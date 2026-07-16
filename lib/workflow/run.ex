defmodule Workflow.Run do
  @moduledoc """
  Public API for executing an already compiled `%Workflow.Tree{}`.

    * `start/2` — claim the write lease and begin executing asynchronously.
      Returns `{:error, {:already_running, pid}}` if a live writer already holds
      the run's lease.
    * `run/2` — `start/2` then block until the run finishes, returning
      `{:ok, run_id}`. Read state back with `Workflow.Status.of/1`.
  """

  alias Workflow.Event
  alias Workflow.Event.Payload.RunStarted
  alias Workflow.Journal
  alias Workflow.PlanIdentity
  alias Workflow.Run.Input
  alias Workflow.Run.Options
  alias Workflow.Run.Writer
  alias Workflow.Tree

  @max_active_runs 8

  @spec max_active_runs() :: pos_integer()
  def max_active_runs, do: @max_active_runs

  @spec start(Tree.t(), [Options.option()] | Options.t()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start(%Tree{} = tree, options) when is_list(options) do
    with {:ok, options} <- Options.from_keyword(options), do: start(tree, options)
  end

  def start(%Tree{} = tree, %Options{} = options) do
    with {:ok, options} <- prepare_invocation(tree, options),
         {:ok, run_id, pid} <- spawn_writer(tree, options, nil) do
      :ok = Writer.start_execution(pid)
      {:ok, run_id, pid}
    end
  end

  @spec run(Tree.t(), [Options.option()] | Options.t()) :: {:ok, String.t()} | {:error, term()}
  def run(%Tree{} = tree, options) when is_list(options) do
    with {:ok, options} <- Options.from_keyword(options), do: run(tree, options)
  end

  def run(%Tree{} = tree, %Options{} = options) do
    with {:ok, options} <- prepare_invocation(tree, options),
         {:ok, run_id, pid} <- spawn_writer(tree, options, self()) do
      Writer.run_to_completion(pid, run_id)
    end
  end

  # Invocation identity is checked before the write lease is claimed. Expected
  # input or resume failures therefore create neither a ghost run nor a paid
  # provider attempt.
  defp prepare_invocation(%Tree{} = tree, %Options{} = options) do
    fingerprint = PlanIdentity.fingerprint(tree)

    case run_started(Journal.fold(options.run_id)) do
      nil -> prepare_fresh_invocation(tree, options, fingerprint)
      %RunStarted{} = started -> prepare_resumed_invocation(tree, options, fingerprint, started)
    end
  end

  defp prepare_fresh_invocation(tree, options, fingerprint) do
    args = if options.args == :not_provided, do: %{}, else: options.args

    with {:ok, args} <- normalize_and_validate(tree, args) do
      {:ok, %{options | args: args, tree_fingerprint: fingerprint}}
    end
  end

  defp prepare_resumed_invocation(tree, options, fingerprint, %RunStarted{} = started) do
    with :ok <- same_plan(started.tree_fingerprint, fingerprint),
         {:ok, recorded_args} <- Input.normalize(started.args),
         {:ok, args} <- resume_args(options.args, recorded_args, started.args_digest),
         :ok <- validate_args(tree, args) do
      {:ok, %{options | args: args, tree_fingerprint: fingerprint}}
    else
      {:error, reason} when reason in [:not_json, :non_finite_float] ->
        {:error, {:invalid_run_args, reason}}

      {:error, {:too_large, _actual, _maximum} = reason} ->
        {:error, {:invalid_run_args, reason}}

      {:error, {:schema, _detail} = reason} ->
        {:error, {:invalid_run_args, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_and_validate(tree, args) do
    with {:ok, args} <- Input.normalize(args),
         :ok <- Input.validate(tree.input_schema, args) do
      {:ok, args}
    else
      {:error, reason} -> {:error, {:invalid_run_args, reason}}
    end
  end

  defp validate_args(tree, args) do
    Input.validate(tree.input_schema, args)
  end

  defp resume_args(:not_provided, recorded_args, _recorded_digest), do: {:ok, recorded_args}

  defp resume_args(supplied_args, recorded_args, recorded_digest) do
    with {:ok, supplied_args} <- Input.normalize(supplied_args) do
      expected = recorded_digest || Input.digest(recorded_args)
      actual = Input.digest(supplied_args)

      if actual == expected,
        do: {:ok, recorded_args},
        else: {:error, {:run_args_mismatch, expected, actual}}
    end
  end

  defp same_plan(nil, _current), do: :ok
  defp same_plan(fingerprint, fingerprint), do: :ok

  defp same_plan(recorded, current), do: {:error, {:tree_fingerprint_mismatch, recorded, current}}

  defp run_started(events) do
    Enum.find_value(events, fn
      %Event{payload: %RunStarted{} = payload} -> payload
      %Event{} -> nil
    end)
  end

  # Claim the write lease and return the idle writer's pid without starting work.
  defp spawn_writer(%Tree{} = tree, %Options{} = options, parent) do
    case DynamicSupervisor.start_child(Workflow.Run.Supervisor, {Writer, {tree, options, parent}}) do
      {:ok, pid} ->
        # Index only after capacity and lease arbitration succeed, but before the
        # caller releases the idle writer to execute. A rejected start must not
        # leave a durable ghost run. Registration is idempotent for resume.
        :ok = Journal.register_run(options.run_id)
        {:ok, options.run_id, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_running, pid}}

      {:error, :max_children} ->
        {:error, {:capacity_exceeded, @max_active_runs}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
