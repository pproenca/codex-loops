defmodule Workflow.Journal do
  @moduledoc """
  The append-only event log — the single source of truth. Every read surface
  (`Workflow.Status`, and later LiveView) is a pure fold over `fold/1`; nothing
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

  This process owns the SQLite connection under supervision; it holds no run state
  of its own.
  """
  use GenServer

  alias Exqlite.Sqlite3

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Append a single event at `seq`. Called only by the run's live writer."
  @spec append(String.t(), non_neg_integer(), Workflow.Event.t()) :: :ok
  def append(run_id, seq, %Workflow.Event{} = event) do
    GenServer.call(__MODULE__, {:append, run_id, seq, event})
  end

  @doc "Fold source: every event for `run_id` in commit (`seq`) order."
  @spec fold(String.t()) :: [Workflow.Event.t()]
  def fold(run_id), do: GenServer.call(__MODULE__, {:fold, run_id})

  @doc "Highest committed `seq` for `run_id`, or `-1` when the run has no events."
  @spec last_seq(String.t()) :: integer()
  def last_seq(run_id), do: GenServer.call(__MODULE__, {:last_seq, run_id})

  @doc """
  Record `run_id` in the run index at its creation order. Idempotent — a resume of
  an already-indexed run is a no-op — so it may be called on every `Run` entry.
  """
  @spec register_run(String.t()) :: :ok
  def register_run(run_id), do: GenServer.call(__MODULE__, {:register_run, run_id})

  @doc "Every known `run_id`, oldest-created first."
  @spec run_ids() :: [String.t()]
  def run_ids, do: GenServer.call(__MODULE__, :run_ids)

  @doc "The most recently created `run_id`, or `nil` when no run has ever started."
  @spec latest_run_id() :: String.t() | nil
  def latest_run_id, do: GenServer.call(__MODULE__, :latest_run_id)

  @impl true
  def init(:ok) do
    path = database_path()
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.set_busy_timeout(db, 5_000)
    :ok = migrate(db)
    {:ok, %{db: db, path: path}}
  end

  @impl true
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  @impl true
  def handle_call({:append, run_id, seq, %Workflow.Event{} = event}, _from, %{db: db} = state) do
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

  def handle_call({:fold, run_id}, _from, %{db: db} = state) do
    events =
      query(db, "SELECT event_blob FROM events WHERE run_id = ? ORDER BY seq ASC", [run_id])
      |> Enum.map(fn [blob] -> :erlang.binary_to_term(blob) end)

    {:reply, events, state}
  end

  def handle_call({:last_seq, run_id}, _from, %{db: db} = state) do
    seq =
      case query(db, "SELECT seq FROM events WHERE run_id = ? ORDER BY seq DESC LIMIT 1", [run_id]) do
        [[seq]] -> seq
        [] -> -1
      end

    {:reply, seq, state}
  end

  def handle_call({:register_run, run_id}, _from, %{db: db} = state) do
    :ok = exec(db, "INSERT OR IGNORE INTO runs (run_id) VALUES (?)", [run_id])
    {:reply, :ok, state}
  end

  def handle_call(:run_ids, _from, %{db: db} = state) do
    ids =
      db
      |> query("SELECT run_id FROM runs ORDER BY creation_order ASC", [])
      |> Enum.map(fn [run_id] -> run_id end)

    {:reply, ids, state}
  end

  def handle_call(:latest_run_id, _from, %{db: db} = state) do
    latest =
      case query(db, "SELECT run_id FROM runs ORDER BY creation_order DESC LIMIT 1", []) do
        [[run_id]] -> run_id
        [] -> nil
      end

    {:reply, latest, state}
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
