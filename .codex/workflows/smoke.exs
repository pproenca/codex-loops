defmodule SmokeWorkflow do
  use Workflow

  workflow "smoke" do
    phase "smoke"
    log "starting smoke workflow"

    agent "Mock-safe smoke step: confirm the scheduler can run one agent node without reading or writing files."

    return :ok
  end
end
