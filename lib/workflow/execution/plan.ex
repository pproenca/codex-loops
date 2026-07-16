defmodule Workflow.Execution.Plan do
  @moduledoc """
  Builds one ephemeral, flat Reactor DAG for a bounded execution frontier.

  Plans are never persisted. Step names are tuples and argument names come from
  a fixed internal set, so workflow-authored names cannot mint atoms. Reactor
  retries, compensation, and undo are deliberately absent: provider retry and
  durable settlement remain scheduler responsibilities.
  """

  alias Reactor.Argument
  alias Reactor.Builder
  alias Workflow.Execution.Step

  @spec build([term()], (term() -> term()), pid(), timeout(), keyword()) :: Reactor.t()
  def build(items, fun, owner, timeout, opts \\ [])
      when is_list(items) and is_function(fun, 1) and is_pid(owner) and
             (timeout == :infinity or (is_integer(timeout) and timeout > 0)) and items != [] and is_list(opts) do
    cap = Keyword.get(opts, :max_concurrency, 8)
    workers = Enum.to_list(0..(min(length(items), cap) - 1))
    cancellation = Keyword.get(opts, :cancellation, owner)
    queue = Keyword.get(opts, :queue, owner)
    report_to = Keyword.get(opts, :report_to, owner)
    execution_ref = Keyword.get_lazy(opts, :execution_ref, &make_ref/0)
    fatal? = Keyword.get(opts, :fatal?, fn _result -> false end)
    supervisor = Keyword.get(opts, :supervisor, Workflow.TaskSupervisor)
    latch = Keyword.get_lazy(opts, :latch, &Workflow.Execution.FatalLatch.new/0)

    reactor =
      Enum.reduce(workers, Builder.new({__MODULE__, make_ref()}), fn index, reactor ->
        name = worker_name(index)

        Builder.add_step!(
          reactor,
          name,
          {Step.Run,
           fun: fun,
           owner: owner,
           timeout: timeout,
           cancellation: cancellation,
           queue: queue,
           report_to: report_to,
           execution_ref: execution_ref,
           fatal?: fatal?,
           supervisor: supervisor,
           latch: latch},
          [],
          async?: true,
          max_retries: 0,
          ref: :step_name
        )
      end)

    reactor =
      Enum.reduce(workers, reactor, fn index, reactor ->
        prior =
          if index == 0 do
            Argument.from_value(:prior, [])
          else
            Argument.from_result(:prior, collect_name(index - 1))
          end

        Builder.add_step!(
          reactor,
          collect_name(index),
          Step.Collect,
          [prior, Argument.from_result(:item, worker_name(index))],
          async?: false,
          max_retries: 0,
          ref: :step_name
        )
      end)

    reactor =
      Builder.add_step!(
        reactor,
        :order,
        Step.Order,
        [Argument.from_result(:results, collect_name(length(workers) - 1))],
        async?: false,
        max_retries: 0,
        ref: :step_name
      )

    Builder.return!(reactor, :order)
  end

  defp worker_name(index), do: {:workflow_worker, index}
  defp collect_name(index), do: {:workflow_collect, index}
end
