defmodule Workflow.Web.SchedulerBoundaryTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Workflow.Journal

  @endpoint Workflow.Web.Endpoint
  @max_body_bytes 65_536

  test "query parameters cannot turn a simple cross-origin POST into a run" do
    run_id = unique_id("query_attack")

    query =
      URI.encode_query(%{
        "provider" => "mock",
        "run_id" => run_id,
        "script_path" => workflow_script()
      })

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "text/plain")
      |> post("/api/runs?#{query}", "")

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.unsupported_media_type",
               "details" => %{
                 "expected" => "application/json",
                 "received" => "text/plain"
               }
             }
           } = json_response(conn, 415)

    refute Journal.run_exists?(run_id)
  end

  test "mutation requests without a content type are rejected before routing" do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post("/api/runs/unknown/resume", nil)

    assert %{
             "error" => %{
               "code" => "scheduler.unsupported_media_type",
               "details" => %{"received" => nil}
             }
           } = json_response(conn, 415)
  end

  test "JSON body parameters win because query parameters never enter the scheduler" do
    body_run_id = unique_id("body")
    query_run_id = unique_id("query")

    query =
      URI.encode_query(%{
        "provider" => "bogus",
        "run_id" => query_run_id,
        "script_path" => "/missing/query-script.exs"
      })

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/runs?#{query}",
        Jason.encode!(%{provider: "mock", run_id: body_run_id, script_path: workflow_script()})
      )

    assert %{"data" => %{"run_id" => ^body_run_id, "state" => "accepted"}} =
             json_response(conn, 200)

    assert Journal.run_exists?(body_run_id)
    refute Journal.run_exists?(query_run_id)
  end

  test "oversized JSON bodies use the scheduler error envelope" do
    body = Jason.encode!(%{"padding" => String.duplicate("x", @max_body_bytes)})

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> post("/api/runs", body)

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.request_too_large",
               "details" => %{"max_bytes" => @max_body_bytes}
             }
           } = json_response(conn, 413)
  end

  defp workflow_script do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex_loops_boundary_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, """
    workflow "boundary" do
      return :ok
    end
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp unique_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
