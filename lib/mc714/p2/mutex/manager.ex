defmodule MC714.P2.Mutex.Manager do
  @registry MC714.P2.Mutex.Manager.Registry
  @supervisor MC714.P2.Mutex.Manager.Supervisor

  use GenServer

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, [{:name, MC714.P2.Mutex} | opts])

  @impl GenServer
  def init(:ok) do
    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: @registry},
        {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
      ],
      strategy: :one_for_one
    )
  end

  @impl GenServer
  def handle_cast({key, message}, _) do
    ensure_lock_exists(key)
    GenServer.cast(via_lock(key), message)
    {:noreply, nil}
  end

  @impl GenServer
  def handle_call({key, message}, from, _) do
    ensure_lock_exists(key)

    Task.start_link(fn ->
      result = GenServer.call(via_lock(key), message, :infinity)
      GenServer.reply(from, result)
    end)

    {:noreply, nil}
  end

  defp ensure_lock_exists(key) do
    if Registry.lookup(@registry, {key, MC714.P2.Mutex.Lock}) == [] do
      create_lock(key)
    end
  end

  defp create_lock(key) do
    clock_name = via_clock(key)

    clock_spec = %{
      id: :clock,
      start: {
        MC714.P2.LogicClock,
        :start_link,
        [[initial: 0, name: clock_name]]
      }
    }

    lock_name = via_lock(key)

    lock_spec = %{
      id: :lock,
      start: {
        MC714.P2.Mutex.Lock,
        :start_link,
        [[logic_clock: clock_name, key: key, name: lock_name]]
      }
    }

    supervisor_spec = %{
      id: key,
      start: {Supervisor, :start_link, [[lock_spec, clock_spec], [strategy: :one_for_all]]},
      type: :supervisor
    }

    {:ok, _} = DynamicSupervisor.start_child(@supervisor, supervisor_spec)
    :ok
  end

  defp via_clock(key), do: via_registry(key, MC714.P2.LogicClock)
  defp via_lock(key), do: via_registry(key, MC714.P2.Mutex.Lock)
  defp via_registry(key, module), do: {:via, Registry, {@registry, {key, module}, module}}
end
