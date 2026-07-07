defmodule Workflow.SchedulerTest do
  use ExUnit.Case, async: false

  alias Workflow.Scheduler

  test "health reports the supervised runtime boundary dependencies" do
    assert {:ok, health} = Scheduler.health()

    assert health.status == :ok

    assert health.checks == %{
             otp_app: :available,
             journal: :available,
             pubsub: :available,
             endpoint: :available
           }
  end

  test "run start is an expected scheduler API error until lifecycle support ships" do
    assert {:error, %Scheduler.Error{} = error} = Scheduler.start_run(%{})

    assert error.status == 501
    assert error.code == "scheduler.run_start_not_available"
    assert error.message == "Workflow run start is not available in this scheduler API slice."
    assert error.details == %{}
  end
end
