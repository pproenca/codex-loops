defmodule Workflow.Refine.Artifact do
  @moduledoc "The single schema for refine producer, reviser, and repair artifacts."

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{"artifact" => %{"type" => "string"}},
    "required" => ["artifact"]
  }

  @spec schema() :: map()
  def schema, do: @schema
end
