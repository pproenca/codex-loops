defmodule Workflow.Tree do
  @moduledoc """
  The inert, serializable representation of a compiled workflow.

  A `%Tree{}` is pure data: a name, an event-log-schema-independent structural
  version, and an ordered list of node structs (`Workflow.Node.*`). It contains
  no closures, so it can be escaped into a module attribute at compile time,
  written to a journal, and folded/resumed later.
  """

  @enforce_keys [:nodes]
  defstruct name: nil, version: 1, nodes: []

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: pos_integer(),
          nodes: [struct()]
        }
end
