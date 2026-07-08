defmodule Workflow.MCPSchedulerClientTest do
  use ExUnit.Case, async: false

  alias Workflow.MCP.SchedulerClient

  setup do
    previous_url = System.get_env("CODEX_LOOPS_SCHEDULER_URL")
    previous_timeout = System.get_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS")

    System.put_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS", "1000")

    on_exit(fn ->
      restore_env("CODEX_LOOPS_SCHEDULER_URL", previous_url)
      restore_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS", previous_timeout)
    end)

    :ok
  end

  test "get_run returns the scheduler status envelope without reshaping camelCase fields" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{
        "runId" => "run 1/alpha",
        "treeName" => "demo",
        "agentCount" => 1,
        "eventCount" => 2,
        "agents" => [],
        "rejected" => [],
        "verifications" => [],
        "judgments" => [],
        "refines" => [],
        "toolActivity" => [],
        "rawRefs" => %{
          "journal" => [
            %{"runId" => "run 1/alpha", "seq" => 0, "type" => "run_started"}
          ]
        }
      }
    }

    url = serve_once(envelope)
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    assert {:ok, ^envelope} = SchedulerClient.get_run("run 1/alpha")
    assert_received {:http_request, request}
    assert request =~ "GET /api/runs/run%201%2Falpha "
  end

  test "get_run_events returns the inspect projection with raw refs intact" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{
        "runId" => "run-inspect",
        "treeName" => "demo",
        "agentCount" => 0,
        "eventCount" => 1,
        "agents" => [],
        "rejected" => [],
        "verifications" => [],
        "judgments" => [],
        "refines" => [],
        "toolActivity" => [],
        "rawRefs" => %{
          "journal" => [
            %{"runId" => "run-inspect", "seq" => 0, "type" => "run_started"}
          ]
        },
        "events" => [%{"seq" => 0, "type" => "run_started"}]
      }
    }

    url = serve_once(envelope)
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    assert {:ok, ^envelope} = SchedulerClient.get_run_events("run-inspect")
    assert_received {:http_request, request}
    assert request =~ "GET /api/runs/run-inspect/events "
  end

  defp serve_once(envelope) do
    body = Jason.encode!(envelope)
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket, 1000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 1000)
      send(parent, {:http_request, request})

      response = [
        "HTTP/1.1 200 OK\r\n",
        "content-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(byte_size(body)),
        "\r\nconnection: close\r\n\r\n",
        body
      ]

      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen_socket)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
