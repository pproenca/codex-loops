defmodule Workflow.ExecutionRunOwnershipTest do
  use ExUnit.Case, async: true

  alias Workflow.Journal
  alias Workflow.Run
  alias Workflow.Test.EchoProvider
  alias Workflow.Test.GateProvider

  @receive_timeout 2_000

  defmodule GatedParallel do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "reactor-owner-death",
        quote do
          parallel([agent("a"), agent("b"), agent("c")], max_concurrency: 1)
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  @tag :capture_log
  test "writer death terminates every branch and no journal writes arrive later" do
    run_id = "reactor_owner_death_#{System.unique_integer([:positive])}"

    assert {:ok, ^run_id, writer} =
             Run.start(GatedParallel.tree(),
               run_id: run_id,
               provider: {GateProvider, sink: self()}
             )

    assert_receive {:at_agent, worker}, @receive_timeout
    assert_receive {:agent_called, "a"}, @receive_timeout
    refute_receive {:agent_called, "b"}, 25
    refute_receive {:agent_called, "c"}, 25

    worker_ref = Process.monitor(worker)
    writer_ref = Process.monitor(writer)
    Process.exit(writer, :kill)

    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :killed}, @receive_timeout

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, @receive_timeout

    event_count = length(Journal.fold(run_id))
    Process.sleep(100)
    assert length(Journal.fold(run_id)) == event_count

    assert run_id
           |> Journal.fold()
           |> Enum.filter(&(&1.type == :agent_started))
           |> Enum.map(& &1.payload.address) == [[0, 0]]

    refute_received {:agent_called, "b"}
    refute_received {:agent_called, "c"}

    assert {:error, {:outcome_unknown, %{iteration: 0, attempt: 0}}} =
             Run.run(GatedParallel.tree(),
               run_id: run_id,
               provider: {EchoProvider, sink: self()}
             )

    refute_received {:agent_called, _prompt}
  end
end
