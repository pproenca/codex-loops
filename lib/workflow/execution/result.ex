defmodule Workflow.Execution.Result.Ok do
  @moduledoc false

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}
end

defmodule Workflow.Execution.Result.Exception do
  @moduledoc false

  @enforce_keys [:exception, :stacktrace]
  defstruct [:exception, :stacktrace]

  @type t :: %__MODULE__{exception: Exception.t(), stacktrace: Exception.stacktrace()}
end

defmodule Workflow.Execution.Result.Exit do
  @moduledoc false

  @enforce_keys [:reason]
  defstruct [:reason]

  @type t :: %__MODULE__{reason: term()}
end

defmodule Workflow.Execution.Result.Timeout do
  @moduledoc false

  defstruct []

  @type t :: %__MODULE__{}
end

defmodule Workflow.Execution.Result do
  @moduledoc false

  import Kernel, except: [exit: 1]

  alias Workflow.Execution.Result.Exit
  alias Workflow.Execution.Result.Ok
  alias Workflow.Execution.Result.Timeout

  @type t ::
          Ok.t()
          | Workflow.Execution.Result.Exception.t()
          | Exit.t()
          | Timeout.t()

  @spec ok(term()) :: t()
  def ok(value), do: %Ok{value: value}

  @spec exception(Exception.t(), Exception.stacktrace()) :: t()
  def exception(exception, stacktrace) do
    %Workflow.Execution.Result.Exception{exception: exception, stacktrace: stacktrace}
  end

  @spec exit(term()) :: t()
  def exit(reason), do: %Exit{reason: reason}

  @spec timeout() :: t()
  def timeout, do: %Timeout{}

  @spec fatal?(t()) :: boolean()
  def fatal?(%Ok{}), do: false
  def fatal?(%Workflow.Execution.Result.Exception{}), do: true
  def fatal?(%Exit{}), do: true
  def fatal?(%Timeout{}), do: true

  @spec fold(t(), function(), function(), function(), function()) :: term()
  def fold(result, on_ok, on_exception, on_exit, on_timeout)

  def fold(%Ok{value: value}, on_ok, _on_exception, _on_exit, _on_timeout), do: on_ok.(value)

  def fold(
        %Workflow.Execution.Result.Exception{exception: exception, stacktrace: stacktrace},
        _on_ok,
        on_exception,
        _on_exit,
        _on_timeout
      ), do: on_exception.(exception, stacktrace)

  def fold(%Exit{reason: reason}, _on_ok, _on_exception, on_exit, _on_timeout), do: on_exit.(reason)

  def fold(%Timeout{}, _on_ok, _on_exception, _on_exit, on_timeout), do: on_timeout.()

  @spec unwrap!(t(), timeout()) :: term()
  def unwrap!(result, timeout)

  def unwrap!(%Ok{value: value}, _timeout), do: value

  def unwrap!(%Workflow.Execution.Result.Exception{exception: exception, stacktrace: stacktrace}, _timeout) do
    reraise exception, stacktrace
  end

  def unwrap!(%Exit{reason: reason}, _timeout) do
    Kernel.exit({:concurrent_workflow_branch_crashed, reason})
  end

  def unwrap!(%Timeout{}, timeout) do
    raise "concurrent workflow branch exceeded #{timeout} ms"
  end
end
