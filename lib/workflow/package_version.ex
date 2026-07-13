defmodule Workflow.PackageVersion do
  @moduledoc "Shared Codex Loops package version."

  @version_source Path.expand("../../VERSION", __DIR__)
  @external_resource @version_source
  @version @version_source |> File.read!() |> String.trim()

  @spec version() :: String.t()
  def version, do: @version
end
