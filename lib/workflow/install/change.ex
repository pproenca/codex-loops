defmodule Workflow.Install.Change do
  @moduledoc false

  @enforce_keys [:name, :rollback]
  defstruct [:name, :rollback, commit: &__MODULE__.no_op/0]

  @type callback :: (-> :ok | {:error, term()})
  @type t :: %__MODULE__{name: String.t(), rollback: callback(), commit: callback()}

  @spec new(String.t(), callback(), callback()) :: t()
  def new(name, rollback, commit \\ &__MODULE__.no_op/0)
      when is_binary(name) and is_function(rollback, 0) and is_function(commit, 0) do
    %__MODULE__{name: name, rollback: rollback, commit: commit}
  end

  @doc false
  def no_op, do: :ok
end
