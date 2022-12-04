defmodule MC714.P2.Consensus.StateMachine do
  @commit_file "/var/paxos/state_machine"

  defmodule State do
    defstruct [:seqno, :decrees, :acceptors]

    def next_decree(state, {_, :noop}), do: state |> increment_seqno()

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

  def init(), do: fetch_state(Node.list())

  defp fetch_state([]) do
    bin =
      case File.read(@commit_file) do
        {:ok, data} -> data
        {:error, :enoent} -> <<>>
      end

    if byte_size(bin) != 0 do
      :erlang.binary_to_term(bin)
    else
      %State{
        seqno: -1,
        decrees: [],
        acceptors: MapSet.new([Application.fetch_env!(:mc714_p2, :paxos)[:root]])
      }
    end
  end

  defp fetch_state([peer | rest]) do
    peer_state = get_state({__MODULE__, peer})
    most_recent = fetch_state(rest)

    if peer_state.seqno > most_recent.seqno do
      peer_state
    else
      most_recent
    end
  end

  def commit() do
    bin = :erlang.term_to_binary(get_state())
    :ok = File.write(@commit_file, bin)
  end

  def decree(seqno, decree),
    do:
      Agent.update(__MODULE__, fn state ->
        cond do
          state.seqno == seqno - 1 -> State.next_decree(state, decree)
          true -> state
        end
      end)

  def get_state(sm \\ __MODULE__), do: Agent.get(sm, & &1)
  def get_seqno(sm \\ __MODULE__), do: Agent.get(sm, & &1.seqno)
  def get_decrees(sm \\ __MODULE__), do: Agent.get(sm, &{&1.seqno, &1.decrees})
  def get_acceptors(sm \\ __MODULE__), do: Agent.get(sm, &{&1.seqno, &1.acceptors})
end
