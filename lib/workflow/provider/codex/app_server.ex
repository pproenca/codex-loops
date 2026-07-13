defmodule Workflow.Provider.Codex.AppServer do
  @moduledoc """
  Owns the scheduler's single long-lived `codex app-server` port.

  The owner does only protocol bookkeeping: it bounds admission, correlates JSON-RPC
  responses and turn notifications, and forwards inert maps to the provider caller.
  In particular, it never invokes an activity sink or writes to the journal from its
  mailbox. Each caller folds its own stream concurrently.

  A port loss after `turn/start` has been written is reported as ambiguous. The
  provider deliberately crashes that caller so the writer leaves its durable
  `agent_started` marker unsettled; resume then records `outcome_unknown` instead of
  redelivering a possibly-paid turn.
  """
  use GenServer

  @name __MODULE__
  @default_max_active 8
  @hard_max_active 8
  @default_max_pending 64
  @default_max_line_bytes 1_048_576
  @default_max_turn_bytes 16 * 1_024 * 1_024
  @hard_max_turn_bytes 16 * 1_024 * 1_024
  @default_max_turn_events 10_000
  @hard_max_turn_events 10_000
  @max_prompt_bytes 16 * 1_024 * 1_024
  @default_initialize_timeout 10_000
  @default_interrupt_timeout 5_000
  @cancel_start_grace 5_000

  defmodule Request do
    @moduledoc false
    @enforce_keys [
      :ref,
      :caller,
      :monitor,
      :prompt,
      :cwd,
      :thread_sandbox,
      :turn_sandbox,
      :command,
      :timer
    ]
    defstruct [
      :ref,
      :caller,
      :monitor,
      :prompt,
      :schema,
      :cwd,
      :model,
      :thread_sandbox,
      :turn_sandbox,
      :command,
      :timer,
      :thread_id,
      :turn_id,
      event_bytes: 0,
      event_count: 0,
      phase: :queued
    ]
  end

  defmodule State do
    @moduledoc false
    defstruct port: nil,
              port_status: :stopped,
              command: nil,
              next_id: 1,
              requests: %{},
              waiting: :queue.new(),
              rpc: %{},
              by_monitor: %{},
              by_thread: %{},
              by_turn: %{},
              draining: MapSet.new(),
              initialize_timer: nil,
              initialize_timeout: 10_000,
              interrupt_timeout: 5_000,
              max_active: 8,
              max_pending: 64,
              max_line_bytes: 1_048_576,
              max_turn_bytes: 16 * 1_024 * 1_024,
              max_turn_events: 10_000
  end

  @type turn_request :: %{
          required(:prompt) => String.t(),
          required(:cwd) => String.t(),
          required(:thread_sandbox) => String.t(),
          required(:turn_sandbox) => map(),
          required(:command) => {String.t(), [String.t()]},
          required(:timeout) => pos_integer(),
          optional(:schema) => map() | nil,
          optional(:model) => String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @spec start_turn(turn_request()) :: {:ok, reference(), pid()} | {:error, :unavailable, map()}
  def start_turn(request) when is_map(request) do
    GenServer.call(@name, {:start_turn, self(), request}, :infinity)
  catch
    :exit, _reason ->
      {:error, :unavailable, %{"message" => "Codex app-server owner is unavailable"}}
  end

  @type caller_event ::
          {:event, map()}
          | :turn_start_sent
          | :accepted
          | {:terminal, :completed | {:error, atom(), map()}}
          | {:transport_lost, map()}
          | {:owner_down, term()}
          | :timeout

  @doc """
  Receives one correlated app-server event in the calling process.

  This keeps the private mailbox tuple protocol inside the transport module while
  leaving event folding and activity callbacks in the provider caller.
  """
  @spec next_event(reference(), reference(), timeout()) :: caller_event()
  def next_event(ref, owner_monitor, timeout) do
    receive do
      {:codex_app_server, ^ref, {:event, event}} -> {:event, event}
      {:codex_app_server, ^ref, :turn_start_sent} -> :turn_start_sent
      {:codex_app_server, ^ref, :accepted} -> :accepted
      {:codex_app_server, ^ref, {:terminal, terminal}} -> {:terminal, terminal}
      {:codex_app_server, ^ref, {:transport_lost, detail}} -> {:transport_lost, detail}
      {:DOWN, ^owner_monitor, :process, _owner, reason} -> {:owner_down, reason}
    after
      timeout -> :timeout
    end
  end

  @spec cancel(reference()) :: :ok
  def cancel(ref) when is_reference(ref) do
    GenServer.cast(@name, {:cancel, ref})
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    GenServer.call(@name, :reset)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, fresh_state()}
  end

  @impl true
  def handle_call({:start_turn, caller, request}, _from, state) do
    with :ok <- validate_request(request),
         :ok <- command_compatible(state, request.command),
         :ok <- admission_available(state) do
      ref = make_ref()
      monitor = Process.monitor(caller)
      timer = Process.send_after(self(), {:request_timeout, ref}, request.timeout)

      entry = %Request{
        ref: ref,
        caller: caller,
        monitor: monitor,
        prompt: :binary.copy(request.prompt),
        schema: Map.get(request, :schema),
        cwd: request.cwd,
        model: Map.get(request, :model),
        thread_sandbox: request.thread_sandbox,
        turn_sandbox: request.turn_sandbox,
        command: request.command,
        timer: timer
      }

      state = %{
        state
        | command: state.command || request.command,
          requests: Map.put(state.requests, ref, entry),
          by_monitor: Map.put(state.by_monitor, monitor, ref),
          waiting: :queue.in(ref, state.waiting)
      }

      state = ensure_port(state)
      state = dispatch_waiting(state)
      {:reply, {:ok, ref, self()}, state}
    else
      {:error, detail} -> {:reply, {:error, :unavailable, detail}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    cancel_initialize_timer(state.initialize_timer)
    state = fail_transport(state, %{"message" => "Codex app-server was reset"}, :unavailable)
    close_port(state.port)
    {:reply, :ok, fresh_state()}
  end

  @impl true
  def handle_cast({:cancel, ref}, state) do
    {:noreply, state |> cancel_request(ref, :cancelled) |> dispatch_waiting()}
  end

  @impl true
  def handle_info(:start_port, %State{port_status: :starting, command: {path, args}} = state) do
    port_options = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, Enum.map(args, &String.to_charlist/1)},
      {:line, state.max_line_bytes}
    ]

    try do
      port = Port.open({:spawn_executable, String.to_charlist(path)}, port_options)
      timer = Process.send_after(self(), {:initialize_timeout, port}, state.initialize_timeout)
      state = %{state | port: port, port_status: :initializing, initialize_timer: timer}

      case send_request(state, "initialize", initialize_params(), :initialize) do
        {:ok, state} -> {:noreply, state}
        {:error, state} -> {:noreply, transport_write_failed(state)}
      end
    rescue
      exception ->
        detail = %{"message" => "Codex app-server failed to start: #{Exception.message(exception)}"}
        {:noreply, state |> fail_transport(detail, :unavailable) |> stopped_state()}
    end
  end

  def handle_info(:start_port, state), do: {:noreply, state}

  def handle_info({:initialize_timeout, port}, %State{port: port, port_status: :initializing} = state) do
    detail = %{"message" => "Codex app-server initialize timed out"}
    close_port(port)
    {:noreply, state |> fail_transport(detail, :unavailable) |> stopped_state()}
  end

  def handle_info({:initialize_timeout, _port}, state), do: {:noreply, state}

  def handle_info({port, {:data, {:eol, line}}}, %State{port: port} = state) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) -> {:noreply, handle_message(state, message)}
      {:ok, value} -> {:noreply, protocol_failed(state, "non-object JSON", inspect(value))}
      {:error, reason} -> {:noreply, protocol_failed(state, "malformed JSON", inspect(reason))}
    end
  end

  def handle_info({port, {:data, {:noeol, _chunk}}}, %State{port: port} = state) do
    {:noreply, protocol_failed(state, "oversized JSON line", state.max_line_bytes)}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    detail = %{"message" => "Codex app-server exited with status #{status}"}
    kind = if state.port_status in [:starting, :initializing], do: :unavailable, else: :backend
    {:noreply, state |> fail_transport(detail, kind) |> stopped_state()}
  end

  def handle_info({:EXIT, port, reason}, %State{port: port} = state) do
    detail = %{"message" => "Codex app-server port closed", "reason" => inspect(reason)}
    {:noreply, state |> fail_transport(detail, :backend) |> stopped_state()}
  end

  def handle_info({:request_timeout, ref}, state) do
    case Map.get(state.requests, ref) do
      nil ->
        {:noreply, state}

      %Request{phase: :cancelling_start} ->
        {:noreply, state}

      request ->
        send_terminal(request, {:error, :timeout, %{"message" => "codex turn timed out"}})
        {:noreply, state |> begin_cancel(request) |> dispatch_waiting()}
    end
  end

  def handle_info({:cancel_start_timeout, ref}, state) do
    case Map.get(state.requests, ref) do
      %Request{phase: :cancelling_start} ->
        detail = %{"message" => "Codex app-server did not acknowledge a cancelled turn/start"}
        close_port(state.port)
        {:noreply, state |> fail_transport(detail, :backend) |> stopped_state()}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:drain_timeout, key}, state) do
    if MapSet.member?(state.draining, key) do
      detail = %{"message" => "Codex app-server did not complete an interrupted turn"}
      close_port(state.port)
      {:noreply, state |> fail_transport(detail, :backend) |> stopped_state()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.get(state.by_monitor, monitor) do
      nil -> {:noreply, state}
      ref -> {:noreply, state |> cancel_request(ref, :caller_down) |> dispatch_waiting()}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp fresh_state do
    %State{
      max_active:
        :codex_loops
        |> Application.get_env(:codex_app_server_max_active, @default_max_active)
        |> positive_integer(@default_max_active)
        |> min(@hard_max_active),
      max_pending:
        :codex_loops
        |> Application.get_env(:codex_app_server_max_pending, @default_max_pending)
        |> positive_integer(@default_max_pending),
      max_line_bytes:
        :codex_loops
        |> Application.get_env(:codex_app_server_max_line_bytes, @default_max_line_bytes)
        |> positive_integer(@default_max_line_bytes),
      initialize_timeout:
        :codex_loops
        |> Application.get_env(:codex_app_server_initialize_timeout, @default_initialize_timeout)
        |> positive_integer(@default_initialize_timeout),
      interrupt_timeout:
        :codex_loops
        |> Application.get_env(:codex_app_server_interrupt_timeout, @default_interrupt_timeout)
        |> positive_integer(@default_interrupt_timeout),
      max_turn_bytes:
        :codex_loops
        |> Application.get_env(:codex_app_server_max_turn_bytes, @default_max_turn_bytes)
        |> positive_integer(@default_max_turn_bytes)
        |> min(@hard_max_turn_bytes),
      max_turn_events:
        :codex_loops
        |> Application.get_env(:codex_app_server_max_turn_events, @default_max_turn_events)
        |> positive_integer(@default_max_turn_events)
        |> min(@hard_max_turn_events)
    }
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp validate_request(%{
         prompt: prompt,
         cwd: cwd,
         thread_sandbox: thread_sandbox,
         turn_sandbox: turn_sandbox,
         command: {path, args},
         timeout: timeout
       })
       when is_binary(prompt) and byte_size(prompt) <= @max_prompt_bytes and is_binary(cwd) and cwd != "" and
              is_binary(thread_sandbox) and is_map(turn_sandbox) and is_binary(path) and path != "" and is_list(args) and
              is_integer(timeout) and timeout > 0 do
    if Enum.all?(args, &is_binary/1) do
      :ok
    else
      {:error, %{"message" => "invalid Codex app-server command arguments"}}
    end
  end

  defp validate_request(_request), do: {:error, %{"message" => "invalid Codex app-server request"}}

  defp command_compatible(%State{command: nil}, _command), do: :ok
  defp command_compatible(%State{command: command}, command), do: :ok

  defp command_compatible(_state, _command) do
    {:error, %{"message" => "Codex app-server is already running with a different command"}}
  end

  defp admission_available(state) do
    queued = Enum.count(state.requests, fn {_ref, request} -> request.phase == :queued end)

    if queued < state.max_pending do
      :ok
    else
      {:error,
       %{
         "message" => "Codex app-server pending queue is full",
         "maxPending" => state.max_pending
       }}
    end
  end

  defp ensure_port(%State{port_status: :stopped} = state) do
    send(self(), :start_port)
    %{state | port_status: :starting}
  end

  defp ensure_port(state), do: state

  defp initialize_params do
    %{
      "clientInfo" => %{
        "name" => "codex-loops",
        "title" => "Codex Loops Scheduler",
        "version" => to_string(Application.spec(:codex_loops, :vsn) || "dev")
      },
      "capabilities" => %{}
    }
  end

  defp handle_message(state, %{"id" => id, "method" => method} = request) when is_binary(method) do
    handle_server_request(state, id, method, Map.get(request, "params", %{}))
  end

  defp handle_message(state, %{"id" => id} = response) do
    handle_response(state, id, response)
  end

  defp handle_message(state, %{"method" => method} = notification) when is_binary(method) do
    handle_notification(state, method, Map.get(notification, "params", %{}), notification)
  end

  defp handle_message(state, _message), do: protocol_failed(state, "invalid JSON-RPC message", nil)

  defp handle_response(state, id, response) do
    case Map.pop(state.rpc, id) do
      {nil, _rpc} ->
        state

      {tag, rpc} ->
        state = %{state | rpc: rpc}

        case tag do
          :initialize -> handle_initialize_response(state, response)
          {:thread_start, ref} -> handle_thread_start_response(state, ref, response)
          {:turn_start, ref} -> handle_turn_start_response(state, ref, response)
          {:interrupt, _key} -> state
        end
    end
  end

  defp handle_initialize_response(state, %{"result" => result}) when is_map(result) do
    cancel_initialize_timer(state.initialize_timer)
    state = %{state | initialize_timer: nil}

    case send_notification(state, "initialized", %{}) do
      :ok -> state |> Map.put(:port_status, :ready) |> dispatch_waiting()
      :error -> transport_write_failed(state)
    end
  end

  defp handle_initialize_response(state, response) do
    protocol_failed(state, "initialize failed", response_error(response))
  end

  defp handle_thread_start_response(state, ref, %{"result" => %{"thread" => %{"id" => thread_id}}})
       when is_binary(thread_id) do
    thread_id = :binary.copy(thread_id)

    case Map.get(state.requests, ref) do
      %Request{phase: :thread_start} = request ->
        request = %{request | thread_id: thread_id, phase: :turn_starting}

        state = %{
          state
          | requests: Map.put(state.requests, ref, request),
            by_thread: Map.put(state.by_thread, thread_id, ref)
        }

        case forward_event(state, request, %{"type" => "thread.started", "thread_id" => thread_id}) do
          {:ok, state, request} ->
            case send_turn_start(state, request) do
              {:ok, state} -> state
              {:error, state} -> transport_write_failed(state)
            end

          {:error, state} ->
            state
        end

      _missing_or_cancelled ->
        state
    end
  end

  defp handle_thread_start_response(state, ref, response) do
    fail_request_from_response(state, ref, "thread/start failed", response)
  end

  defp handle_turn_start_response(state, ref, %{"result" => %{"turn" => %{"id" => turn_id}}}) when is_binary(turn_id) do
    turn_id = :binary.copy(turn_id)

    case Map.get(state.requests, ref) do
      %Request{phase: :turn_starting} = request ->
        request = %{request | turn_id: turn_id, phase: :running}
        send(request.caller, {:codex_app_server, ref, :accepted})

        state = %{
          state
          | requests: Map.put(state.requests, ref, request),
            by_turn: Map.put(state.by_turn, {request.thread_id, turn_id}, ref)
        }

        case forward_event(state, request, %{"type" => "turn.started"}) do
          {:ok, state, _request} -> state
          {:error, state} -> state
        end

      %Request{phase: :cancelling_start} = request ->
        request = %{request | turn_id: turn_id, phase: :running}
        state = %{state | requests: Map.put(state.requests, ref, request)}
        {_request, state} = remove_request(state, ref)
        state |> interrupt_and_drain(request) |> dispatch_waiting()

      _missing_or_cancelled ->
        state
    end
  end

  defp handle_turn_start_response(state, ref, response) do
    fail_request_from_response(state, ref, "turn/start failed", response)
  end

  defp fail_request_from_response(state, ref, label, response) do
    case Map.get(state.requests, ref) do
      nil ->
        state

      request ->
        detail = %{"message" => label, "error" => response_error(response)}
        send_terminal(request, {:error, :backend, detail})
        {_request, state} = remove_request(state, ref)
        dispatch_waiting(state)
    end
  end

  defp handle_notification(state, "turn/completed", params, notification) do
    case correlated_ref(state, params) do
      nil ->
        finish_draining_from_params(state, params)

      ref ->
        case Map.get(state.requests, ref) do
          nil ->
            state

          request ->
            case forward_event(state, request, notification) do
              {:ok, state, request} ->
                terminal = terminal_status(params)
                send_terminal(request, terminal)
                {_request, state} = remove_request(state, ref)
                dispatch_waiting(state)

              {:error, state} ->
                state
            end
        end
    end
  end

  defp handle_notification(state, _method, params, notification) do
    case correlated_ref(state, params) do
      nil ->
        state

      ref ->
        case Map.get(state.requests, ref) do
          nil ->
            state

          request ->
            case forward_event(state, request, notification) do
              {:ok, state, _request} -> state
              {:error, state} -> state
            end
        end
    end
  end

  defp terminal_status(%{"turn" => %{"status" => "completed"}}), do: :completed

  defp terminal_status(%{"turn" => %{"status" => status} = turn}) when is_binary(status) do
    detail =
      case Map.get(turn, "error") do
        %{"message" => message} = error when is_binary(message) -> Map.put(error, "message", message)
        nil -> %{"message" => "codex turn #{status}"}
        error -> %{"message" => "codex turn #{status}", "error" => inspect(error)}
      end

    {:error, :backend, detail}
  end

  defp terminal_status(_params) do
    {:error, :backend, %{"message" => "codex emitted an invalid terminal turn status"}}
  end

  defp handle_server_request(state, id, method, params) do
    response = fail_closed_response(method)

    state =
      case send_server_response(state, id, response) do
        :ok -> state
        :error -> transport_write_failed(state)
      end

    case correlated_ref(state, params) do
      nil ->
        state

      ref ->
        case Map.get(state.requests, ref) do
          nil ->
            state

          request ->
            detail = %{
              "message" => "Codex requested unsupported interactive input",
              "method" => method
            }

            send_terminal(request, {:error, :backend, detail})
            {_request, state} = remove_request(state, ref)
            state |> interrupt_and_drain(request) |> dispatch_waiting()
        end
    end
  end

  defp fail_closed_response(method)
       when method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"],
       do: {:result, %{"decision" => "cancel"}}

  defp fail_closed_response("item/tool/requestUserInput"), do: {:result, %{"answers" => %{}}}
  defp fail_closed_response("mcpServer/elicitation/request"), do: {:result, %{"action" => "cancel"}}

  defp fail_closed_response("item/tool/call") do
    {:result,
     %{
       "contentItems" => [%{"type" => "inputText", "text" => "unsupported by non-interactive scheduler"}],
       "success" => false
     }}
  end

  defp fail_closed_response(_method) do
    {:error, %{"code" => -32_601, "message" => "unsupported by non-interactive scheduler"}}
  end

  defp correlated_ref(state, params) when is_map(params) do
    thread_id = Map.get(params, "threadId")
    turn_id = Map.get(params, "turnId")

    Map.get(state.by_turn, {thread_id, turn_id}) ||
      (is_binary(thread_id) && Map.get(state.by_thread, thread_id))
  end

  defp correlated_ref(_state, _params), do: nil

  defp dispatch_waiting(%State{port_status: :ready} = state) do
    if active_count(state) < state.max_active do
      case pop_waiting(state) do
        {:empty, state} -> state
        {{:value, ref}, state} -> state |> start_thread(ref) |> dispatch_waiting()
      end
    else
      state
    end
  end

  defp dispatch_waiting(state), do: state

  defp pop_waiting(state) do
    case :queue.out(state.waiting) do
      {:empty, waiting} ->
        {:empty, %{state | waiting: waiting}}

      {{:value, ref}, waiting} ->
        state = %{state | waiting: waiting}

        case Map.get(state.requests, ref) do
          %Request{phase: :queued} -> {{:value, ref}, state}
          _removed -> pop_waiting(state)
        end
    end
  end

  defp start_thread(state, ref) do
    request = Map.fetch!(state.requests, ref)
    request = %{request | phase: :thread_start}
    state = %{state | requests: Map.put(state.requests, ref, request)}

    params =
      maybe_put(
        %{
          "cwd" => request.cwd,
          "approvalPolicy" => "never",
          "sandbox" => request.thread_sandbox,
          "ephemeral" => request.thread_sandbox == "workspace-write"
        },
        "model",
        request.model
      )

    case send_request(state, "thread/start", params, {:thread_start, ref}) do
      {:ok, state} -> state
      {:error, state} -> transport_write_failed(state)
    end
  end

  defp send_turn_start(state, request) do
    params =
      %{
        "threadId" => request.thread_id,
        "input" => [%{"type" => "text", "text" => request.prompt}],
        "cwd" => request.cwd,
        "approvalPolicy" => "never",
        "sandboxPolicy" => request.turn_sandbox
      }
      |> maybe_put("model", request.model)
      |> maybe_put("outputSchema", request.schema)

    send(request.caller, {:codex_app_server, request.ref, :turn_start_sent})
    send_request(state, "turn/start", params, {:turn_start, request.ref})
  end

  defp active_count(state) do
    active = Enum.count(state.requests, fn {_ref, request} -> request.phase != :queued end)
    active + MapSet.size(state.draining)
  end

  defp cancel_request(state, ref, _reason) do
    case Map.get(state.requests, ref) do
      nil ->
        state

      request ->
        begin_cancel(state, request)
    end
  end

  defp begin_cancel(state, %Request{phase: :turn_starting} = request) do
    Process.cancel_timer(request.timer, async: true, info: false)
    Process.demonitor(request.monitor, [:flush])
    Process.send_after(self(), {:cancel_start_timeout, request.ref}, @cancel_start_grace)
    request = %{request | phase: :cancelling_start}

    %{
      state
      | requests: Map.put(state.requests, request.ref, request),
        by_monitor: Map.delete(state.by_monitor, request.monitor)
    }
  end

  defp begin_cancel(state, %Request{phase: :cancelling_start}), do: state

  defp begin_cancel(state, request) do
    {_request, state} = remove_request(state, request.ref)
    interrupt_and_drain(state, request)
  end

  defp interrupt_and_drain(state, %Request{thread_id: thread_id, turn_id: turn_id})
       when is_binary(thread_id) and is_binary(turn_id) do
    key = {thread_id, turn_id}
    params = %{"threadId" => thread_id, "turnId" => turn_id}

    case send_request(state, "turn/interrupt", params, {:interrupt, key}) do
      {:ok, state} ->
        Process.send_after(self(), {:drain_timeout, key}, state.interrupt_timeout)
        %{state | draining: MapSet.put(state.draining, key)}

      {:error, state} ->
        transport_write_failed(state)
    end
  end

  defp interrupt_and_drain(state, _request), do: state

  defp finish_draining(state, key) do
    rpc = Map.reject(state.rpc, fn {_id, tag} -> tag == {:interrupt, key} end)

    state
    |> Map.put(:rpc, rpc)
    |> Map.update!(:draining, &MapSet.delete(&1, key))
    |> dispatch_waiting()
  end

  defp finish_draining_from_params(state, params) do
    case {Map.get(params, "threadId"), get_in(params, ["turn", "id"])} do
      {thread_id, turn_id} when is_binary(thread_id) and is_binary(turn_id) ->
        finish_draining(state, {thread_id, turn_id})

      _other ->
        state
    end
  end

  defp remove_request(state, ref) do
    case Map.pop(state.requests, ref) do
      {nil, _requests} ->
        {nil, state}

      {request, requests} ->
        Process.cancel_timer(request.timer, async: true, info: false)
        Process.demonitor(request.monitor, [:flush])

        rpc =
          Map.reject(state.rpc, fn {_id, tag} ->
            match?({:thread_start, ^ref}, tag) or match?({:turn_start, ^ref}, tag)
          end)

        by_thread = delete_if_value(state.by_thread, request.thread_id, ref)
        by_turn = delete_if_value(state.by_turn, {request.thread_id, request.turn_id}, ref)

        {request,
         %{
           state
           | requests: requests,
             waiting: delete_waiting(state.waiting, ref),
             rpc: rpc,
             by_monitor: Map.delete(state.by_monitor, request.monitor),
             by_thread: by_thread,
             by_turn: by_turn
         }}
    end
  end

  defp delete_if_value(map, key, value) do
    if Map.get(map, key) == value, do: Map.delete(map, key), else: map
  end

  defp delete_waiting(waiting, ref) do
    waiting
    |> :queue.to_list()
    |> Enum.reject(&(&1 == ref))
    |> :queue.from_list()
  end

  defp send_request(state, method, params, tag) do
    id = state.next_id
    message = %{"id" => id, "method" => method, "params" => params}

    case write_message(state.port, message) do
      :ok -> {:ok, %{state | next_id: id + 1, rpc: Map.put(state.rpc, id, tag)}}
      :error -> {:error, state}
    end
  end

  defp send_notification(state, method, params) do
    write_message(state.port, %{"method" => method, "params" => params})
  end

  defp send_server_response(state, id, {:result, result}) do
    write_message(state.port, %{"id" => id, "result" => result})
  end

  defp send_server_response(state, id, {:error, error}) do
    write_message(state.port, %{"id" => id, "error" => error})
  end

  defp write_message(port, message) when is_port(port) do
    Port.command(port, [JSON.encode!(message), "\n"])
    :ok
  rescue
    ArgumentError -> :error
  end

  defp write_message(_port, _message), do: :error

  defp forward_event(state, request, event) do
    event_bytes = byte_size(JSON.encode!(event))
    total_bytes = request.event_bytes + event_bytes
    total_events = request.event_count + 1

    if total_bytes <= state.max_turn_bytes and total_events <= state.max_turn_events do
      request = %{request | event_bytes: total_bytes, event_count: total_events}
      send(request.caller, {:codex_app_server, request.ref, {:event, event}})
      {:ok, %{state | requests: Map.put(state.requests, request.ref, request)}, request}
    else
      detail = %{
        "message" => "Codex app-server turn notification limit exceeded",
        "maxBytes" => state.max_turn_bytes,
        "maxEvents" => state.max_turn_events
      }

      send_terminal(request, {:error, :backend, detail})
      {_request, state} = remove_request(state, request.ref)
      {:error, state |> interrupt_and_drain(request) |> dispatch_waiting()}
    end
  end

  defp send_terminal(request, terminal) do
    send(request.caller, {:codex_app_server, request.ref, {:terminal, terminal}})
  end

  defp protocol_failed(state, label, reason) do
    detail = maybe_put(%{"message" => "Codex app-server emitted #{label}"}, "reason", reason)

    close_port(state.port)
    state |> fail_transport(detail, :backend) |> stopped_state()
  end

  defp transport_write_failed(state) do
    detail = %{"message" => "Codex app-server transport closed while writing"}
    kind = if state.port_status in [:starting, :initializing], do: :unavailable, else: :backend
    close_port(state.port)
    state |> fail_transport(detail, kind) |> stopped_state()
  end

  defp fail_transport(state, detail, kind) do
    Enum.each(state.requests, fn {_ref, request} ->
      if request.phase in [:turn_starting, :running] do
        send(request.caller, {:codex_app_server, request.ref, {:transport_lost, detail}})
      else
        send_terminal(request, {:error, kind, detail})
      end

      Process.cancel_timer(request.timer, async: true, info: false)
      Process.demonitor(request.monitor, [:flush])
    end)

    %{
      state
      | requests: %{},
        waiting: :queue.new(),
        rpc: %{},
        by_monitor: %{},
        by_thread: %{},
        by_turn: %{},
        draining: MapSet.new()
    }
  end

  defp stopped_state(state) do
    cancel_initialize_timer(state.initialize_timer)

    %{
      state
      | port: nil,
        port_status: :stopped,
        command: nil,
        next_id: 1,
        initialize_timer: nil
    }
  end

  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp response_error(%{"error" => error}), do: inspect(error)
  defp response_error(response), do: inspect(response)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp cancel_initialize_timer(nil), do: :ok

  defp cancel_initialize_timer(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end
end
