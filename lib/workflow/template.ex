defmodule Workflow.Template do
  @moduledoc """
  An inert `~P` template: literal segments plus ordered assign names.

  Parsing is a hand-rolled binary scanner. Only `<%= @name %>` holes are
  admitted; the template language has no expressions, control flow, or
  interpolation.
  """

  alias Workflow.Compiler.Finding

  @enforce_keys [:segments, :assigns]
  defstruct [:segments, :assigns]

  @type t :: %__MODULE__{segments: [String.t()], assigns: [String.t()]}

  @spec parse(String.t(), Macro.Env.t()) :: {:ok, t()} | {:error, Finding.t()}
  def parse(source, env) when is_binary(source) do
    if String.contains?(source, "\#{") do
      {:error,
       Finding.at(env, nil, "template interpolation is not allowed",
         hint: "use `<%= @name %>` holes over `let` bindings"
       )}
    else
      scan(source, [], [], env)
    end
  end

  @spec to_parts(t(), %{atom() => Workflow.Node.binding_ref()}) :: [Workflow.RenderText.part()]
  def to_parts(%__MODULE__{segments: segments, assigns: assigns}, bindings) do
    [head | tail] = segments

    Enum.zip(assigns, tail)
    |> Enum.reduce([{:text, head}], fn {name, segment}, parts ->
      parts ++ [binding_part(fetch_binding!(name, bindings)), {:text, segment}]
    end)
  end

  defp scan(source, segments, assigns, env) do
    case :binary.match(source, "<%") do
      :nomatch ->
        {:ok,
         %__MODULE__{
           segments: Enum.reverse([source | segments]),
           assigns: Enum.reverse(assigns)
         }}

      {index, 2} ->
        literal = binary_part(source, 0, index)
        rest = binary_part(source, index + 2, byte_size(source) - index - 2)

        case rest do
          <<"=", hole_and_tail::binary>> ->
            case :binary.match(hole_and_tail, "%>") do
              :nomatch ->
                {:error,
                 Finding.at(env, nil, "template hole is missing `%>`",
                   hint: "close every hole as `<%= @name %>`"
                 )}

              {close_index, 2} ->
                hole = binary_part(hole_and_tail, 0, close_index)

                remaining =
                  binary_part(
                    hole_and_tail,
                    close_index + 2,
                    byte_size(hole_and_tail) - close_index - 2
                  )

                with {:ok, assign} <- parse_hole(String.trim(hole), env) do
                  scan(remaining, [literal | segments], [assign | assigns], env)
                end
            end

          _other ->
            {:error,
             Finding.at(env, nil, "only `<%= @name %>` holes are allowed in `~P` templates",
               hint: "statement, comment, and other raw `<% ... %>` tags are not allowed"
             )}
        end
    end
  end

  defp parse_hole("if " <> _rest, env),
    do: {:error, Finding.at(env, nil, "`if` holes are not allowed in `~P` templates")}

  defp parse_hole("if\n" <> _rest, env),
    do: {:error, Finding.at(env, nil, "`if` holes are not allowed in `~P` templates")}

  defp parse_hole("for " <> _rest, env),
    do: {:error, Finding.at(env, nil, "`for` holes are not allowed in `~P` templates")}

  defp parse_hole("for\n" <> _rest, env),
    do: {:error, Finding.at(env, nil, "`for` holes are not allowed in `~P` templates")}

  defp parse_hole(hole, env) do
    case Regex.run(~r/^@([a-zA-Z_][a-zA-Z0-9_]*)$/, hole) do
      [_, assign] ->
        {:ok, assign}

      _ ->
        {:error,
         Finding.at(env, nil, "only `<%= @name %>` holes are allowed in `~P` templates",
           hint: "bind a producer with `let :name = ...`, then reference it as `<%= @name %>`"
         )}
    end
  end

  defp fetch_binding!(name, bindings) do
    case Enum.find(bindings, fn {key, _ref} -> Atom.to_string(key) == name end) do
      {_, ref} -> ref
      nil -> raise ArgumentError, "missing binding for template assign #{inspect(name)}"
    end
  end

  defp binding_part({:node, _address} = ref), do: {:bound_value, ref}
  defp binding_part({:map, _address} = ref), do: {:bound_list, ref}
end
