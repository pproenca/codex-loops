defmodule Workflow.Journal do
  @moduledoc """
  The append-only event log — the single source of truth. Every read surface
  (`Workflow.Status`, and later LiveView) is a pure fold over `fold/1`; nothing
  reads independent process state.

  Backed by one `:ordered_set` ETS table keyed by `{run_id, seq}`. Reads are
  lock-free concurrent folds. Writes are serialised per run by the single live
  writer (one per run via the run registry), so `seq` needs no global counter and
  ordered iteration yields events in commit order.

  This process is only the table's owner/heir under supervision; it holds no run
  state of its own.
  """
  use GenServer

  @table __MODULE__

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

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
