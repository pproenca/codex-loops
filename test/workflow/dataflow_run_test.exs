defmodule Workflow.DataflowRunTest do
  @moduledoc """
  End-to-end run coverage for slice #15's dataflow core. These assertions pin
  rendered terminal values, the absence of extra journal events, and the existing
  `run_completed` fold/status behavior.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Event, Journal, Run, Status}
  alias Workflow.Test.{EchoProvider, ScriptedProvider}

  defmodule BinaryEmit do
    use Workflow

    workflow "binary-emit" do
      let(:draft = agent("Write a draft."))
      emit(~P"Final draft: <%= @draft %>")
    end
  end

  defmodule SynthesizedEmit do
    use Workflow

    workflow "synthesized-emit" do
      let(:summary = synthesize(["plan A", "plan B"], "Merge the plans."))
      emit(~P"Summary: <%= @summary %>")
    end
  end

  defmodule MapEmit do
    use Workflow

    workflow "map-emit" do
      let(:draft = agent("Write a draft."))
      emit(~P"Final draft: <%= @draft %>")
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp types(id), do: Journal.fold(id) |> Enum.map(& &1.type)

  test "emit renders a binary-valued binding into run_completed.value exactly" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start(["READY"])

    assert {:ok, ^id} =
             Run.run(BinaryEmit,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Write a draft."}
    refute_received {:agent_called, _}

    assert types(id) == [:run_started, :agent_committed, :run_completed]

    assert %Event{payload: %{value: "Final draft: READY"}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))

    assert Status.of(id).state == :completed
    assert Status.of(id).result == "Final draft: READY"
  end

  test "let-bound synthesize reuses the existing render/prompt seams and emits the terminal value" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start(["Merged summary"])

    assert {:ok, ^id} =
             Run.run(SynthesizedEmit,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Merge the plans.\n\nInputs: [\"plan A\", \"plan B\"]"}

    assert %Event{payload: %{value: "Summary: Merged summary"}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))
  end

  test "map-bearing terminal render is asserted structurally, not byte-for-byte" do
    id = run_id()

    assert {:ok, ^id} = Run.run(MapEmit, run_id: id, provider: {EchoProvider, sink: self()})

    assert %Event{payload: %{value: rendered}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))

    assert String.starts_with?(rendered, "Final draft: %{")
    assert rendered =~ ~s|"echo" => "Write a draft."|
    assert Status.of(id).result == rendered
  end
end
