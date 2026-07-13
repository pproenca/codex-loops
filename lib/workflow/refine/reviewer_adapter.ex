defmodule Workflow.Refine.ReviewerAdapter do
  @moduledoc """
  Closed reviewer adapter schemas and normalizers for refine V1.
  """

  alias Workflow.Refine.Review
  alias Workflow.Refine.ReviewFinding

  @adapters [:findings_v1, :defects_v1, :violations_v1, :concerns_v1]

  @type t :: :findings_v1 | :defects_v1 | :violations_v1 | :concerns_v1

  @spec default() :: t()
  def default, do: :findings_v1

  @spec all() :: [t()]
  def all, do: @adapters

  @spec known?(atom()) :: boolean()
  def known?(adapter), do: adapter in @adapters

  @spec version(t()) :: pos_integer()
  def version(adapter) when adapter in @adapters, do: 1

  @spec schema(t()) :: map()
  def schema(adapter) do
    adapter
    |> config()
    |> schema_for()
  end

  @spec normalize(t(), term()) :: {:ok, Review.t()} | {:error, term()}
  def normalize(adapter, output) when is_map(output) do
    with {:ok, config} <- fetch_config(adapter),
         :ok <- allowed_keys(output, top_level_keys(config), :review_object_unexpected_shape),
         {:ok, approved} <- normalize_approval(output, config),
         {:ok, findings} <- normalize_findings(output, config),
         {:ok, snippets} <- report_snippets(output) do
      {:ok, %Review{approved: approved, findings: findings, report_snippets: snippets}}
    end
  end

  def normalize(_adapter, _output), do: {:error, :review_object_unexpected_shape}

  defp fetch_config(adapter) do
    case config(adapter) do
      nil -> {:error, {:unsupported_reviewer_adapter, adapter}}
      config -> {:ok, config}
    end
  end

  defp config(:findings_v1) do
    %{
      approval_field: "approved",
      approval_kind: :boolean,
      array_field: "findings",
      issue_field: "issue",
      fix_field: "fix",
      item_mode: :blocking_required
    }
  end

  defp config(:defects_v1) do
    %{
      approval_field: "pass",
      approval_kind: :boolean,
      array_field: "defects",
      issue_field: "issue",
      fix_field: "fix",
      item_mode: :blocking_required
    }
  end

  defp config(:violations_v1) do
    %{
      approval_field: "pass",
      approval_kind: :boolean,
      array_field: "violations",
      issue_field: "issue",
      fix_field: "fix",
      item_mode: :severity_fallback
    }
  end

  defp config(:concerns_v1) do
    %{
      approval_field: "verdict",
      approval_kind: :verdict,
      array_field: "concerns",
      issue_field: "concern",
      fix_field: "recommendation",
      item_mode: :blocking_required
    }
  end

  defp config(_adapter), do: nil

  defp schema_for(config) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => [config.approval_field, config.array_field],
      "properties" => %{
        config.approval_field => approval_schema(config),
        "cross_expert_note" => %{"type" => "string"},
        "report_snippet" => %{"type" => "string"},
        config.array_field => %{
          "type" => "array",
          "items" => item_schema(config)
        }
      }
    }
  end

  defp approval_schema(%{approval_kind: :boolean}), do: %{"type" => "boolean"}

  defp approval_schema(%{approval_kind: :verdict}), do: %{"type" => "string", "enum" => ["approve", "changes"]}

  defp item_schema(config) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => item_required(config),
      "properties" => item_properties(config)
    }
  end

  defp item_required(%{item_mode: :blocking_required} = config),
    do: ["id", "blocking", config.issue_field, config.fix_field]

  defp item_required(%{item_mode: :severity_fallback} = config), do: ["id", config.issue_field, config.fix_field]

  defp item_properties(config) do
    properties = %{
      "id" => %{"type" => "string"},
      "blocking" => %{"type" => "boolean"},
      config.issue_field => %{"type" => "string"},
      config.fix_field => %{"type" => "string"}
    }

    include_severity(properties, config.item_mode)
  end

  defp include_severity(properties, :blocking_required), do: properties
  defp include_severity(properties, :severity_fallback), do: Map.put(properties, "severity", %{"type" => "string"})

  defp top_level_keys(config), do: [config.approval_field, config.array_field, "cross_expert_note", "report_snippet"]

  defp allowed_keys(map, allowed, reason) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)), do: :ok, else: {:error, reason}
  end

  defp normalize_approval(output, %{approval_kind: :boolean, approval_field: field}) do
    case Map.fetch(output, field) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, :review_approval_unexpected_shape}
      :error -> {:error, {:missing_required, field}}
    end
  end

  defp normalize_approval(output, %{approval_kind: :verdict, approval_field: field}) do
    case Map.fetch(output, field) do
      {:ok, "approve"} -> {:ok, true}
      {:ok, "changes"} -> {:ok, false}
      {:ok, _value} -> {:error, :review_approval_unexpected_shape}
      :error -> {:error, {:missing_required, field}}
    end
  end

  defp normalize_findings(output, %{array_field: field} = config) do
    case Map.fetch(output, field) do
      {:ok, items} -> normalize_items(items, config)
      :error -> {:error, {:missing_required, field}}
    end
  end

  defp normalize_items(items, config) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_item(item, config) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp normalize_items(_items, _config), do: {:error, :review_findings_unexpected_shape}

  defp normalize_item(item, config) when is_map(item) do
    with :ok <- allowed_keys(item, item_keys(config), :review_finding_unexpected_shape),
         {:ok, id} <- non_empty_string(item, "id", :review_finding_invalid_text),
         {:ok, issue} <- non_empty_string(item, config.issue_field, :review_finding_invalid_text),
         {:ok, fix} <- non_empty_string(item, config.fix_field, :review_finding_invalid_text),
         {:ok, blocking} <- normalize_blocking(item, config) do
      {:ok, %ReviewFinding{id: id, blocking: blocking, issue: issue, fix: fix}}
    end
  end

  defp normalize_item(_item, _config), do: {:error, :review_finding_unexpected_shape}

  defp item_keys(config) do
    keys = ["id", "blocking", config.issue_field, config.fix_field]
    include_severity_key(keys, config.item_mode)
  end

  defp include_severity_key(keys, :blocking_required), do: keys
  defp include_severity_key(keys, :severity_fallback), do: ["severity" | keys]

  defp normalize_blocking(item, %{item_mode: :blocking_required}) do
    case Map.fetch(item, "blocking") do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _other -> {:error, :review_finding_unexpected_shape}
    end
  end

  defp normalize_blocking(item, %{item_mode: :severity_fallback}) do
    with {:ok, severity} <- optional_severity(item) do
      case Map.fetch(item, "blocking") do
        {:ok, value} when is_boolean(value) -> {:ok, value}
        :error -> {:ok, severity_blocking?(severity)}
        _other -> {:error, :review_finding_unexpected_shape}
      end
    end
  end

  defp optional_severity(item) do
    case Map.fetch(item, "severity") do
      {:ok, severity} when is_binary(severity) ->
        if String.valid?(severity),
          do: {:ok, severity},
          else: {:error, :review_finding_unexpected_shape}

      {:ok, _severity} ->
        {:error, :review_finding_unexpected_shape}

      :error ->
        {:ok, nil}
    end
  end

  defp severity_blocking?(severity) when severity in ["blocker", "blocking", "critical", "error"], do: true

  defp severity_blocking?(_severity), do: false

  defp non_empty_string(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if value != "" and String.valid?(value), do: {:ok, value}, else: {:error, reason}

      _other ->
        {:error, reason}
    end
  end

  defp report_snippets(output) do
    ["cross_expert_note", "report_snippet"]
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case Map.fetch(output, key) do
        {:ok, ""} ->
          {:cont, {:ok, acc}}

        {:ok, value} when is_binary(value) ->
          if String.valid?(value) do
            {:cont, {:ok, [value | acc]}}
          else
            {:halt, {:error, :review_report_snippet_invalid_text}}
          end

        {:ok, _value} ->
          {:halt, {:error, :review_report_snippet_invalid_text}}

        :error ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end
end
