defmodule Workflow.Compiler do
  @moduledoc """
  Turns a quoted workflow body into an inert `%Workflow.Tree{}` at compile time.

  This is the whole DSL. It is a plain function — deliberately *not* a macro — so
  it can be unit-tested directly against `quote do ... end` input with no macro
  expansion, and so all parsing/validation lives in one testable place. The
  `workflow/2` macro is a thin shell that calls this and escapes the result.

  Failure modes:

    * a form outside the combinator vocabulary (unknown call, closure, literal,
      anything that is not a recognised combinator) **raises**
      `Workflow.CompileError` — the DSL never permissively accepts unknown code.
    * a recognised combinator called with the wrong shape returns
      `{:error, %Finding{}}` so the caller can surface a located diagnostic
      (precise locations land in a later slice).

  There is no combinator for randomness or wall-clock, so a workflow simply cannot
  express nondeterminism.
  """

  alias Workflow.Tree
  alias Workflow.Node.{Phase, Log, Agent, Return}
  alias Workflow.Compiler.Finding

  @spec parse(Macro.t(), Macro.Env.t()) :: {:ok, Tree.t()} | {:error, Finding.t()}
  def parse(block, _env) do
    block
    |> statements()
    |> build(0, [])
  end

  # A single-statement body is not wrapped in a __block__.
  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(nil), do: []
  defp statements(single), do: [single]

  defp build([], _index, acc), do: {:ok, %Tree{nodes: Enum.reverse(acc)}}

  defp build([stmt | rest], index, acc) do
    case node(stmt, [index]) do
      {:ok, node} -> build(rest, index + 1, [node | acc])
      {:error, finding} -> {:error, finding}
    end
  end

  # --- The closed combinator vocabulary ---

  defp node({:phase, _meta, [name]}, address) when is_binary(name),
    do: {:ok, %Phase{address: address, name: name}}

  defp node({:log, _meta, [message]}, address) when is_binary(message),
    do: {:ok, %Log{address: address, message: message}}

  defp node({:agent, _meta, [prompt]}, address) when is_binary(prompt),
    do: {:ok, %Agent{address: address, prompt: prompt}}

  defp node({:return, _meta, [value]}, address) do
    if Macro.quoted_literal?(value) do
      {:ok, %Return{address: address, value: value}}
    else
      {:error, Finding.new("return expects a literal value", value)}
    end
  end

  # A known combinator invoked with the wrong argument shape: recoverable finding.
  defp node({combinator, _meta, _args} = form, _address)
       when combinator in [:phase, :log, :agent, :return],
       do: {:error, Finding.new("#{combinator} was called with invalid arguments", form)}

  # Anything else is outside the vocabulary — reject the compile outright. This
  # single clause is what makes closures (`fn -> ... end`) and unknown calls
  # impossible to smuggle into the tree.
  defp node(form, _address) do
    raise Workflow.CompileError,
          "unknown workflow form outside the combinator vocabulary: #{Macro.to_string(form)}"
  end
end
