defmodule Workflow.Compiler.Finding do
  @moduledoc """
  A structured, **caller-located** compile-time diagnostic.

  A finding pins the user's `file`/`line` (taken from the offending form's AST
  metadata, falling back to the workflow declaration) and, optionally, a `hint`
  drawn from the closed combinator vocabulary. `format/1` renders it rustc-style so
  the failure at `mix compile` points at the user's own source, not the macro
  internals. The shape is additive — later slices may add fields without breaking
  callers.
  """
  @enforce_keys [:message, :file, :line]
  defstruct [:message, :form, :file, :line, :hint]

  @type t :: %__MODULE__{
          message: String.t(),
          form: Macro.t() | nil,
          file: String.t(),
          line: pos_integer(),
          hint: String.t() | nil
        }

  @doc """
  Build a finding located at `form` (or, when `form` is `nil`/has no line, at the
  workflow declaration carried by `env`). Pass `:hint` for a suggestion line.
  """
  @spec at(Macro.Env.t(), Macro.t() | nil, String.t(), keyword()) :: t()
  def at(env, form, message, opts \\ []) do
    %__MODULE__{
      message: message,
      form: form,
      file: env.file,
      line: form_line(form) || env.line,
      hint: Keyword.get(opts, :hint)
    }
  end

  defp form_line({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp form_line(_), do: nil

  @doc """
  Render a finding as a rustc-style, caller-located diagnostic string.

  With a concrete offending form the output carries the source snippet and a caret
  underline; whole-DSL findings (`form: nil`) render the message and location only.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{form: nil} = f) do
    [f.message, " --> #{location(f)}"]
    |> append_note(f.hint)
    |> Enum.join("\n")
  end

  def format(%__MODULE__{} = f) do
    gutter = Integer.to_string(f.line)
    pad = String.duplicate(" ", String.length(gutter))
    snippet = Macro.to_string(f.form)
    caret = String.duplicate("^", caret_length(snippet))

    [
      f.message,
      "#{pad}--> #{location(f)}",
      "#{pad} |",
      "#{gutter} | #{snippet}",
      "#{pad} | #{caret}"
    ]
    |> append_note(f.hint)
    |> Enum.join("\n")
  end

  defp append_note(lines, nil), do: lines
  defp append_note(lines, hint), do: lines ++ ["   = hint: #{hint}"]

  defp location(%__MODULE__{file: file, line: line}),
    do: "#{Path.relative_to_cwd(file)}:#{line}"

  defp caret_length(snippet) do
    snippet |> String.split("\n") |> List.first() |> String.length() |> max(1)
  end
end
