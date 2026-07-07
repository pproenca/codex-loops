defmodule Workflow.ReleaseCLITest do
  use ExUnit.Case, async: true

  test "decodes release argv from a base64 nul-delimited environment payload" do
    argv = ["run", "/tmp/work flow.exs", "", "--provider", "mock", "--json"]
    encoded = argv |> Enum.join(<<0>>) |> Kernel.<>(<<0>>) |> Base.encode64()

    assert Workflow.ReleaseCLI.decode_argv(encoded) == argv
  end

  test "empty release argv payload decodes as no arguments" do
    assert Workflow.ReleaseCLI.decode_argv(nil) == []
    assert Workflow.ReleaseCLI.decode_argv("") == []
  end

  test "rejects a malformed release argv payload" do
    assert_raise ArgumentError, ~r/AGENT_LOOPS_ARGV_B64/, fn ->
      Workflow.ReleaseCLI.decode_argv("not base64")
    end
  end
end
