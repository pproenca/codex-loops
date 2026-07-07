defmodule Workflow.Web.SchedulerAPITest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint Workflow.Web.Endpoint

  defp json_conn do
    build_conn()
    |> put_req_header("accept", "application/json")
  end

  test "GET /api/health returns a versioned ready response" do
    conn = get(json_conn(), "/api/health")

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "status" => "ok",
               "checks" => %{
                 "otp_app" => "available",
                 "journal" => "available",
                 "pubsub" => "available",
                 "endpoint" => "available"
               }
             }
           } = json_response(conn, 200)
  end

  test "POST /api/runs returns a typed error envelope until run start ships" do
    conn =
      json_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/runs", "{}")

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run_start_not_available",
               "message" => "Workflow run start is not available in this scheduler API slice.",
               "details" => %{}
             }
           } = json_response(conn, 501)
  end

  test "malformed JSON requests return the scheduler error envelope" do
    conn =
      json_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/runs", "{")

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.malformed_json",
               "message" => "Malformed JSON request body.",
               "details" => %{}
             }
           } = json_response(conn, 400)
  end

  test "unknown API routes return the scheduler error envelope" do
    conn = get(json_conn(), "/api/does-not-exist")

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.not_found",
               "message" => "Scheduler API route not found.",
               "details" => %{}
             }
           } = json_response(conn, 404)
  end
end
