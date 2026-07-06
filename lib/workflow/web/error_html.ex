defmodule Workflow.Web.ErrorHTML do
  @moduledoc "Minimal error renderer: the status phrase for the template code."

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
