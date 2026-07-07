import Config

if config_env() == :prod do
  server? = System.get_env("CODEX_LOOPS_SERVER") in ["1", "true"]

  port =
    (System.get_env("CODEX_LOOPS_PORT") || System.get_env("PORT", "4000")) |> String.to_integer()

  host = System.get_env("CODEX_LOOPS_HOST", "0.0.0.0")

  ip =
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, parsed_ip} ->
        parsed_ip

      {:error, _reason} when host == "localhost" ->
        {127, 0, 0, 1}

      {:error, _reason} ->
        raise """
        invalid CODEX_LOOPS_HOST=#{inspect(host)}

        Expected an IPv4/IPv6 address or localhost.
        """
    end

  config :codex_loops, Workflow.Web.Endpoint,
    http: [ip: ip, port: port],
    server: server?
end
