defmodule Workflow.MCPProtocolTest do
  use ExUnit.Case, async: true

  alias Workflow.MCP.Protocol
  alias Workflow.MCP.Tools
  alias Workflow.PackageVersion

  @base_url "http://127.0.0.1:47125"

  test "initialize negotiates every supported HTTP protocol version" do
    Enum.each(Protocol.supported_versions(), fn version ->
      assert {:reply,
              %{
                "jsonrpc" => "2.0",
                "id" => 1,
                "result" => %{
                  "protocolVersion" => ^version,
                  "capabilities" => %{"tools" => %{"listChanged" => false}},
                  "serverInfo" => %{
                    "name" => "codex-loops",
                    "version" => package_version
                  }
                }
              }} =
               Protocol.handle(
                 %{
                   "jsonrpc" => "2.0",
                   "id" => 1,
                   "method" => "initialize",
                   "params" => %{
                     "protocolVersion" => version,
                     "capabilities" => %{},
                     "clientInfo" => %{"name" => "test", "version" => "1"}
                   }
                 },
                 base_url: @base_url
               )

      assert package_version == PackageVersion.version()
    end)
  end

  test "an unsupported initialize version selects the newest supported version" do
    assert {:reply, %{"result" => %{"protocolVersion" => "2025-11-25"}}} =
             Protocol.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => "init",
                 "method" => "initialize",
                 "params" => %{
                   "protocolVersion" => "2099-01-01",
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "test", "version" => "1"}
                 }
               },
               base_url: @base_url
             )
  end

  test "the tool catalog has six strict schemas and preserves the resume alias" do
    tools = Tools.catalog()

    assert Enum.map(tools, & &1["name"]) == [
             "workflow_validate",
             "workflow_start",
             "workflow_status",
             "workflow_inspect",
             "workflow_resume",
             "workflow_open_ui"
           ]

    assert Enum.all?(tools, &(&1["inputSchema"]["additionalProperties"] == false))

    assert Enum.all?(tools, fn tool ->
             case get_in(tool, ["inputSchema", "properties", "run_id"]) do
               nil -> true
               schema -> schema["maxLength"] == 128
             end
           end)

    resume = Enum.find(tools, &(&1["name"] == "workflow_resume"))
    validate = Enum.find(tools, &(&1["name"] == "workflow_validate"))
    start = Enum.find(tools, &(&1["name"] == "workflow_start"))

    assert validate["inputSchema"]["properties"]["args"] == %{}
    assert start["inputSchema"]["properties"]["args"] == %{}

    assert resume["inputSchema"]["properties"]["script"] ==
             resume["inputSchema"]["properties"]["script_path"]

    assert {:invalid_params, message} =
             Tools.call(
               "workflow_resume",
               %{"run_id" => "run-1", "script" => "/tmp/a", "script_path" => "/tmp/b"},
               base_url: @base_url
             )

    assert message =~ "cannot both be provided"
  end

  test "subsequent requests validate the MCP protocol header" do
    ping = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}

    assert {:reply, %{"result" => %{}}} = Protocol.handle(ping, base_url: @base_url)

    assert {:bad_request,
            %{
              "error" => %{
                "code" => -32_600,
                "data" => %{"received" => "2024-11-05"}
              }
            }} =
             Protocol.handle(ping,
               base_url: @base_url,
               protocol_version: "2024-11-05"
             )
  end

  test "notifications and client responses are accepted without allocating session state" do
    assert :accepted =
             Protocol.handle(
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
               base_url: @base_url,
               protocol_version: "2025-11-25"
             )

    assert :accepted =
             Protocol.handle(
               %{"jsonrpc" => "2.0", "method" => "initialize", "params" => "malformed"},
               base_url: @base_url,
               protocol_version: "2025-11-25"
             )

    assert :accepted =
             Protocol.handle(
               %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/initialized",
                 "params" => "malformed"
               },
               base_url: @base_url,
               protocol_version: "2025-11-25"
             )

    assert :accepted =
             Protocol.handle(
               %{"jsonrpc" => "2.0", "id" => 9, "result" => %{}},
               base_url: @base_url,
               protocol_version: "2025-11-25"
             )
  end

  test "initialize requires a complete client implementation identity" do
    for client_info <- [
          %{},
          %{"name" => "test"},
          %{"version" => "1"},
          %{"name" => 1, "version" => "1"},
          %{"name" => "test", "version" => 1}
        ] do
      request =
        1
        |> initialize_request("2025-11-25")
        |> put_in(["params", "clientInfo"], client_info)

      assert {:reply, %{"id" => 1, "error" => %{"code" => -32_602}}} =
               Protocol.handle(request, base_url: @base_url)
    end
  end

  test "client responses contain exactly one valid result or error member" do
    opts = [base_url: @base_url, protocol_version: "2025-11-25"]

    assert :accepted = Protocol.handle(%{"jsonrpc" => "2.0", "id" => 1, "result" => nil}, opts)

    assert :accepted =
             Protocol.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 2,
                 "error" => %{"code" => -32_001, "message" => "client failure"}
               },
               opts
             )

    for invalid <- [
          %{"jsonrpc" => "2.0", "id" => 3, "result" => %{}, "error" => %{}},
          %{"jsonrpc" => "2.0", "id" => 4},
          %{"jsonrpc" => "2.0", "id" => 5, "error" => %{"code" => "bad", "message" => "bad"}},
          %{"jsonrpc" => "2.0", "id" => 6, "error" => %{"code" => -1}}
        ] do
      assert {:bad_request, %{"error" => %{"code" => -32_600}} = response} =
               Protocol.handle(invalid, opts)

      refute Map.has_key?(response, "id")
    end
  end

  test "2025-03-26 batches omit notifications and client responses" do
    batch = [
      %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      %{"jsonrpc" => "2.0", "id" => 9, "result" => %{}}
    ]

    assert {:reply, [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}]} =
             Protocol.handle(batch, base_url: @base_url)

    assert :accepted =
             Protocol.handle(tl(batch),
               base_url: @base_url,
               protocol_version: "2025-03-26"
             )
  end

  test "batch compatibility rejects empty, initialized, and newer-version batches correctly" do
    assert {:bad_request, %{"error" => %{"code" => -32_600}} = empty_error} =
             Protocol.handle([], base_url: @base_url)

    refute Map.has_key?(empty_error, "id")

    assert {:reply, [%{"id" => "init", "error" => %{"code" => -32_600}}]} =
             Protocol.handle([initialize_request("init", "2025-03-26")],
               base_url: @base_url,
               protocol_version: "2025-03-26"
             )

    assert {:bad_request, %{"error" => %{"code" => -32_600}}} =
             Protocol.handle([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}],
               base_url: @base_url,
               protocol_version: "2025-06-18"
             )
  end

  test "tool runtime rejects run ids over 128 bytes" do
    overlong = String.duplicate("r", 129)

    assert {:invalid_params, message} =
             Tools.call("workflow_status", %{"run_id" => overlong}, base_url: @base_url)

    assert message =~ "at most 128 bytes"
  end

  test "transport-level errors omit an id" do
    for response <- [Protocol.parse_error(), Protocol.invalid_request()] do
      assert response["jsonrpc"] == "2.0"
      refute Map.has_key?(response, "id")
    end
  end

  defp initialize_request(id, version) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1"}
      }
    }
  end
end
