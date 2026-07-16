defmodule Workflow.Execution.FatalLatch do
  @moduledoc false

  @opaque t :: :atomics.atomics_ref()

  @spec new() :: t()
  def new, do: :atomics.new(1, signed: false)

  @spec cancel(t()) :: :ok
  def cancel(latch), do: :atomics.put(latch, 1, 1)

  @spec cancelled?(t()) :: boolean()
  def cancelled?(latch), do: :atomics.get(latch, 1) == 1
end
