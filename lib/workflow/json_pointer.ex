defmodule Workflow.JSONPointer do
  @moduledoc """
  RFC 6901 pointer validation and lookup for journaled JSON-shaped values.

  Lookups distinguish a missing path from a present `nil`. String object keys
  take precedence over compatible atom keys, and list positions use canonical
  unsigned decimal indexes (`0`, `1`, ...), never signs or leading zeroes.
  """

  @type resolution :: {:present, term()} | :missing
  @type validation_error :: :not_a_string | :invalid_pointer | :invalid_escape

  @doc "Return whether `pointer` is a valid RFC 6901 JSON Pointer."
  @spec valid?(term()) :: boolean()
  def valid?(pointer), do: validate(pointer) == :ok

  @doc "Validate an RFC 6901 JSON Pointer."
  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(pointer) when is_binary(pointer) do
    case pointer_tokens(pointer) do
      {:ok, _tokens} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_pointer), do: {:error, :not_a_string}

  @doc "Decode one RFC 6901 reference token."
  @spec decode_token(binary()) :: {:ok, binary()} | {:error, :invalid_escape}
  def decode_token(token) when is_binary(token), do: decode_token(token, [])

  @doc "Return whether a token is a canonical, unsigned list index."
  @spec canonical_index?(binary()) :: boolean()
  def canonical_index?("0"), do: true
  def canonical_index?(<<first, rest::binary>>) when first in ?1..?9, do: decimal_digits?(rest)
  def canonical_index?(_token), do: false

  @doc """
  Resolve `pointer` against a JSON-shaped value.

  Existing atom keys are compatible by default without creating atoms. Pass
  `atom_keys: false` when the caller accepts only string-keyed JSON objects.
  """
  @spec resolve(term(), term(), keyword()) :: resolution()
  def resolve(value, pointer, opts \\ []) do
    atom_keys? = Keyword.get(opts, :atom_keys, true)

    case pointer_tokens(pointer) do
      {:ok, tokens} -> resolve_tokens(tokens, value, atom_keys?)
      {:error, _reason} -> :missing
    end
  end

  defp pointer_tokens("") do
    {:ok, []}
  end

  defp pointer_tokens(<<"/", rest::binary>> = pointer) do
    if String.valid?(pointer) do
      rest
      |> :binary.split("/", [:global])
      |> Enum.reduce_while({:ok, []}, fn token, {:ok, decoded} ->
        case decode_token(token) do
          {:ok, token} -> {:cont, {:ok, [token | decoded]}}
          {:error, :invalid_escape} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
        {:error, :invalid_escape} = error -> error
      end
    else
      {:error, :invalid_pointer}
    end
  end

  defp pointer_tokens(pointer) when is_binary(pointer), do: {:error, :invalid_pointer}
  defp pointer_tokens(_pointer), do: {:error, :not_a_string}

  defp decode_token(<<>>, decoded), do: {:ok, decoded |> Enum.reverse() |> IO.iodata_to_binary()}
  defp decode_token(<<"~0", rest::binary>>, decoded), do: decode_token(rest, ["~" | decoded])
  defp decode_token(<<"~1", rest::binary>>, decoded), do: decode_token(rest, ["/" | decoded])
  defp decode_token(<<"~", _rest::binary>>, _decoded), do: {:error, :invalid_escape}

  defp decode_token(<<byte, rest::binary>>, decoded), do: decode_token(rest, [<<byte>> | decoded])

  defp resolve_tokens([], value, _atom_keys?), do: {:present, value}

  defp resolve_tokens([token | tokens], current, atom_keys?) do
    case step(current, token, atom_keys?) do
      {:present, value} -> resolve_tokens(tokens, value, atom_keys?)
      :missing -> :missing
    end
  end

  defp step(current, token, atom_keys?) when is_map(current) do
    case Map.fetch(current, token) do
      {:ok, value} -> {:present, value}
      :error when atom_keys? -> fetch_atom_key(current, token)
      :error -> :missing
    end
  end

  defp step(current, token, _atom_keys?) when is_list(current) do
    with true <- canonical_index?(token),
         {index, ""} <- Integer.parse(token),
         {:ok, value} <- Enum.fetch(current, index) do
      {:present, value}
    else
      _invalid_or_missing -> :missing
    end
  end

  defp step(_current, _token, _atom_keys?), do: :missing

  defp fetch_atom_key(map, token) do
    Enum.find_value(map, :missing, fn
      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == token, do: {:present, value}

      _entry ->
        false
    end)
  end

  defp decimal_digits?(<<>>), do: true
  defp decimal_digits?(<<digit, rest::binary>>) when digit in ?0..?9, do: decimal_digits?(rest)
  defp decimal_digits?(_rest), do: false
end
