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

  use GenServer

  alias MC714.P2.Consensus.StateMachine
  alias MC714.P2.Consensus.Proposer

  defmodule State do
    defstruct [:request_timeout, :supervisor]
  end

  defmodule Proxy do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_cast({seqno, message}, state) do
      Task.Supervisor.start_child(
        MC714.P2.Consensus.Manager.TaskSupervisor,
        fn ->
          MC714.P2.Consensus.Manager.ensure_exists(seqno)
          GenServer.cast(MC714.P2.Consensus.Manager.via_paxos(seqno), message)
        end
      )

      {:noreply, state}
    end
  end

  def ensure_exists(seqno),
    do: GenServer.call(MC714.P2.Consensus.Manager, {:ensure_exists, seqno}, :infinity)

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    state = %State{request_timeout: opts[:request_timeout]}
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
          StateMachine,
          {Task.Supervisor, name: MC714.P2.Consensus.Manager.TaskSupervisor}
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
  def handle_call({:ensure_exists, seqno}, _from, state) do
    if Registry.lookup(@registry, {seqno, MC714.P2.Consensus.Paxos}) == [] do
      create_consensus(state, seqno)
    end
    {:reply, :ok, state}
  end

  defp create_consensus(state, seqno) do
    decided_seqno = MC714.P2.Consensus.StateMachine.get_seqno()

    if decided_seqno < seqno do
      create_consensus(state, seqno - 1)
    end

    instance = via_paxos(seqno)

    {_, acceptors} = StateMachine.get_acceptors()

    paxos_opts = [
      name: instance,
      key: seqno,
      ledger: "/var/paxos/#{seqno}.ledger",
      acceptors: acceptors,
      request_timeout: state.request_timeout,
      node: Application.fetch_env!(:mc714_p2, :paxos)[:node]
    ]

    paxos_spec = %{
      id: seqno,
      start: {MC714.P2.Consensus.Paxos, :start_link, [paxos_opts]}
    }

    DynamicSupervisor.start_child(@supervisor, paxos_spec)
  end

  def via_paxos(key), do: via_registry(key, MC714.P2.Consensus.Paxos)
  defp via_registry(key, module), do: {:via, Registry, {@registry, {key, module}, module}}
end
