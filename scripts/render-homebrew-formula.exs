defmodule RenderHomebrewFormula do
  @moduledoc false

  def run([version, sha256, output]) do
    unless Regex.match?(~r/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/, version) do
      Mix.raise("invalid version: #{version}")
    end

    unless Regex.match?(~r/^[0-9a-f]{64}$/, sha256) do
      Mix.raise("sha256 must contain 64 lowercase hexadecimal characters")
    end

    template = File.read!("packaging/homebrew/Formula/codex-loops.rb.erb")

    rendered =
      template
      |> String.replace("@VERSION@", version)
      |> String.replace("@SHA256@", sha256)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, rendered)
  end

  def run(_args) do
    Mix.raise("usage: mix run scripts/render-homebrew-formula.exs VERSION SHA256 OUTPUT")
  end
end

RenderHomebrewFormula.run(System.argv())
