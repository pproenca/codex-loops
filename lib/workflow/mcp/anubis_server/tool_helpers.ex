defmodule Workflow.MCP.AnubisServer.ToolHelpers do
  @moduledoc false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Workflow.MCP.{Lifecycle, ProjectionEnvelope, SchedulerClient}

  @api_version "codex-loops.mcp.v1"
  @lifecycle_assign :workflow_mcp_lifecycle
  @lifecycle_store {__MODULE__, :workflow_mcp_lifecycle}

  @spec init_lifecycle(Frame.t()) :: Frame.t()
  def init_lifecycle(%Frame{} = frame) do
    Frame.assign_new(frame, @lifecycle_assign, fn ->
      state = Lifecycle.new()
      store_lifecycle_state(state)
      state
    end)
  end

  @spec stop_lifecycle(Frame.t()) :: :ok
  def stop_lifecycle(%Frame{} = frame) do
    frame_state = lifecycle_state(frame)
    stored_state = stored_lifecycle_state()

    if owned_scheduler?(frame_state) do
      Lifecycle.stop_owned(frame_state)
    else
      Lifecycle.stop_owned(stored_state)
    end

    clear_lifecycle_state()

    :ok
  end

  @spec stop_stored_lifecycle() :: :ok
  def stop_stored_lifecycle do
    stored_lifecycle_state()
    |> Lifecycle.stop_owned()

    clear_lifecycle_state()

    :ok
  end

  @spec scheduler_tool(Frame.t(), (-> SchedulerClient.scheduler_result())) ::
          {:reply, Response.t(), Frame.t()}
  def scheduler_tool(%Frame{} = frame, scheduler_fun) when is_function(scheduler_fun, 0) do
    with {:ok, frame} <- ensure_ready(frame) do
      scheduler_fun.()
      |> scheduler_response(frame)
    else
      {:error, response, frame} ->
        {:reply, response, frame}
    end
  end

  @spec scheduler_projection_tool(Frame.t(), (-> SchedulerClient.scheduler_result())) ::
          {:reply, Response.t(), Frame.t()}
  def scheduler_projection_tool(%Frame{} = frame, scheduler_fun)
      when is_function(scheduler_fun, 0) do
    with {:ok, frame} <- ensure_ready(frame) do
      scheduler_fun.()
      |> scheduler_projection_response(frame)
    else
      {:error, response, frame} ->
        {:reply, response, frame}
    end
  end

  @spec open_ui_tool(Frame.t(), String.t()) :: {:reply, Response.t(), Frame.t()}
  def open_ui_tool(%Frame{} = frame, run_id) when is_binary(run_id) do
    with {:ok, frame} <- ensure_ready(frame) do
      case SchedulerClient.get_run(run_id) do
        {:ok, %{"data" => %{} = projection}} ->
          {:reply, tool_response(open_ui_envelope(projection), false), frame}

        {:ok, envelope} ->
          {:reply, tool_response(unexpected_response_envelope(200, envelope), true), frame}

        other ->
          scheduler_response(other, frame)
      end
    else
      {:error, response, frame} ->
        {:reply, response, frame}
    end
  end

  defp ensure_ready(%Frame{} = frame) do
    state =
      frame
      |> lifecycle_state()
      |> Lifecycle.collect_port_messages()

    case Lifecycle.ensure_ready(state) do
      {:ok, state} ->
        {:ok, put_lifecycle_state(frame, state)}

      {:error, envelope, state} ->
        {:error, tool_response(envelope, true), put_lifecycle_state(frame, state)}
    end
  end

  defp scheduler_response({:ok, envelope}, frame) do
    {:reply, tool_response(envelope, false), frame}
  end

  defp scheduler_response({:scheduler_error, envelope}, frame) do
    {:reply, tool_response(envelope, true), frame}
  end

  defp scheduler_response({:unexpected, status, payload}, frame) do
    {:reply, tool_response(unexpected_response_envelope(status, payload), true), frame}
  end

  defp scheduler_response({:error, reason}, frame) do
    envelope =
      error_envelope("scheduler_unavailable", "Scheduler could not be reached.", %{
        scheduler_url: SchedulerClient.config().base_url,
        reason: reason
      })

    {:reply, tool_response(envelope, true), frame}
  end

  defp scheduler_projection_response({:ok, envelope}, frame) do
    {:reply, envelope |> ProjectionEnvelope.conform() |> tool_response(false), frame}
  end

  defp scheduler_projection_response(other, frame), do: scheduler_response(other, frame)

  defp tool_response(envelope, is_error?) do
    Response.tool()
    |> Response.text(Jason.encode!(envelope, pretty: true))
    |> Map.put(:structured_content, envelope)
    |> Map.put(:isError, is_error?)
  end

  defp unexpected_response_envelope(status, payload) do
    error_envelope(
      "scheduler_unexpected_response",
      "Scheduler returned an unexpected response.",
      %{
        http_status: status,
        payload: payload
      }
    )
  end

  defp open_ui_envelope(projection) do
    ui_url =
      projection["uiUrl"] || projection["uiPath"] || projection["ui_url"] || projection["ui_path"]

    %{
      "api_version" => @api_version,
      "data" => Map.put(projection, "open_url", absolute_open_url(ui_url))
    }
  end

  defp absolute_open_url(nil), do: SchedulerClient.config().base_url

  defp absolute_open_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme && uri.host do
      url
    else
      SchedulerClient.config().base_url
      |> Kernel.<>("/")
      |> URI.merge(url)
      |> URI.to_string()
    end
  end

  defp error_envelope(code, message, details) do
    %{
      "api_version" => @api_version,
      "error" => %{
        "code" => code,
        "message" => message,
        "details" => details
      }
    }
  end

  defp lifecycle_state(%Frame{} = frame) do
    Map.get(frame.assigns, @lifecycle_assign, Lifecycle.new())
  end

  defp put_lifecycle_state(%Frame{} = frame, state) do
    store_lifecycle_state(state)
    Frame.assign(frame, @lifecycle_assign, state)
  end

  defp store_lifecycle_state(state) do
    :persistent_term.put(@lifecycle_store, state)
  end

  defp stored_lifecycle_state do
    :persistent_term.get(@lifecycle_store, Lifecycle.new())
  end

  defp clear_lifecycle_state do
    :persistent_term.erase(@lifecycle_store)
  rescue
    ArgumentError -> :ok
  end

  defp owned_scheduler?(%{owned_scheduler: nil}), do: false
  defp owned_scheduler?(%{owned_scheduler: _scheduler}), do: true
  defp owned_scheduler?(_state), do: false
end
