defmodule Workflow.Journal do
  @moduledoc """
  The append-only event log — the single source of truth. Every read surface
  (`Workflow.Status`, the HTTP API, and LiveView) is a pure fold over `fold/1`; nothing
  reads independent process state.

  Backed by SQLite at `~/.codex/workflows/runs_1.sqlite` by default, or
  `CODEX_LOOPS_JOURNAL_PATH` when supplied. Events are keyed by `{run_id, seq}` and
  store the full `%Workflow.Event{}` as an Erlang term blob so folds reconstruct the
  exact in-memory event without lossy JSON conversion. Writes are serialised per run
  by the single live writer (one per run via the run registry), so `seq` needs no
  global counter and ordered iteration yields events in commit order.

  A `runs` table is a lightweight **run index**: `run_id -> creation order`
  (SQLite's autoincrementing row id). It is not run *state* — every authoritative
  read still folds the event log — it only lets `list` enumerate runs and the read
  commands select the latest one when `--run-id` is omitted, since run ids are
  random and carry no order themselves.

  This process owns the single write connection under supervision; it holds no run
  state of its own. Reads open short-lived read-only connections, so HTTP and
  LiveView folds do not queue behind one GenServer mailbox. A protected ETS row
  publishes only the supervised database path. The process is deliberately a boot
  gate: the scheduler must not accept a run unless its source of truth is open and
  migrated successfully.

  The ETF blob is an internal, user-owned persistence format, not an import format.
  Decoding uses OTP's `:safe` option. At boot the journal loads the finite module
  vocabulary compiled into this application, making every legitimate persisted
  atom existing before the first fold. Workflow source cannot add atoms, and a blob
  containing anything outside that release-owned vocabulary is rejected.
  """
  use GenServer

  alias Exqlite.Sqlite3
  alias Workflow.Event

  @max_event_blob_bytes 16 * 1024 * 1024
  @metadata_table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Append an event at the next available sequence number for `run_id`.

  Used by callers that need the journal to allocate the next durable sequence.
  """
  @spec append_next(String.t(), Event.t()) :: {:ok, Event.t()} | {:error, :inactive_activity}
  def append_next(run_id, %Event{} = event) do
    GenServer.call(__MODULE__, {:append_next, run_id, event})
  end

  @doc "Fold source: every event for `run_id` in commit (`seq`) order."
  @spec fold(String.t()) :: [Event.t()]
  def fold(run_id) do
    read(fn db ->
      db
      |> query("SELECT event_blob FROM events WHERE run_id = ? ORDER BY seq ASC", [run_id])
      |> Enum.map(fn [blob] -> decode_event(blob) end)
    end)
  end

  @doc "Highest committed `seq` for `run_id`, or `-1` when the run has no events."
  @spec last_seq(String.t()) :: integer()
  def last_seq(run_id), do: read(&last_seq(&1, run_id))

  @doc """
  Record `run_id` in the run index at its creation order. Idempotent — a resume of
  an already-indexed run is a no-op — so it may be called on every `Run` entry.
  """
  @spec register_run(String.t()) :: :ok
  def register_run(run_id), do: GenServer.call(__MODULE__, {:register_run, run_id})

  @doc "Every known `run_id`, oldest-created first."
  @spec run_ids() :: [String.t()]
  def run_ids do
    read(fn db ->
      db
      |> query("SELECT run_id FROM runs ORDER BY creation_order ASC", [])
      |> Enum.map(fn [run_id] -> run_id end)
    end)
  end

  @doc "Whether `run_id` is present in the run index."
  @spec run_exists?(String.t()) :: boolean()
  def run_exists?(run_id) when is_binary(run_id) do
    read(fn db -> query(db, "SELECT 1 FROM runs WHERE run_id = ? LIMIT 1", [run_id]) != [] end)
  end

  @doc "The most recently created `run_id`, or `nil` when no run has ever started."
  @spec latest_run_id() :: String.t() | nil
  def latest_run_id do
    read(fn db ->
      case query(db, "SELECT run_id FROM runs ORDER BY creation_order DESC LIMIT 1", []) do
        [[run_id]] -> run_id
        [] -> nil
      end
    end)
  end

  @impl true
  def init(:ok) do
    :ok = Code.ensure_all_loaded!(Application.spec(:codex_loops, :modules))
    path = database_path()
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.set_busy_timeout(db, 5_000)
    :ok = migrate(db)
    _table = :ets.new(@metadata_table, [:named_table, :protected, read_concurrency: true])
    true = :ets.insert(@metadata_table, {:path, path})
    {:ok, %{db: db, path: path, activity_cursors: %{}}}
  end

  @impl true
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  @impl true
  def handle_call({:append_next, run_id, %Event{} = event}, {owner, _tag}, %{db: db} = state) do
    if inactive_activity?(run_id, event, state.activity_cursors) do
      {:reply, {:error, :inactive_activity}, state}
    else
      {event, activity_cursors} = prepare_event(run_id, event, owner, state.activity_cursors)
      seq = last_seq(db, run_id) + 1
      event = %{event | run_id: run_id, seq: seq}
      :ok = insert_event(db, run_id, seq, event)

      {:reply, {:ok, event}, %{state | activity_cursors: activity_cursors}}
    end
  end

  def handle_call({:register_run, run_id}, _from, %{db: db} = state) do
    :ok = exec(db, "INSERT OR IGNORE INTO runs (run_id) VALUES (?)", [run_id])
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    activity_cursors =
      Map.reject(state.activity_cursors, fn {_key, {_next_index, cursor_ref}} -> cursor_ref == ref end)

    {:noreply, %{state | activity_cursors: activity_cursors}}
  end

  defp database_path do
    System.get_env("CODEX_LOOPS_JOURNAL_PATH") ||
      :codex_loops
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:path)
      |> case do
        nil -> Path.join([System.user_home!(), ".codex", "workflows", "runs_1.sqlite"])
        path -> path
      end
  end

  defp migrate(db) do
    Sqlite3.execute(db, """
    CREATE TABLE IF NOT EXISTS runs (
      creation_order INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id TEXT UNIQUE NOT NULL
    );

    CREATE TABLE IF NOT EXISTS events (
      run_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      schema INTEGER NOT NULL,
      type TEXT NOT NULL,
      event_blob BLOB NOT NULL,
      PRIMARY KEY (run_id, seq)
    );
    """)
  end

  defp insert_event(db, run_id, seq, %Event{} = event) do
    sql = """
    INSERT INTO events (run_id, seq, schema, type, event_blob)
    VALUES (?, ?, ?, ?, ?)
    """

    exec(db, sql, [
      run_id,
      seq,
      event.schema,
      Atom.to_string(event.type),
      {:blob, :erlang.term_to_binary(event)}
    ])
  end

  defp prepare_event(run_id, %Event{type: :agent_started, payload: payload} = event, owner, cursors) do
    key = activity_key(run_id, payload.address, payload.iteration, payload.attempt)

    case Map.fetch(cursors, key) do
      {:ok, _cursor} ->
        {event, cursors}

      :error ->
        {event, Map.put(cursors, key, {0, Process.monitor(owner)})}
    end
  end

  defp prepare_event(run_id, %Event{type: :agent_activity, payload: payload} = event, _owner, cursors) do
    key = activity_key(run_id, payload.address, payload.iteration, payload.attempt)

    case {payload.activity_index, Map.fetch(cursors, key)} do
      {nil, :error} ->
        raise ArgumentError, "activity arrived outside an active provider attempt"

      {nil, {:ok, {next_index, ref}}} ->
        event = %{event | payload: %{payload | activity_index: next_index}}
        {event, Map.put(cursors, key, {next_index + 1, ref})}

      {index, :error} when is_integer(index) and index >= 0 ->
        {event, cursors}

      {index, {:ok, {next_index, ref}}} when is_integer(index) and index >= 0 ->
        {event, Map.put(cursors, key, {max(next_index, index + 1), ref})}

      {invalid, _cursor} ->
        raise ArgumentError, "invalid activity index: #{inspect(invalid)}"
    end
  end

  defp prepare_event(run_id, %Event{type: :agent_committed, payload: payload} = event, _owner, cursors) do
    attempt = payload.idempotency_key.attempt
    {event, drop_activity_cursor(cursors, activity_key(run_id, payload.address, payload.iteration, attempt))}
  end

  defp prepare_event(run_id, %Event{type: :agent_attempt_rejected, payload: payload} = event, _owner, cursors) do
    {event, drop_activity_cursor(cursors, activity_key(run_id, payload.address, payload.iteration, payload.attempt))}
  end

  defp prepare_event(run_id, %Event{type: :agent_failed, payload: payload} = event, _owner, cursors) do
    key = activity_key(run_id, payload.address, payload.iteration, max(payload.attempts - 1, 0))
    {event, drop_activity_cursor(cursors, key)}
  end

  defp prepare_event(run_id, %Event{type: :refine_role_failed, payload: payload} = event, _owner, cursors) do
    attempt = max(payload.attempts - 1, 0)

    cursors =
      case payload.round do
        round when is_integer(round) ->
          drop_activity_cursor(cursors, activity_key(run_id, payload.role_address, round, attempt))

        nil ->
          drop_activity_cursors(cursors, fn {cursor_run_id, address, _iteration, cursor_attempt} ->
            cursor_run_id == run_id and address == payload.role_address and cursor_attempt == attempt
          end)
      end

    {event, cursors}
  end

  defp prepare_event(run_id, %Event{type: type} = event, _owner, cursors) when type in [:run_completed, :run_failed] do
    {event,
     drop_activity_cursors(cursors, fn {cursor_run_id, _address, _iteration, _attempt} -> cursor_run_id == run_id end)}
  end

  defp prepare_event(_run_id, %Event{} = event, _owner, cursors), do: {event, cursors}

  defp inactive_activity?(run_id, %Event{type: :agent_activity, payload: %{activity_index: nil} = payload}, cursors) do
    key = activity_key(run_id, payload.address, payload.iteration, payload.attempt)
    not Map.has_key?(cursors, key)
  end

  defp inactive_activity?(_run_id, %Event{}, _cursors), do: false

  defp activity_key(run_id, address, iteration, attempt), do: {run_id, address, iteration, attempt}

  defp drop_activity_cursor(cursors, key) do
    case Map.pop(cursors, key) do
      {{_next_index, ref}, cursors} ->
        demonitor(ref)
        cursors

      {nil, cursors} ->
        cursors
    end
  end

  defp drop_activity_cursors(cursors, matches?) do
    Enum.reduce(cursors, %{}, fn {key, {_next_index, ref} = cursor}, kept ->
      if matches?.(key) do
        demonitor(ref)
        kept
      else
        Map.put(kept, key, cursor)
      end
    end)
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_event(blob) when is_binary(blob) and byte_size(blob) <= @max_event_blob_bytes do
    case :erlang.binary_to_term(blob, [:safe]) do
      %Event{} = event ->
        if data_only?(event) do
          copy_data(event)
        else
          raise ArgumentError, "journal event contains a runtime-only term"
        end

      _other ->
        raise ArgumentError, "journal blob is not a Workflow.Event"
    end
  end

  defp decode_event(blob) when is_binary(blob) do
    raise ArgumentError, "journal event exceeds #{@max_event_blob_bytes} bytes"
  end

  defp data_only?(term) when is_function(term) or is_pid(term) or is_port(term) or is_reference(term), do: false
  defp data_only?(%_{} = struct), do: struct |> Map.from_struct() |> data_only?()

  defp data_only?(term) when is_map(term),
    do: Enum.all?(term, fn {key, value} -> data_only?(key) and data_only?(value) end)

  defp data_only?([head | tail]), do: data_only?(head) and data_only?(tail)
  defp data_only?([]), do: true
  defp data_only?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.all?(&data_only?/1)
  defp data_only?(_term), do: true

  defp copy_data(value) when is_binary(value), do: :binary.copy(value)
  defp copy_data([head | tail]), do: [copy_data(head) | copy_data(tail)]
  defp copy_data([]), do: []

  defp copy_data(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&copy_data/1)
    |> List.to_tuple()
  end

  defp copy_data(%_{} = value) do
    fields = value |> Map.from_struct() |> copy_data()
    struct(value.__struct__, fields)
  end

  defp copy_data(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {copy_data(key), copy_data(item)} end)
  end

  defp copy_data(value), do: value

  defp last_seq(db, run_id) do
    case query(db, "SELECT seq FROM events WHERE run_id = ? ORDER BY seq DESC LIMIT 1", [run_id]) do
      [[seq]] -> seq
      [] -> -1
    end
  end

  defp read(fun) when is_function(fun, 1) do
    [{:path, path}] = :ets.lookup(@metadata_table, :path)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    :ok = Sqlite3.set_busy_timeout(db, 5_000)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp exec(db, sql, params) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, params)

      case Sqlite3.step(db, statement) do
        :done -> :ok
        {:error, reason} -> raise "sqlite exec failed: #{inspect(reason)}"
      end
    after
      Sqlite3.release(db, statement)
    end
  end

  defp query(db, sql, params) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(db, statement)
      rows
    after
      Sqlite3.release(db, statement)
    end
  end
end
