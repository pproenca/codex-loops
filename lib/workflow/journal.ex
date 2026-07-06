defmodule Workflow.Journal do
  @moduledoc """
  The append-only event log — the single source of truth. Every read surface
  (`Workflow.Status`, and later LiveView) is a pure fold over `fold/1`; nothing
  reads independent process state.

  Backed by one `:ordered_set` ETS table keyed by `{run_id, seq}`. Reads are
  lock-free concurrent folds. Writes are serialised per run by the single live
  writer (one per run via the run registry), so `seq` needs no global counter and
  ordered iteration yields events in commit order.

  A second `:set` table is a lightweight **run index**: `run_id -> creation order`
  (a strictly-monotonic integer). It is not run *state* — every authoritative read
  still folds the event log — it only lets `list` enumerate runs and the read
  commands select the latest one when `--run-id` is omitted, since run ids are
  random and carry no order themselves.

  This process is only the tables' owner/heir under supervision; it holds no run
  state of its own.
  """
  use GenServer

  @table __MODULE__
  @runs Module.concat(__MODULE__, Runs)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Append a single event at `seq`. Called only by the run's live writer."
  @spec append(String.t(), non_neg_integer(), Workflow.Event.t()) :: :ok
  def append(run_id, seq, %Workflow.Event{} = event) do
    true = :ets.insert_new(@table, {{run_id, seq}, event})
    :ok
  end

  @doc "Fold source: every event for `run_id` in commit (`seq`) order."
  @spec fold(String.t()) :: [Workflow.Event.t()]
  def fold(run_id) do
    @table
    |> :ets.select([{{{run_id, :"$1"}, :"$2"}, [], [:"$2"]}])
  end

  @doc "Highest committed `seq` for `run_id`, or `-1` when the run has no events."
  @spec last_seq(String.t()) :: integer()
  def last_seq(run_id) do
    case fold(run_id) do
      [] -> -1
      events -> events |> List.last() |> Map.fetch!(:seq)
    end
  end

  @doc """
  Record `run_id` in the run index at its creation order. Idempotent — a resume of
  an already-indexed run is a no-op — so it may be called on every `Run` entry.
  """
  @spec register_run(String.t()) :: :ok
  def register_run(run_id) do
    :ets.insert_new(@runs, {run_id, System.unique_integer([:monotonic, :positive])})
    :ok
  end

  @doc "Every known `run_id`, oldest-created first."
  @spec run_ids() :: [String.t()]
  def run_ids do
    @runs
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  @doc "The most recently created `run_id`, or `nil` when no run has ever started."
  @spec latest_run_id() :: String.t() | nil
  def latest_run_id do
    case run_ids() do
      [] -> nil
      ids -> List.last(ids)
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    :ets.new(@runs, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
