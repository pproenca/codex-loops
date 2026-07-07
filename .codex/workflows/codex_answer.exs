defmodule CodexAnswerWorkflow do
  use Workflow

  workflow "codex-answer" do
    phase "answer"
    log "asking Codex for one visible answer"

    agent "Reply with exactly this single sentence and do not use tools: Codex agent answer: hello from the live Codex provider."

    return :ok
  end
end
