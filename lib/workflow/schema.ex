defmodule Workflow.Schema.Object do
  @moduledoc false
  @enforce_keys [:attributes]
  defstruct [:attributes]

  @type t :: %__MODULE__{attributes: %{optional(String.t()) => Workflow.Schema.value()}}
end

defmodule Workflow.Schema.String do
  @moduledoc false
  @enforce_keys [:attributes]
  defstruct [:attributes]

  @type t :: %__MODULE__{attributes: %{optional(String.t()) => Workflow.Schema.value()}}
end

defmodule Workflow.Schema.Integer do
  @moduledoc false
  @enforce_keys [:attributes]
  defstruct [:attributes]

  @type t :: %__MODULE__{attributes: %{optional(String.t()) => Workflow.Schema.value()}}
end

defmodule Workflow.Schema.Number do
  @moduledoc false
  @enforce_keys [:attributes]
  defstruct [:attributes]

  @type t :: %__MODULE__{attributes: %{optional(String.t()) => Workflow.Schema.value()}}
end

defmodule Workflow.Schema.Boolean do
  @moduledoc false
  @enforce_keys [:attributes]
  defstruct [:attributes]

  @type t :: %__MODULE__{attributes: %{optional(String.t()) => Workflow.Schema.value()}}
end

defmodule Workflow.Schema.Array do
  @moduledoc false
  @enforce_keys [:attributes]
  defstruct [:attributes]

  @type t :: %__MODULE__{attributes: %{optional(String.t()) => Workflow.Schema.value()}}
end

defmodule Workflow.Schema.Extension do
  @moduledoc "An unrecognized JSON-schema form retained without constraining output."
  @enforce_keys [:attributes]
  defstruct [:attributes]

  @type t :: %__MODULE__{attributes: %{optional(String.t()) => Workflow.Schema.value()}}
end

defprotocol Workflow.Schema.Variant do
  @moduledoc false

  @spec validate(t(), term()) :: :ok | {:error, term()}
  def validate(schema, value)

  @spec to_map(t()) :: map()
  def to_map(schema)

  @spec strict_map(t()) :: map()
  def strict_map(schema)
end

defmodule Workflow.Schema do
  @moduledoc """
  Normalizes raw JSON-schema maps and validates decoded provider results.

  A raw author-supplied map crosses the compiler boundary once and becomes a
  named schema variant. Validation and provider serialization then dispatch on
  that variant through `Workflow.Schema.Variant`. Unknown forms become an
  explicit `Workflow.Schema.Extension`, preserving the forward-compatible rule
  that unrecognized vocabulary does not reject output.

  This is the fail-closed gate for the structured-output subset used by
  workflows: `object`, `string`, `integer`, `number`, `boolean`, and `array`.
  """

  alias Workflow.Schema.Array
  alias Workflow.Schema.Boolean
  alias Workflow.Schema.Extension
  alias Workflow.Schema.Integer
  alias Workflow.Schema.Number
  alias Workflow.Schema.Object
  alias Workflow.Schema.String, as: StringSchema
  alias Workflow.Schema.Variant

  @type t ::
          Object.t()
          | StringSchema.t()
          | Integer.t()
          | Number.t()
          | Boolean.t()
          | Array.t()
          | Extension.t()
  @type scalar :: nil | boolean() | number() | String.t()
  @type value :: t() | scalar() | [value()]

  @spec new(map() | t()) :: t()
  def new(%Object{} = schema), do: schema
  def new(%StringSchema{} = schema), do: schema
  def new(%Integer{} = schema), do: schema
  def new(%Number{} = schema), do: schema
  def new(%Boolean{} = schema), do: schema
  def new(%Array{} = schema), do: schema
  def new(%Extension{} = schema), do: schema

  def new(%{"type" => "object"} = attributes), do: %Object{attributes: normalize_attributes(attributes)}
  def new(%{"type" => "string"} = attributes), do: %StringSchema{attributes: normalize_attributes(attributes)}
  def new(%{"type" => "integer"} = attributes), do: %Integer{attributes: normalize_attributes(attributes)}
  def new(%{"type" => "number"} = attributes), do: %Number{attributes: normalize_attributes(attributes)}
  def new(%{"type" => "boolean"} = attributes), do: %Boolean{attributes: normalize_attributes(attributes)}
  def new(%{"type" => "array"} = attributes), do: %Array{attributes: normalize_attributes(attributes)}
  def new(attributes) when is_map(attributes), do: %Extension{attributes: normalize_attributes(attributes)}

  @spec validate(t(), term()) :: {:ok, term()} | {:error, term()}
  def validate(schema, value) do
    case Variant.validate(schema, value) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  @spec to_map(t()) :: map()
  def to_map(schema), do: Variant.to_map(schema)

  @doc "Returns the strict JSON schema handed to Codex structured output."
  @spec strict_map(t()) :: map()
  def strict_map(schema), do: Variant.strict_map(schema)

  @doc false
  @spec attribute(t(), String.t(), term()) :: term()
  def attribute(%{attributes: attributes}, key, default), do: Map.get(attributes, key, default)

  @doc false
  @spec attributes_to_map(t()) :: map()
  def attributes_to_map(%{attributes: attributes}) do
    Map.new(attributes, fn {key, value} -> {key, external_value(value)} end)
  end

  @doc false
  @spec strict_attributes(t()) :: map()
  def strict_attributes(%{attributes: attributes}) do
    Map.new(attributes, fn {key, value} -> {key, strict_value(value)} end)
  end

  @doc false
  @spec extension_entries(Extension.t()) :: map()
  def extension_entries(%Extension{attributes: attributes}), do: attributes

  @doc false
  @spec validate_value(value(), term()) :: :ok | {:error, term()}
  def validate_value(%_{} = schema, value), do: Variant.validate(schema, value)
  def validate_value(_extension_value, _value), do: :ok

  @doc false
  @spec strict_value(value()) :: term()
  def strict_value(%_{} = schema), do: Variant.strict_map(schema)
  def strict_value(values) when is_list(values), do: Enum.map(values, &strict_value/1)
  def strict_value(value), do: value

  @doc false
  @spec check_required([String.t()], map()) :: :ok | {:error, term()}
  def check_required(required, map) do
    case Enum.find(required, fn key -> not Map.has_key?(map, key) end) do
      nil -> :ok
      missing -> {:error, {:missing_required, missing}}
    end
  end

  @doc false
  @spec check_properties(Extension.t(), map()) :: :ok | {:error, term()}
  def check_properties(properties, map) do
    properties
    |> extension_entries()
    |> Enum.reduce_while(:ok, fn {key, sub_schema}, :ok ->
      case Map.fetch(map, key) do
        {:ok, value} ->
          case validate_value(sub_schema, value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:property, key, reason}}}
          end

        :error ->
          {:cont, :ok}
      end
    end)
  end

  @doc false
  @spec check_each(value(), list()) :: :ok | {:error, term()}
  def check_each(item_schema, list) do
    Enum.reduce_while(list, :ok, fn element, :ok ->
      case validate_value(item_schema, element) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:item, reason}}}
      end
    end)
  end

  defp normalize_attributes(attributes) do
    Map.new(attributes, fn {key, value} -> {key, normalize_value(value)} end)
  end

  defp normalize_value(value) when is_map(value), do: new(value)
  defp normalize_value(values) when is_list(values), do: Enum.map(values, &normalize_value/1)
  defp normalize_value(value), do: value

  defp external_value(%_{} = schema), do: Variant.to_map(schema)
  defp external_value(values) when is_list(values), do: Enum.map(values, &external_value/1)
  defp external_value(value), do: value
end

defimpl Workflow.Schema.Variant, for: Workflow.Schema.Object do
  alias Workflow.Schema
  alias Workflow.Schema.Extension

  def validate(schema, value) when is_map(value) do
    required = Schema.attribute(schema, "required", [])
    properties = Schema.attribute(schema, "properties", %Extension{attributes: %{}})

    with :ok <- Schema.check_required(required, value) do
      Schema.check_properties(properties, value)
    end
  end

  def validate(_schema, value), do: {:error, {:expected_object, value}}

  def to_map(schema), do: Schema.attributes_to_map(schema)

  def strict_map(schema) do
    properties = Schema.attribute(schema, "properties", %Extension{attributes: %{}})

    schema
    |> Schema.attributes_to_map()
    |> Map.put("properties", Schema.strict_value(properties))
    |> Map.put("additionalProperties", false)
  end
end

defimpl Workflow.Schema.Variant, for: Workflow.Schema.String do
  alias Workflow.Schema

  def validate(_schema, value) when is_binary(value), do: :ok
  def validate(_schema, value), do: {:error, {:expected_string, value}}
  def to_map(schema), do: Schema.attributes_to_map(schema)
  def strict_map(schema), do: Schema.strict_attributes(schema)
end

defimpl Workflow.Schema.Variant, for: Workflow.Schema.Integer do
  alias Workflow.Schema

  def validate(_schema, value) when is_integer(value), do: :ok
  def validate(_schema, value), do: {:error, {:expected_integer, value}}
  def to_map(schema), do: Schema.attributes_to_map(schema)
  def strict_map(schema), do: Schema.strict_attributes(schema)
end

defimpl Workflow.Schema.Variant, for: Workflow.Schema.Number do
  alias Workflow.Schema

  def validate(_schema, value) when is_number(value), do: :ok
  def validate(_schema, value), do: {:error, {:expected_number, value}}
  def to_map(schema), do: Schema.attributes_to_map(schema)
  def strict_map(schema), do: Schema.strict_attributes(schema)
end

defimpl Workflow.Schema.Variant, for: Workflow.Schema.Boolean do
  alias Workflow.Schema

  def validate(_schema, value) when is_boolean(value), do: :ok
  def validate(_schema, value), do: {:error, {:expected_boolean, value}}
  def to_map(schema), do: Schema.attributes_to_map(schema)
  def strict_map(schema), do: Schema.strict_attributes(schema)
end

defimpl Workflow.Schema.Variant, for: Workflow.Schema.Array do
  alias Workflow.Schema
  alias Workflow.Schema.Extension

  def validate(schema, value) when is_list(value) do
    case Schema.attribute(schema, "items", :missing) do
      :missing -> :ok
      item_schema -> Schema.check_each(item_schema, value)
    end
  end

  def validate(_schema, value), do: {:error, {:expected_array, value}}

  def to_map(schema), do: Schema.attributes_to_map(schema)

  def strict_map(schema) do
    items = Schema.attribute(schema, "items", %Extension{attributes: %{}})

    schema
    |> Schema.attributes_to_map()
    |> Map.put("items", Schema.strict_value(items))
  end
end

defimpl Workflow.Schema.Variant, for: Workflow.Schema.Extension do
  alias Workflow.Schema

  def validate(_schema, _value), do: :ok
  def to_map(schema), do: Schema.attributes_to_map(schema)
  def strict_map(schema), do: Schema.strict_attributes(schema)
end
