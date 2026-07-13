defmodule Workflow.Run.Stream do
  @moduledoc """
  Subscription boundary for committed run notifications.

  Writers persist every event before broadcasting `{:journal_committed, ...}`.
  PubSub is therefore only a refresh signal; reconnecting readers always fold the
  SQLite journal.
  """

  alias Workflow.PubSub

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) when is_binary(run_id) do
    Phoenix.PubSub.subscribe(PubSub, run_topic(run_id))
  end

  defp run_topic(run_id), do: "run:" <> run_id
end
