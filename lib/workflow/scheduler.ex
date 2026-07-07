defmodule Workflow.Scheduler do
  @moduledoc """
  Product API boundary for scheduler clients.

  Phoenix controllers call this context instead of reaching into journal or runtime
  internals. Expected API failures return tagged tuples with typed error data;
  unexpected process failures are left to crash under supervision.
  """

  alias Workflow.Scheduler.{Error, Health}

  @app :codex_loops

  @spec health() :: {:ok, Health.t()} | {:error, Error.t()}
  def health do
    checks = %{
      otp_app: available?(application_started?(@app)),
      journal: available?(process_alive?(Workflow.Journal)),
      pubsub: available?(process_alive?(Workflow.PubSub)),
      endpoint: available?(process_alive?(Workflow.Web.Endpoint))
    }

    if Enum.all?(checks, fn {_dependency, status} -> status == :available end) do
      {:ok, %Health{status: :ok, checks: checks}}
    else
      {:error, Error.unavailable(checks)}
    end
  end

  @spec start_run(map()) :: {:error, Error.t()}
  def start_run(_params), do: {:error, Error.run_start_not_available()}

  defp application_started?(app) do
    Enum.any?(Application.started_applications(), fn
      {^app, _description, _version} -> true
      _other -> false
    end)
  end

  defp process_alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  defp available?(true), do: :available
  defp available?(false), do: :unavailable
end
