defmodule MC714.P2.Consensus.Manager do
  @registry MC714.P2.Consensus.Manager.Registry
  @proxy MC714.P2.Consensus.Manager.Proxy
  @supervisor MC714.P2.Consensus.Manager.Supervisor

  @moduledoc """
  """

  @type t :: GenServer.server()
  @type options :: [
          GenServer.option()
          | {:node, atom}
          | {:request_timeout, pos_integer}
        ]

  require Logger
  use GenServer

  defmodule State do
    defstruct [:request_timeout, :seqno, :supervisor]
  end

  defmodule Proxy do
    require Logger
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_cast({seqno, message}, state) do
      Task.Supervisor.start_child(
        MC714.P2.Consensus.Manager.TaskSupervisor,
        fn ->
          GenServer.call(MC714.P2.Consensus.Manager, {:ensure_exists, seqno, true}, :infinity)
          GenServer.cast(MC714.P2.Consensus.Manager.via_paxos(seqno), message)
        end
      )

      {:noreply, state}
    end
  end

  defmodule StateMachine do
    defmodule State do
      defstruct [:seqno, :decrees, :acceptors]

      def next_decree(state, :noop), do: state |> increment_seqno()

      def next_decree(state, {_, {:new_acceptor, node}}),
        do: %{state | acceptors: MapSet.put(state.acceptors, node)} |> increment_seqno()

      def next_decree(state, {_, {:disconnect, node}}),
        do: %{state | acceptors: MapSet.delete(state.acceptors, node)} |> increment_seqno()

      def next_decree(state, {_, {:decree, value}}),
        do: %{state | decrees: [value | state.decrees]} |> increment_seqno()

      defp increment_seqno(state), do: %{state | seqno: state.seqno + 1}
    end

    def child_spec(opts),
      do: %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, opts}
      }

    def start_link(opts \\ []), do: Agent.start_link(&init/0, [{:name, __MODULE__} | opts])

    def init(),
      do: %State{
        seqno: -1,
        decrees: [],
        acceptors: MapSet.new([Application.fetch_env!(:mc714_p2, :paxos)[:root]])
      }

    def decree(seqno, decree),
      do:
        Agent.update(__MODULE__, fn state ->
          cond do
            state.seqno == seqno - 1 -> State.next_decree(state, decree)
            true -> state
          end
        end)

    def get_state(), do: Agent.get(__MODULE__, & &1)
    def get_seqno(), do: Agent.get(__MODULE__, & &1.seqno)
    def get_decrees(), do: Agent.get(__MODULE__, & &1.decrees)
    def get_acceptors(), do: Agent.get(__MODULE__, & &1.acceptors)
  end

  defmodule Proposer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call({:request, value}, _from, _state) do
      seqno = until_pass({:decree, value})
      {:reply, :ok, seqno}
    end

    def handle_call(:become_acceptor, _from, state) do
      node = Application.fetch_env!(:mc714_p2, :paxos)[:node]

      acceptors = StateMachine.get_acceptors()

      if MapSet.member?(acceptors, node) do
        {:reply, :noop, state}
      else
        :ok = until_pass({:new_acceptor, node})
        {:reply, :ok, state}
      end
    end

    def handle_call(:disconnect, _from, state) do
      node = Application.fetch_env!(:mc714_p2, :paxos)[:node]

      acceptors = StateMachine.get_acceptors()

      if not MapSet.member?(acceptors, node) do
        {:reply, :noop, state}
      else
        :ok = until_pass({:disconnect, node})
        {:reply, :ok, state}
      end
    end

    defp until_pass(value) do
      seqno = StateMachine.get_seqno() + 1
      GenServer.call(MC714.P2.Consensus.Manager, {:ensure_exists, seqno, true}, :infinity)

      uid = :rand.bytes(16)
      instance = MC714.P2.Consensus.Manager.via_paxos(seqno)
      {_, decree} = GenServer.call(instance, {:propose, {uid, value}}, :infinity)
      StateMachine.decree(seqno, decree)

      case decree do
        {uid2, _} when uid == uid2 -> :ok
        _ -> until_pass(value)
      end
    end
  end

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    state = %State{
      request_timeout: opts[:request_timeout],
      seqno: -1
    }

    GenServer.start_link(__MODULE__, state, [{:name, __MODULE__} | opts])
  end

  @impl GenServer
  def init(state) do
    {:ok, pid} =
      Supervisor.start_link(
        [
          {Registry, keys: :unique, name: @registry},
          {DynamicSupervisor, strategy: :one_for_one, name: @supervisor},
          {Proxy, name: @proxy},
          {Proposer, name: MC714.P2.Consensus},
          {Task.Supervisor, name: MC714.P2.Consensus.Manager.TaskSupervisor},
          StateMachine
        ],
        strategy: :one_for_one
      )

    Task.Supervisor.start_child(
      MC714.P2.Consensus.Manager.TaskSupervisor,
      fn -> MC714.P2.Consensus.become_acceptor() end
    )

    state = %{state | supervisor: pid}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:ensure_exists, seqno, new}, _from, state) do
    seqno = if state.seqno < seqno do
      create_consensus(state, seqno, new)
    else
      state.seqno
    end

    state = %{state | seqno: seqno}

    {:reply, :ok, state}
  end

  def handle_call(:seqno, _from, state), do: {:reply, state.seqno, state}

  defp create_consensus(state, seqno, new) when seqno > state.seqno do
    seq_decided = create_consensus(state, seqno - 1, false)

    instance = via_paxos(seqno)

    paxos_opts = [
      name: instance,
      key: seqno,
      ledger: "/var/paxos/#{seqno}",
      acceptors: StateMachine.get_acceptors(),
      request_timeout: state.request_timeout,
      node: Application.fetch_env!(:mc714_p2, :paxos)[:node]
    ]

    paxos_spec = %{
      id: seqno,
      start: {MC714.P2.Consensus.Paxos, :start_link, [paxos_opts]}
    }

    DynamicSupervisor.start_child(@supervisor, paxos_spec)

    if not new do
      {_, decree} = GenServer.call(instance, {:propose, :noop})
      StateMachine.decree(seqno, decree)
      Logger.info("Created consensus #{seqno}, with decree #{inspect(decree)}")

      if seq_decided == seqno - 1 do
        seqno
      else
        seq_decided
      end
    else
      Logger.info("Created consensus #{seqno} with no known decree")
      seq_decided
    end
  end

  defp create_consensus(state, seqno, _) when seqno <= state.seqno, do: state.seqno

  def via_paxos(key), do: via_registry(key, MC714.P2.Consensus.Paxos)
  defp via_registry(key, module), do: {:via, Registry, {@registry, {key, module}, module}}
end
