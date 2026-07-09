defmodule CodexLoopsConformanceDataflow do
  use Workflow

  workflow "conformance-dataflow" do
    phase("dataflow")

    let(
      :rows =
        agent("Return two rows.",
          schema: %{
            "type" => "object",
            "properties" => %{
              "rows" => %{
                "type" => "array",
                "minItems" => 2,
                "items" => %{
                  "type" => "object",
                  "properties" => %{"id" => %{"type" => "string"}},
                  "required" => ["id"]
                }
              }
            },
            "required" => ["rows"]
          }
        )
    )

    fanout width: path_count(:rows, "/rows", max: 2), bind: :work do
      agent("process one row")
    end

    let(:summary = synthesize(["alpha", "beta"], "Summarize these inputs."))
    let(:improved = agent(~P"Improve this summary: <%= @summary %>"))

    emit(
      ~P|Rows=<%= count(@rows, "/rows") %> Work=<%= count(@work) %> First=<%= path(@rows, "/rows/0/id") %> Summary=<%= truncate(@improved, 80) %>|
    )
  end
end
