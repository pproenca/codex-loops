import Config

if config_env() == :prod do
  server? =
    case System.get_env("CODEX_LOOPS_SERVER", "false") do
      value when value in ["0", "false"] -> false
      value when value in ["1", "true"] -> true
      value -> raise "invalid CODEX_LOOPS_SERVER=#{inspect(value)}; expected 0, 1, false, or true"
    end

  raw_port = System.get_env("CODEX_LOOPS_PORT") || System.get_env("PORT", "4000")

  port =
    case Integer.parse(raw_port) do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise "invalid scheduler port #{inspect(raw_port)}; expected an integer from 1 to 65535"
    end

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
    secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
    url: [host: host, port: port],
    server: server?

  if server? do
    codex_bin =
      System.get_env("CODEX_LOOPS_CODEX_BIN") ||
        raise "CODEX_LOOPS_CODEX_BIN must be injected by the Codex Loops control plane"

    with :absolute <- Path.type(codex_bin),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(codex_bin),
         true <- Bitwise.band(mode, 0o111) != 0 do
      config :codex_loops, codex_command: {codex_bin, ["provider-exec"]}
    else
      _ -> raise "CODEX_LOOPS_CODEX_BIN must name an absolute executable file"
    end
  end

  case System.get_env("CODEX_LOOPS_CODEX_MODEL") do
    nil ->
      :ok

    model ->
      model = String.trim(model)

      if model == "" do
        raise "CODEX_LOOPS_CODEX_MODEL must not be blank"
      end

      config :codex_loops, codex_model: model
  end

  case {System.get_env("CODEX_LOOPS_CODEX_SANDBOX"), System.get_env("CODEX_LOOPS_CODEX_WORKDIR")} do
    {nil, nil} ->
      :ok

    {"workspace-write", workdir} when is_binary(workdir) ->
      with :absolute <- Path.type(workdir),
           {:ok, %File.Stat{type: :directory}} <- File.stat(workdir) do
        config :codex_loops, codex_execution: {:sandboxed, workdir}
      else
        _ -> raise "CODEX_LOOPS_CODEX_WORKDIR must name an absolute directory"
      end

    {sandbox, workdir} ->
      raise """
      invalid Codex sandbox configuration

      CODEX_LOOPS_CODEX_SANDBOX=#{inspect(sandbox)}
      CODEX_LOOPS_CODEX_WORKDIR=#{inspect(workdir)}

      Expected both variables to be unset, or sandbox=workspace-write with an absolute workdir.
      """
  end
end
