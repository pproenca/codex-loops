defmodule Workflow.Provider.Activity do
  @moduledoc "Normalized provider progress retained by the scheduler."

  @enforce_keys [:kind, :label, :status]
  defstruct [:kind, :label, :summary, :activity_index, :status]

  @type status :: :running | :completed | :failed | :rejected
  @type t :: %__MODULE__{
          kind: String.t(),
          label: String.t(),
          summary: String.t() | nil,
          status: status(),
          activity_index: non_neg_integer() | nil
        }

  @statuses %{
    "running" => :running,
    "completed" => :completed,
    "failed" => :failed,
    "rejected" => :rejected,
    running: :running,
    completed: :completed,
    failed: :failed,
    rejected: :rejected
  }

  @spec normalize(term()) :: {:ok, t()} | {:error, :invalid_activity}
  def normalize(%__MODULE__{} = activity), do: {:ok, copy(activity)}

  def normalize(activity) when is_map(activity) do
    with kind when is_binary(kind) <- field(activity, :kind),
         label when is_binary(label) <- field(activity, :label),
         summary when is_binary(summary) or is_nil(summary) <- field(activity, :summary),
         {:ok, status} <- Map.fetch(@statuses, field(activity, :status)),
         index when (is_integer(index) and index >= 0) or is_nil(index) <-
           field(activity, :activity_index) do
      {:ok,
       %__MODULE__{
         kind: :binary.copy(kind),
         label: :binary.copy(label),
         summary: copy_binary(summary),
         status: status,
         activity_index: index
       }}
    else
      _invalid -> {:error, :invalid_activity}
    end
  end

  def normalize(_activity), do: {:error, :invalid_activity}

  @spec normalize!(term()) :: t()
  def normalize!(activity) do
    case normalize(activity) do
      {:ok, normalized} -> normalized
      {:error, :invalid_activity} -> raise ArgumentError, "invalid provider activity: #{inspect(activity)}"
    end
  end

  @spec normalize_all!([term()]) :: [t()]
  def normalize_all!(activity) when is_list(activity), do: Enum.map(activity, &normalize!/1)

  @doc "Convert normalized activity to its atom-keyed durable journal representation."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = activity), do: Map.from_struct(activity)

  @spec with_index(t(), non_neg_integer()) :: t()
  def with_index(%__MODULE__{} = activity, index) when is_integer(index) and index >= 0,
    do: %{activity | activity_index: index}

  @spec without_index(t()) :: t()
  def without_index(%__MODULE__{} = activity), do: %{activity | activity_index: nil}

  @doc "Convert normalized provider activity to its JSON-safe public representation."
  @spec to_public_map(t()) :: %{required(String.t()) => String.t() | non_neg_integer() | nil}
  def to_public_map(%__MODULE__{} = activity) do
    put_activity_index(
      %{
        "kind" => activity.kind,
        "label" => activity.label,
        "summary" => activity.summary,
        "status" => Atom.to_string(activity.status)
      },
      activity.activity_index
    )
  end

  defp copy(%__MODULE__{} = activity) do
    %{
      activity
      | kind: :binary.copy(activity.kind),
        label: :binary.copy(activity.label),
        summary: copy_binary(activity.summary)
    }
  end

  defp copy_binary(nil), do: nil
  defp copy_binary(value), do: :binary.copy(value)

  defp put_activity_index(activity, nil), do: activity
  defp put_activity_index(activity, index), do: Map.put(activity, "activity_index", index)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
