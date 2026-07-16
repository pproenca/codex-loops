workflow "parameterized-scope-review",
  inputs: %{
    "type" => "object",
    "properties" => %{
      "scope" => %{"type" => "string"},
      "files" => %{"type" => "array", "items" => %{"type" => "string"}},
      "replicas" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["scope", "files", "replicas"]
  } do
  phase("independent review")

  fanout width: path_count(:args, "/replicas", max: 8), bind: :reviews do
    agent(~P"""
    Independently review the requested scope. This is a replica over the whole
    scope, not one replica-list item mapped into this lane.

    Scope:
    <%= path(@args, "/scope") %>

    Files:
    <%= flatten(@args, "/files") %>

    Report concrete risks with file evidence. Make no edits.
    """)
  end

  let(
    :summary =
      agent(~P"""
      Consolidate the independent reviews for this scope:
      <%= path(@args, "/scope") %>

      Reviews:
      <%= @reviews %>

      Preserve disagreements and cite files. Do not invent evidence.
      """)
  )

  emit(~P"<%= @summary %>")
end
