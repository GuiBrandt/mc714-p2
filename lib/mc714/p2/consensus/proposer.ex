defmodule MC714.P2.Consensus.Proposer do
  @lock_timeout 1_000

  use GenServer

  alias MC714.P2.Consensus.StateMachine

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:request, value}, _from, state) do
    seqno = until_pass({:decree, value})
    {:reply, seqno, state}
  end

  def handle_call(:sync, _from, state) do
    seqno = until_pass(:noop)
    {:reply, seqno, state}
  end

  def handle_call(:become_acceptor, _from, state) do
    node = Application.fetch_env!(:mc714_p2, :paxos)[:node]

    # Sincroniza antes de tentar conectar
    until_pass(:noop)

    {_, acceptors} = StateMachine.get_acceptors()

    if MapSet.member?(acceptors, node) do
      {:reply, :noop, state}
    else
      seqno = until_pass({:new_acceptor, node})
      {:reply, seqno, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    node = Application.fetch_env!(:mc714_p2, :paxos)[:node]

    # Sincroniza antes de tentar desconectar
    until_pass(:noop)

    {_, acceptors} = StateMachine.get_acceptors()

    if not MapSet.member?(acceptors, node) do
      {:reply, :noop, state}
    else
      seqno = until_pass({:disconnect, node})
      {:reply, seqno, state}
    end
  end

  defp until_pass(value) do
    seqno = StateMachine.get_seqno() + 1
    MC714.P2.Consensus.Manager.ensure_exists(seqno)

    lock_key = {MC714.P2.Consensus, seqno}

    case MC714.P2.Mutex.lock(lock_key, @lock_timeout) do
      :ok ->
        uid = :rand.bytes(16)
        instance = MC714.P2.Consensus.Manager.via_paxos(seqno)
        {_, decree} = MC714.P2.Consensus.Paxos.propose(instance, {uid, value})
        :ok = MC714.P2.Mutex.release(lock_key)

        StateMachine.decree(seqno, decree)

        case decree do
          {uid2, _} when uid == uid2 -> seqno
          _ -> until_pass(value)
        end

      {:failed, :timeout} ->
        until_pass(value)
    end
  end
end
