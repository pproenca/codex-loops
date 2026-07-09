defmodule Workflow.ContainmentTest do
  use ExUnit.Case, async: true

  alias Workflow.Containment

  test "successful turns return stdout without stderr noise" do
    assert {:ok, "hello"} =
             Containment.run_turn("hello",
               command: {"/bin/sh", ["-c", "cat; printf noisy >&2"]}
             )
  end

  test "failed turns include stdout and stderr in backend exit detail" do
    assert {:error, {:backend_exit, 41, output}} =
             Containment.run_turn("hello",
               command: {"/bin/sh", ["-c", "cat; printf boom >&2; exit 41"]}
             )

    assert output =~ "hello"
    assert output =~ "boom"
  end
end
