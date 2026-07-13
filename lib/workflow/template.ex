defmodule Workflow.Template do
  @moduledoc """
  An inert `~P` template: literal segments plus parsed holes.

  Parsing is a hand-rolled binary scanner. Only `<%= @name %>` and the adopted
  formatter holes are admitted; the template language has no expressions,
  control flow, or interpolation.
  """

  alias __MODULE__.Hole
  alias Workflow.Compiler.Finding
  alias Workflow.JSONPointer

  defmodule Hole do
    @moduledoc "A parsed, inert template hole."

    @enforce_keys [:op, :assign, :args]
    defstruct [:op, :assign, :args]

    @type op :: :identity | :path | :flatten | :count | :numbered_findings | :truncate
    @type t :: %__MODULE__{op: op(), assign: String.t(), args: map()}
  end

  @enforce_keys [:segments, :holes, :assigns]
  defstruct [:segments, :holes, :assigns]

  @type t :: %__MODULE__{
          segments: [String.t()],
          holes: [Hole.t()],
          assigns: [String.t()]
        }

  @spec parse(String.t(), Macro.Env.t()) :: {:ok, t()} | {:error, Finding.t()}
  def parse(source, env) when is_binary(source) do
    if String.contains?(source, "\#{") do
      {:error,
       Finding.at(env, nil, "template interpolation is not allowed", hint: "use `<%= @name %>` holes over `let` bindings")}
    else
      scan(source, [], [], env)
    end
  end

  @spec to_parts(t(), %{atom() => Workflow.Node.binding_ref()}) :: [Workflow.RenderText.part()]
  def to_parts(%__MODULE__{segments: segments, holes: holes}, bindings) do
    [head | tail] = segments

    formatted =
      holes
      |> Enum.zip(tail)
      |> Enum.flat_map(fn {%Hole{} = hole, segment} ->
        ref = fetch_binding!(hole.assign, bindings)
        [hole_part(hole, binding_part(ref)), {:text, segment}]
      end)

    [{:text, head} | formatted]
  end

  defp scan(source, segments, holes, env) do
    case :binary.match(source, "<%") do
      :nomatch ->
        {:ok, retain_template([source | segments], holes)}

      {index, 2} ->
        literal = binary_part(source, 0, index)
        rest = binary_part(source, index + 2, byte_size(source) - index - 2)

        case rest do
          <<"=", hole_and_tail::binary>> ->
            case :binary.match(hole_and_tail, "%>") do
              :nomatch ->
                {:error,
                 Finding.at(env, nil, "template hole is missing `%>`", hint: "close every hole as `<%= @name %>`")}

              {close_index, 2} ->
                hole = binary_part(hole_and_tail, 0, close_index)

                remaining =
                  binary_part(
                    hole_and_tail,
                    close_index + 2,
                    byte_size(hole_and_tail) - close_index - 2
                  )

                with {:ok, %Hole{} = parsed} <- parse_hole(trim_template_ws(hole), env) do
                  scan(remaining, [literal | segments], [parsed | holes], env)
                end
            end

          _other ->
            {:error,
             Finding.at(
               env,
               nil,
               "only `<%= @name %>` or closed formatter holes are allowed in `~P` templates",
               hint: "statement, comment, and other raw `<% ... %>` tags are not allowed"
             )}
        end
    end
  end

  defp parse_hole("if " <> _rest, env), do: {:error, Finding.at(env, nil, "`if` holes are not allowed in `~P` templates")}

  defp parse_hole("if\n" <> _rest, env),
    do: {:error, Finding.at(env, nil, "`if` holes are not allowed in `~P` templates")}

  defp parse_hole("for " <> _rest, env),
    do: {:error, Finding.at(env, nil, "`for` holes are not allowed in `~P` templates")}

  defp parse_hole("for\n" <> _rest, env),
    do: {:error, Finding.at(env, nil, "`for` holes are not allowed in `~P` templates")}

  defp parse_hole(hole, env) do
    case Regex.run(~r/^@([a-zA-Z_][a-zA-Z0-9_]*)$/, hole) do
      [_, assign] ->
        {:ok, %Hole{op: :identity, assign: assign, args: %{}}}

      _ ->
        parse_formatter_hole(hole, env)
    end
  end

  defp parse_formatter_hole(hole, env) do
    formatter =
      Regex.run(
        ~r/\A([a-z_][a-z0-9_]*)[ \t\r\n]*\([ \t\r\n]*@([A-Za-z_][A-Za-z0-9_]*)(?:[ \t\r\n]*,[ \t\r\n]*(.*))?[ \t\r\n]*\)\z/s,
        hole
      )

    case formatter do
      [_, op, assign] -> formatter_hole(op, assign, nil, env)
      [_, op, assign, arg] -> formatter_hole(op, assign, trim_template_ws(arg), env)
      _other -> unsupported_hole(env)
    end
  end

  defp formatter_hole("path", assign, arg, env) when is_binary(arg) do
    with {:ok, pointer} <- pointer_arg(arg, env) do
      {:ok, %Hole{op: :path, assign: assign, args: %{pointer: pointer}}}
    end
  end

  defp formatter_hole("flatten", assign, nil, _env), do: {:ok, %Hole{op: :flatten, assign: assign, args: %{pointer: ""}}}

  defp formatter_hole("flatten", assign, arg, env) when is_binary(arg) do
    with {:ok, pointer} <- pointer_arg(arg, env) do
      {:ok, %Hole{op: :flatten, assign: assign, args: %{pointer: pointer}}}
    end
  end

  defp formatter_hole("count", assign, nil, _env), do: {:ok, %Hole{op: :count, assign: assign, args: %{pointer: ""}}}

  defp formatter_hole("count", assign, arg, env) when is_binary(arg) do
    with {:ok, pointer} <- pointer_arg(arg, env) do
      {:ok, %Hole{op: :count, assign: assign, args: %{pointer: pointer}}}
    end
  end

  defp formatter_hole("numbered_findings", assign, nil, _env),
    do: {:ok, %Hole{op: :numbered_findings, assign: assign, args: %{pointer: ""}}}

  defp formatter_hole("numbered_findings", assign, arg, env) when is_binary(arg) do
    with {:ok, pointer} <- pointer_arg(arg, env) do
      {:ok, %Hole{op: :numbered_findings, assign: assign, args: %{pointer: pointer}}}
    end
  end

  defp formatter_hole("truncate", assign, arg, env) when is_binary(arg) do
    with {:ok, max_bytes} <- non_negative_integer_arg(arg, env) do
      {:ok, %Hole{op: :truncate, assign: assign, args: %{max_bytes: max_bytes}}}
    end
  end

  defp formatter_hole(_op, _assign, _arg, env), do: unsupported_hole(env)

  defp pointer_arg(source, env) do
    with {:ok, pointer} <- quoted_string(source),
         :ok <- JSONPointer.validate(pointer) do
      {:ok, pointer}
    else
      _error ->
        {:error,
         Finding.at(env, nil, "invalid JSON pointer in template formatter",
           hint: "use an empty pointer or one that starts with `/` and only escapes `~0` and `~1`"
         )}
    end
  end

  defp quoted_string(<<"\"", rest::binary>>), do: quoted_string(rest, [])
  defp quoted_string(_other), do: :error

  defp quoted_string(<<"\"">>, acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
  defp quoted_string(<<"\"", _rest::binary>>, _acc), do: :error
  defp quoted_string(<<"\\\"", rest::binary>>, acc), do: quoted_string(rest, ["\"" | acc])
  defp quoted_string(<<"\\\\", rest::binary>>, acc), do: quoted_string(rest, ["\\" | acc])
  defp quoted_string(<<"\\", _rest::binary>>, _acc), do: :error

  defp quoted_string(<<char::utf8, rest::binary>>, acc), do: quoted_string(rest, [<<char::utf8>> | acc])

  defp quoted_string(_invalid, _acc), do: :error

  defp non_negative_integer_arg(source, env) do
    source = trim_template_ws(source)

    if integer_literal?(source) do
      {:ok, integer_literal_value(source)}
    else
      {:error,
       Finding.at(env, nil, "truncate formatter expects a non-negative integer", hint: "write `truncate(@name, 4000)`")}
    end
  end

  defp trim_template_ws(source) do
    source
    |> trim_leading_template_ws()
    |> trim_trailing_template_ws()
  end

  defp trim_leading_template_ws(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r],
    do: trim_leading_template_ws(rest)

  defp trim_leading_template_ws(source), do: source

  defp trim_trailing_template_ws(source), do: trim_trailing_template_ws(source, byte_size(source))
  defp trim_trailing_template_ws(source, 0), do: source

  defp trim_trailing_template_ws(source, size) do
    prefix_size = size - 1
    <<rest::binary-size(prefix_size), char>> = source

    if char in [?\s, ?\t, ?\n, ?\r] do
      trim_trailing_template_ws(rest, byte_size(rest))
    else
      source
    end
  end

  defp integer_literal?(source) do
    Regex.match?(
      ~r/\A(?:[0-9](?:_?[0-9])*|0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*)\z/,
      source
    )
  end

  defp integer_literal_value("0x" <> digits), do: digits |> strip_separators() |> String.to_integer(16)

  defp integer_literal_value("0o" <> digits), do: digits |> strip_separators() |> String.to_integer(8)

  defp integer_literal_value("0b" <> digits), do: digits |> strip_separators() |> String.to_integer(2)

  defp integer_literal_value(digits), do: digits |> strip_separators() |> String.to_integer(10)

  defp strip_separators(source), do: String.replace(source, "_", "")

  defp unsupported_hole(env) do
    {:error,
     Finding.at(
       env,
       nil,
       "only `<%= @name %>` or closed formatter holes are allowed in `~P` templates",
       hint: "use `@name`, `path`, `flatten`, `count`, `numbered_findings`, or `truncate` over an assign"
     )}
  end

  defp fetch_binding!(name, bindings) do
    case Enum.find(bindings, fn {key, _ref} -> Atom.to_string(key) == name end) do
      {_, ref} -> ref
      nil -> raise ArgumentError, "missing binding for template assign #{inspect(name)}"
    end
  end

  defp binding_part({:node, _address} = ref), do: {:bound_value, ref}
  defp binding_part({:refine, _address} = ref), do: {:bound_value, ref}
  defp binding_part({:map, _address} = ref), do: {:bound_list, ref}
  defp binding_part({:fanout, _address, _scope} = ref), do: {:bound_list, ref}

  defp hole_part(%Hole{op: :identity}, value_part), do: value_part
  defp hole_part(%Hole{} = hole, value_part), do: {:formatter, hole, value_part}

  defp retain_hole(%Hole{assign: assign, args: %{pointer: pointer}} = hole) do
    %{hole | assign: :binary.copy(assign), args: %{pointer: :binary.copy(pointer)}}
  end

  defp retain_hole(%Hole{assign: assign} = hole), do: %{hole | assign: :binary.copy(assign)}

  defp retain_template(segments, holes) do
    holes = holes |> Enum.reverse() |> Enum.map(&retain_hole/1)

    %__MODULE__{
      segments: segments |> Enum.reverse() |> Enum.map(&:binary.copy/1),
      holes: holes,
      assigns: Enum.map(holes, & &1.assign)
    }
  end
end
