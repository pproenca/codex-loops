defmodule Workflow.ContainmentTest do
  use ExUnit.Case, async: true

  alias Workflow.Containment

  test "successful turns return stdout without stderr noise" do
    assert {:ok, "hello", nil} =
             Containment.run_turn("hello",
               command: {"/bin/sh", ["-c", "cat; printf noisy >&2"]}
             )
  end

  test "failed turns retain bounded stdout and discard stderr" do
    assert {:error, {:backend_exit, 41, "hello"}, nil} =
             Containment.run_turn("hello",
               command: {"/bin/sh", ["-c", "cat; printf boom >&2; exit 41"]}
             )
  end

  test "line observers thread an explicit accumulator through the turn" do
    assert {:ok, "one\ntwo\n", ["two", "one"]} =
             Containment.run_turn("",
               command: {"/bin/sh", ["-c", "printf 'one\\ntwo\\n'"]},
               line_acc: [],
               on_line: fn lines, line -> [line | lines] end
             )
  end
end
