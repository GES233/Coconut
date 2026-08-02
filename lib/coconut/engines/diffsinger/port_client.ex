defmodule Coconut.Engines.DiffSinger.PortClient do
  @moduledoc """
  Port-based client for the DiffSinger stdio worker (`worker.py`,
  colocated in this directory).

  A single Python process is kept alive per worker key
  (`{python, voicebank_root}`): the worker loads the ONNX voicebank at
  startup (seconds), so it is reused across calls; a config change
  transparently restarts it. Calls are serialized — one outstanding
  request at a time — over newline-delimited JSON.

  The worker script path defaults to the colocated `worker.py`; override
  with the `:worker` config key (e.g. when packaging a release, where
  `lib/` sources are not shipped — copy the script somewhere durable and
  point `:worker` at it).
  """

  alias Coconut.Engines.DiffSinger.PortClient.Server

  @doc """
  Send one request map to the worker and wait for its response.

  Returns `{:ok, result_map}` or `{:error, reason}`; a crashed worker
  fails the call (and every queued call) with `{:worker_exit, status}`.
  """
  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(payload, config) do
    {:ok, _pid} = ensure_server()
    GenServer.call(Server, {:request, payload, config}, :infinity)
  end

  defp ensure_server do
    case Process.whereis(Server) do
      nil ->
        case Server.start_link() do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end

      pid ->
        {:ok, pid}
    end
  end

  defmodule Server do
    @moduledoc false

    use GenServer

    require Logger

    @line_limit 64_000_000
    @worker_path Path.expand("worker.py", __DIR__)

    def start_link do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    @impl true
    def init(:ok) do
      {:ok,
       %{
         port: nil,
         key: nil,
         ready: false,
         buffer: "",
         current: nil,
         queue: :queue.new(),
         next_id: 1
       }}
    end

    @impl true
    def handle_call({:request, payload, config}, from, state) do
      key = worker_key(config)

      case ensure_worker(state, key, config) do
        {:ok, state} ->
          id = state.next_id

          state = %{
            state
            | next_id: id + 1,
              queue: :queue.in({id, from, payload}, state.queue)
          }

          {:noreply, maybe_dispatch(state)}

        {:error, reason} ->
          {:reply, {:error, reason}, %{state | port: nil, key: nil}}
      end
    end

    @impl true
    def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
      {:noreply, handle_line(%{state | buffer: ""}, state.buffer <> line)}
    end

    def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
      {:noreply, %{state | buffer: state.buffer <> chunk}}
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      error = {:error, {:worker_exit, status}}

      if state.current, do: GenServer.reply(elem(state.current, 1), error)

      Enum.each(:queue.to_list(state.queue), fn {_id, from, _payload} ->
        GenServer.reply(from, error)
      end)

      {:noreply,
       %{state | port: nil, key: nil, ready: false, buffer: "", current: nil, queue: :queue.new()}}
    end

    def handle_info(_other, state), do: {:noreply, state}

    # ---- Worker lifecycle ----

    defp ensure_worker(state, key, config) do
      if state.key == key and is_port(state.port) do
        {:ok, state}
      else
        spawn_worker(state, key, config)
      end
    end

    defp spawn_worker(state, key, config) do
      if is_port(state.port), do: Port.close(state.port)

      [cmd | args] = Map.get(config, :python, ["python"])

      case System.find_executable(cmd) do
        nil ->
          {:error, {:python_not_found, cmd}}

        executable ->
          script = Map.get(config, :worker, @worker_path)

          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :stream,
              :exit_status,
              {:line, @line_limit},
              {:args, args ++ [script, Map.fetch!(config, :voicebank_root)]}
            ])

          {:ok, %{state | port: port, key: key, ready: false, buffer: "", current: nil}}
      end
    end

    defp worker_key(config) do
      {Map.get(config, :python, ["python"]), Map.get(config, :voicebank_root),
       Map.get(config, :worker, @worker_path)}
    end

    # ---- Protocol ----

    defp maybe_dispatch(%{ready: true, current: nil} = state) do
      case :queue.out(state.queue) do
        {:empty, _} ->
          state

        {{:value, {id, from, payload}}, queue} ->
          line = payload |> Map.put(:id, id) |> Jason.encode!()
          Port.command(state.port, line <> "\n")
          %{state | current: {id, from}, queue: queue}
      end
    end

    defp maybe_dispatch(state), do: state

    defp handle_line(state, line) do
      case Jason.decode(line) do
        {:ok, %{"ready" => true}} ->
          maybe_dispatch(%{state | ready: true})

        {:ok, %{"id" => id} = response} ->
          state = reply_current(state, id, response)
          maybe_dispatch(state)

        {:error, _} ->
          Logger.warning("ds_worker sent a non-JSON line: #{String.slice(line, 0, 200)}")
          state
      end
    end

    defp reply_current(%{current: {id, from}} = state, id, response) do
      reply = if response["ok"], do: {:ok, response["result"]}, else: {:error, response["error"]}
      GenServer.reply(from, reply)
      %{state | current: nil}
    end

    defp reply_current(state, id, _response) do
      Logger.warning("ds_worker sent a response for stale id #{id}")
      state
    end
  end
end
