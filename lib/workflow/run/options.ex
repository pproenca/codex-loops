defmodule Workflow.Run.Options do
  @moduledoc "A validated request to execute one compiled workflow tree."

  alias Workflow.Provider

  @enforce_keys [:run_id, :provider, :budget, :script_path]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          run_id: String.t(),
          provider: Provider.t(),
          budget: non_neg_integer() | nil,
          script_path: String.t() | nil
        }

  @type option ::
          {:run_id, String.t()}
          | {:provider, Provider.t()}
          | {:budget, non_neg_integer()}
          | {:script_path, String.t()}

  @spec from_keyword([option()]) :: {:ok, t()} | {:error, term()}
  def from_keyword(options) when is_list(options) do
    with {:ok, run_id} <- run_id(Keyword.get(options, :run_id)),
         {:ok, provider} <- Provider.resolve(Keyword.get(options, :provider)),
         {:ok, budget} <- budget(Keyword.get(options, :budget)),
         {:ok, script_path} <- script_path(Keyword.get(options, :script_path)) do
      {:ok,
       %__MODULE__{
         run_id: run_id,
         provider: provider,
         budget: budget,
         script_path: script_path
       }}
    end
  end

  @spec generate_run_id() :: String.t()
  def generate_run_id, do: "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp run_id(nil), do: {:ok, generate_run_id()}
  defp run_id(run_id) when is_binary(run_id) and byte_size(run_id) > 0, do: {:ok, :binary.copy(run_id)}
  defp run_id(_invalid), do: {:error, {:usage, :run_id}}

  defp budget(nil), do: {:ok, nil}
  defp budget(budget) when is_integer(budget) and budget >= 0, do: {:ok, budget}
  defp budget(_invalid), do: {:error, {:usage, :budget}}

  defp script_path(nil), do: {:ok, nil}
  defp script_path(path) when is_binary(path) and byte_size(path) > 0, do: {:ok, :binary.copy(path)}
  defp script_path(_invalid), do: {:error, {:usage, :script_path}}
end
