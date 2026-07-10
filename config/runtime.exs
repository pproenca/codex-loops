import Config

if config_env() == :prod do
  server? = System.get_env("CODEX_LOOPS_SERVER") in ["1", "true"]

  port = String.to_integer(System.get_env("CODEX_LOOPS_PORT") || System.get_env("PORT", "4000"))

  host = System.get_env("CODEX_LOOPS_HOST", "127.0.0.1")

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
    url: [host: host, port: port],
    server: server?

  if server? do
    codex_bin =
      System.get_env("CODEX_LOOPS_CODEX_BIN") ||
        raise "CODEX_LOOPS_CODEX_BIN must be injected by the Codex Loops control plane"

    stat = File.stat!(codex_bin)

    if !(Path.type(codex_bin) == :absolute and stat.type == :regular and
           Bitwise.band(stat.mode, 0o111) != 0) do
      raise "CODEX_LOOPS_CODEX_BIN must name an absolute executable file"
    end

    config :codex_loops, codex_command: {codex_bin, ["provider-exec"]}
  end

  if codex_model = System.get_env("CODEX_LOOPS_CODEX_MODEL") do
    config :codex_loops, codex_model: codex_model
  end
end
