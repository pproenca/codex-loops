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
  Decoding uses OTP's `:safe` option. Workflow source is parsed with an existing-atom
  encoder, so persisted events contain only atoms compiled into the release; a blob
  that tries to mint a new atom is rejected.
  """
  use GenServer

  alias Exqlite.Sqlite3
  alias Workflow.Event

  @max_event_blob_bytes 16 * 1024 * 1024
  @metadata_table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Append a single event at `seq`. Called only by the run's live writer."
  @spec append(String.t(), non_neg_integer(), Event.t()) :: :ok
  def append(run_id, seq, %Event{} = event) do
    GenServer.call(__MODULE__, {:append, run_id, seq, event})
  end

  @doc """
  Append an event at the next available sequence number for `run_id`.

  Used by callers that need the journal to allocate the next durable sequence.
  """
  @spec append_next(String.t(), Event.t()) :: {:ok, Event.t()}
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
    path = database_path()
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.set_busy_timeout(db, 5_000)
    :ok = migrate(db)
    _table = :ets.new(@metadata_table, [:named_table, :protected, read_concurrency: true])
    true = :ets.insert(@metadata_table, {:path, path})
    {:ok, %{db: db, path: path}}
  end

  @impl true
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  @impl true
  def handle_call({:append, run_id, seq, %Event{} = event}, _from, %{db: db} = state) do
    sql = """
    INSERT INTO events (run_id, seq, schema, type, event_blob)
    VALUES (?, ?, ?, ?, ?)
    """

    :ok =
      exec(db, sql, [
        run_id,
        seq,
        event.schema,
        Atom.to_string(event.type),
        {:blob, :erlang.term_to_binary(event)}
      ])

    {:reply, :ok, state}
  end

  def handle_call({:append_next, run_id, %Event{} = event}, _from, %{db: db} = state) do
    seq = last_seq(db, run_id) + 1
    event = %{event | run_id: run_id, seq: seq}
    :ok = insert_event(db, run_id, seq, event)

    {:reply, {:ok, event}, state}
  end

  def handle_call({:register_run, run_id}, _from, %{db: db} = state) do
    :ok = exec(db, "INSERT OR IGNORE INTO runs (run_id) VALUES (?)", [run_id])
    {:reply, :ok, state}
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

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_event(blob) when is_binary(blob) and byte_size(blob) <= @max_event_blob_bytes do
    case :erlang.binary_to_term(blob, [:safe]) do
      %Event{} = event ->
        if data_only?(event) do
          event
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

  defp data_only?(term) when is_list(term), do: Enum.all?(term, &data_only?/1)
  defp data_only?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.all?(&data_only?/1)
  defp data_only?(_term), do: true

  defp last_seq(db, run_id) do
    case query(db, "SELECT seq FROM events WHERE run_id = ? ORDER BY seq DESC LIMIT 1", [run_id]) do
      [[seq]] -> seq
      [] -> -1
    end
  end

  defp read(fun) when is_function(fun, 1) do
    [{:path, path}] = :ets.lookup(@metadata_table, :path)
    {:ok, db} = Sqlite3.open(path, [:readonly])
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
