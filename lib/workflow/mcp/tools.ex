defmodule Workflow.MCP.Tools do
  @moduledoc """
  The scheduler-owned MCP tool catalog and dispatch boundary.

  Tool calls enter the same `Workflow.Scheduler` context used by Phoenix's JSON
  API. The MCP transport does not call back into the scheduler over loopback
  HTTP, and it owns no run or provider state.
  """

  alias Workflow.Scheduler
  alias Workflow.Scheduler.Error
  alias Workflow.Scheduler.RunEventsProjection
  alias Workflow.Scheduler.RunProjection
  alias Workflow.Scheduler.RunStart
  alias Workflow.Scheduler.Validation

  @api_version "scheduler.v1"
  @mcp_api_version "codex-loops.mcp.v1"
  @max_run_id_bytes 128
  @run_id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/
  @run_id_schema_pattern "^[A-Za-z0-9][A-Za-z0-9_.:-]*$"

  @path_schema %{"type" => "string", "minLength" => 1}
  @workspace_root_schema %{"type" => "string", "minLength" => 1, "pattern" => "^/"}
  @run_id_schema %{
    "type" => "string",
    "minLength" => 1,
    "maxLength" => @max_run_id_bytes,
    "pattern" => @run_id_schema_pattern
  }
  @provider_schema %{"type" => "string", "enum" => ["mock", "codex"]}

  @projection_fields ~w[
    runId state treeName phase logs agentCount eventCount usage result failure
    agents rejected verifications judgments refines toolActivity journalEvents rawRefs
    args argsDigest treeFingerprint
  ]

  @type call_result :: map()
  @type dispatch_result :: {:ok, call_result()} | {:invalid_params, String.t()}

  @spec catalog() :: [map()]
  def catalog do
    [
      tool(
        "workflow_validate",
        "Validate a Codex Loops workflow script.",
        schema(
          %{
            "script_path" => @path_schema,
            "workspace_root" => @workspace_root_schema,
            "args" => %{}
          },
          ["script_path"]
        )
      ),
      tool(
        "workflow_start",
        "Start a Codex Loops workflow run.",
        schema(
          %{
            "script_path" => @path_schema,
            "workspace_root" => @workspace_root_schema,
            "run_id" => @run_id_schema,
            "provider" => @provider_schema,
            "budget" => %{"type" => "integer", "minimum" => 0},
            "args" => %{}
          },
          ["script_path"]
        )
      ),
      tool(
        "workflow_status",
        "Read the public §7.5 status projection for a scheduler run.",
        run_schema()
      ),
      tool(
        "workflow_inspect",
        "Read the public §7.5 inspect/status projection with ordered rawRefs for a scheduler run.",
        run_schema()
      ),
      tool(
        "workflow_resume",
        "Resume an existing scheduler run.",
        schema(
          %{
            "run_id" => @run_id_schema,
            "script_path" => @path_schema,
            "script" => @path_schema,
            "workspace_root" => @workspace_root_schema,
            "provider" => @provider_schema
          },
          ["run_id"]
        )
      ),
      tool(
        "workflow_open_ui",
        "Return the Phoenix LiveView URL for a scheduler run.",
        run_schema()
      )
    ]
  end

  @spec call(String.t(), map(), keyword()) :: dispatch_result()
  def call(name, arguments, opts \\ [])

  def call(name, arguments, opts) when is_binary(name) and is_map(arguments) do
    case validate_arguments(name, arguments) do
      :ok -> {:ok, dispatch(name, arguments, opts)}
      {:error, message} -> {:invalid_params, message}
    end
  end

  def call(name, _arguments, _opts) when is_binary(name), do: {:invalid_params, "arguments for #{name} must be an object"}

  defp dispatch("workflow_validate", arguments, _opts) do
    arguments
    |> Scheduler.validate_workflow()
    |> scheduler_result(&Validation.to_map/1)
  end

  defp dispatch("workflow_start", arguments, _opts) do
    arguments
    |> Scheduler.start_run()
    |> scheduler_result(&RunStart.to_map/1)
  end

  defp dispatch("workflow_status", %{"run_id" => run_id}, _opts) do
    run_id
    |> Scheduler.get_run()
    |> scheduler_result(fn projection -> projection |> RunProjection.to_map() |> conform_projection() end)
  end

  defp dispatch("workflow_inspect", %{"run_id" => run_id}, _opts) do
    run_id
    |> Scheduler.get_run_events()
    |> scheduler_result(fn projection -> projection |> RunEventsProjection.to_map() |> conform_projection() end)
  end

  defp dispatch("workflow_resume", %{"run_id" => run_id} = arguments, _opts) do
    run_id
    |> Scheduler.resume_run(Map.delete(arguments, "run_id"))
    |> scheduler_result(&RunStart.to_map/1)
  end

  defp dispatch("workflow_open_ui", %{"run_id" => run_id}, opts) do
    case Scheduler.get_run(run_id) do
      {:ok, projection} -> open_ui_result(projection, opts)
      {:error, %Error{} = error} -> error_result(error)
    end
  end

  defp scheduler_result({:ok, value}, mapper), do: success_result(mapper.(value))
  defp scheduler_result({:error, %Error{} = error}, _mapper), do: error_result(error)

  defp success_result(data), do: tool_result(%{"api_version" => @api_version, "data" => data}, false)

  defp error_result(%Error{} = error) do
    tool_result(
      %{
        "api_version" => @api_version,
        "error" => %{
          "code" => error.code,
          "message" => error.message,
          "details" => error.details
        }
      },
      true
    )
  end

  defp open_ui_result(projection, opts) do
    data = RunProjection.to_map(projection)
    path = data["uiUrl"] || data["uiPath"]
    base_url = Keyword.get(opts, :base_url, "http://127.0.0.1:47125")
    open_url = base_url |> URI.merge(path) |> URI.to_string()

    tool_result(
      %{
        "api_version" => @mcp_api_version,
        "data" => Map.put(data, "open_url", open_url)
      },
      false
    )
  end

  defp tool_result(payload, error?) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
      "structuredContent" => payload,
      "isError" => error?
    }
  end

  defp conform_projection(data), do: Map.take(data, @projection_fields)

  defp validate_arguments("workflow_validate", arguments) do
    with :ok <- known_fields(arguments, ~w[script_path workspace_root args]),
         :ok <- required_string(arguments, "script_path") do
      optional_workspace_root(arguments)
    end
  end

  defp validate_arguments("workflow_start", arguments) do
    with :ok <- known_fields(arguments, ~w[script_path workspace_root run_id provider budget args]),
         :ok <- required_string(arguments, "script_path"),
         :ok <- optional_workspace_root(arguments),
         :ok <- optional_run_id(arguments),
         :ok <- optional_provider(arguments) do
      optional_budget(arguments)
    end
  end

  defp validate_arguments(name, arguments) when name in ~w[workflow_status workflow_inspect workflow_open_ui] do
    with :ok <- known_fields(arguments, ~w[run_id]) do
      required_run_id(arguments)
    end
  end

  defp validate_arguments("workflow_resume", arguments) do
    with :ok <- known_fields(arguments, ~w[run_id script_path script workspace_root provider]),
         :ok <- required_run_id(arguments),
         :ok <- one_script_field(arguments),
         :ok <- optional_string(arguments, "script_path"),
         :ok <- optional_string(arguments, "script"),
         :ok <- optional_workspace_root(arguments) do
      optional_provider(arguments)
    end
  end

  defp validate_arguments(name, _arguments), do: {:error, "unknown tool: #{name}"}

  defp one_script_field(%{"script_path" => _path, "script" => _alias}),
    do: {:error, "script and script_path cannot both be provided"}

  defp one_script_field(_arguments), do: :ok

  defp known_fields(arguments, allowed) do
    unknown = arguments |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort()

    case unknown do
      [] -> :ok
      fields -> {:error, "unexpected argument fields: #{Enum.join(fields, ", ")}"}
    end
  end

  defp required_string(arguments, field) do
    case Map.fetch(arguments, field) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> :ok
      _missing_or_invalid -> {:error, "#{field} must be a non-empty string"}
    end
  end

  defp optional_string(arguments, field) do
    case Map.fetch(arguments, field) do
      :error -> :ok
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> :ok
      {:ok, _invalid} -> {:error, "#{field} must be a non-empty string when provided"}
    end
  end

  defp required_run_id(arguments) do
    with :ok <- required_string(arguments, "run_id") do
      run_id(arguments["run_id"])
    end
  end

  defp optional_run_id(arguments) do
    case Map.fetch(arguments, "run_id") do
      :error -> :ok
      {:ok, value} -> run_id(value)
    end
  end

  defp run_id(value) when is_binary(value) do
    if byte_size(value) <= @max_run_id_bytes and String.valid?(value) and
         Regex.match?(@run_id_pattern, value),
       do: :ok,
       else: {:error, "run_id must be route-safe and at most #{@max_run_id_bytes} bytes"}
  end

  defp run_id(_value), do: {:error, "run_id must be a non-empty string"}

  defp optional_provider(arguments) do
    case Map.fetch(arguments, "provider") do
      :error -> :ok
      {:ok, provider} when provider in ["mock", "codex"] -> :ok
      {:ok, _invalid} -> {:error, "provider must be either mock or codex"}
    end
  end

  defp optional_budget(arguments) do
    case Map.fetch(arguments, "budget") do
      :error -> :ok
      {:ok, budget} when is_integer(budget) and budget >= 0 -> :ok
      {:ok, _invalid} -> {:error, "budget must be a non-negative integer"}
    end
  end

  defp optional_workspace_root(arguments) do
    case Map.fetch(arguments, "workspace_root") do
      :error ->
        :ok

      {:ok, root} when is_binary(root) and byte_size(root) > 0 ->
        if Path.type(root) == :absolute,
          do: :ok,
          else: {:error, "workspace_root must be an absolute path"}

      {:ok, _invalid} ->
        {:error, "workspace_root must be a non-empty absolute path when provided"}
    end
  end

  defp run_schema, do: schema(%{"run_id" => @run_id_schema}, ["run_id"])

  defp schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp tool(name, description, input_schema) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => input_schema
    }
  end
end
