defmodule MC714.P2.Consensus.Paxos do
  @moduledoc """
  Módulo de consenso distribuído.

  Implementa o algoritmo Paxos, de Leslie Lamport.

  Qualquer processo pode enviar propostas para o algoritmo, e pode descobrir qual valor foi
  decidido. O único conjunto restrito de processos é o conjunto de "eleitores", que votam nas
  "urnas"; este conjunto é decidido uma vez e nunca alterado (de forma que mesmo que novos nós
  passem a fazer parte do cluster, consensos anteriores não sejam afetados).

  Assume-se que apenas um processo tentará propor um valor de cada vez no cluster (isso é
  garantido externamente, com o uso de um mutex), mas o algoritmo garante que mesmo no caso em
  que dois processos enviam propostas, apenas uma será eleita.

  """

  @type t :: GenServer.server()
  @type options :: [
          GenServer.option()
          | {:node, atom}
          | {:acceptors, MapSet.t(atom)}
          | {:ledger, String.t()}
          | {:request_timeout, pos_integer}
        ]

  @type ballot :: {non_neg_integer, atom} | -1

  require Logger
  use GenServer

  defmodule State do
    @typedoc """
    Estado de um processo do agoritmo.

    ## Campos
    - `:key` - Chave do consenso.
    - `:phase` - `:request_ballot` ou `:propose_value`, dependendo da etapa do algoritmo em que
                 o processo se encontra.
    - `:node` - Nome do nó atual, deve ser único no cluster. Usado para criar uma ordenação total
                das urnas.
    - `:ledger` - Arquivo para armazenamento de estado persistente.
    - `:acceptors` - Conjunto de nós que participam da eleição.
    - `:proposal` - Valor proposto.
    - `:request_timeout` - Tempo máximo que o processo aguarda respostas para o consenso. Passado
                           esse tempo, o processo tenta criar uma nova urna.
    - `:request_timeout_ref` - Referência ao processo de timeout.
    - `:callback` - Referências a processos esperando por respostas a `:get_decree`.
    - `:last_tried` - Última urna que o processo atual tentou criar.
    - `:current_value` - Valor escolhido para a urna atual.
    - `:previous_ballot` - Urna mais recente em que o processo votou.
    - `:previous_value` - Valor escolhido na urna `previous_ballot`.
    - `:next_ballot` - Urna mais recente de que o processo concordou em participar.
    - `:accepted` - Conjunto de nós que aceitaram a urna sendo proposta.
    - `:max_accepted_ballot` - Urna mais recente aceita por algum dos pares que aceitaram a urna.
    - `:max_accepted_value` - Valor escolhido na urna `max_accepted_ballot`.
    - `:rejected` - Conjunto de nós que rejeitaram a urna sendo proposta.
    - `:max_rejected_ballot` - Urna mais recente aceita por algum dos pares que _rejeitaram_ a urna.
                        Usado para ajustar a proposta de urna para um valor mais recente.
    - `:voted` - Conjunto de nós que votaram em favor do valor proposto na urna.
    - `:decided` - Indica se consenso foi atingido.
    - `:decided_value` - Valor decidido pelo consenso.
    """
    @type t :: %__MODULE__{
            key: term,
            phase: :idle | :request_ballot | :propose_value,
            node: atom,
            ledger: File.t(),
            acceptors: MapSet.t(atom),
            proposal: term,
            request_timeout: pos_integer,
            request_timeout_ref: reference,
            callback: [GenServer.from()],
            last_tried: MC714.P2.Consensus.Paxos.ballot(),
            current_value: term,
            previous_ballot: MC714.P2.Consensus.Paxos.ballot(),
            previous_value: term,
            next_ballot: MC714.P2.Consensus.Paxos.ballot(),
            # quorum
            accepted: MapSet.t(t),
            max_accepted_ballot: MC714.P2.Consensus.Paxos.ballot(),
            max_accepted_value: term,
            rejected: MapSet.t(term),
            max_rejected_ballot: MC714.P2.Consensus.Paxos.ballot(),
            voted: MapSet.t(term),
            decided: boolean,
            decided_value: term
          }

    defstruct key: nil,
              phase: :idle,
              node: nil,
              ledger: nil,
              acceptors: nil,
              proposal: nil,
              request_timeout: 5_000,
              request_timeout_ref: nil,
              callback: [],
              last_tried: -1,
              current_value: nil,
              previous_ballot: -1,
              previous_value: nil,
              next_ballot: -1,
              accepted: nil,
              max_accepted_ballot: -1,
              max_accepted_value: nil,
              rejected: nil,
              max_rejected_ballot: -1,
              voted: nil,
              decided: false,
              decided_value: -1

    @spec load_persistent_state(t) :: t
    def load_persistent_state(state) do
      bin =
        case File.read(state.ledger) do
          {:ok, data} -> data
          {:error, :enoent} -> <<>>
        end

      if byte_size(bin) != 0 do
        {
          decided,
          decided_value,
          last_tried,
          previous_ballot,
          previous_value,
          next_ballot
        } = :erlang.binary_to_term(bin)

        %{
          state
          | decided: decided,
            decided_value: decided_value,
            last_tried: last_tried,
            previous_ballot: previous_ballot,
            previous_value: previous_value,
            next_ballot: next_ballot
        }
      else
        state
      end
    end

    @spec persist(t) :: t
    def persist(state) do
      bin =
        :erlang.term_to_binary({
          state.decided,
          state.decided_value,
          state.last_tried,
          state.previous_ballot,
          state.previous_value,
          state.next_ballot
        })

      :ok = File.write(state.ledger, bin)
      state
    end

    def with_proposal(state, value), do: %{state | proposal: value}

    def with_next_ballot(state, ballot), do: %{state | next_ballot: ballot} |> State.persist()

    def cancel_timeout(state) do
      if state.request_timeout_ref != nil, do: Process.cancel_timer(state.request_timeout_ref)
      %{state | request_timeout_ref: nil}
    end

    def add_callback(state, pid), do: %{state | callback: [pid | state.callback]}

    def add_rejection(state, peer, max_ballot),
      do: %{
        state
        | rejected: MapSet.put(state.rejected, peer),
          max_rejected_ballot: max(state.max_rejected_ballot, max_ballot)
      }

    def add_accept(state, peer, max_ballot, max_ballot_value) do
      {mbal, mval} =
        max(
          {max_ballot, max_ballot_value},
          {state.max_accepted_ballot, state.max_accepted_value}
        )

      %{
        state
        | accepted: MapSet.put(state.accepted, peer),
          max_accepted_ballot: mbal,
          max_accepted_value: mval
      }
    end

    def add_vote(state, peer), do: %{state | voted: MapSet.put(state.voted, peer)}

    def enter_request_phase(state, ballot),
      do:
        %{
          state
          | phase: :request_ballot,
            last_tried: ballot,
            accepted: MapSet.new(),
            rejected: MapSet.new()
        }
        |> State.persist()

    def with_value(state, value), do: %{state | current_value: value}

    def enter_propose_phase(state, value),
      do:
        %{
          state
          | phase: :propose_value,
            voted: MapSet.new()
        }
        |> State.with_value(value)
        |> State.persist()

    def voted(state, ballot, value),
      do:
        %{
          state
          | previous_ballot: ballot,
            previous_value: value
        }
        |> State.persist()

    def reached_consensus(state) do
      for client <- state.callback, do: GenServer.reply(client, {:ok, state.current_value})

      %{
        state
        | decided: true,
          decided_value: state.current_value,
          callback: []
      }
      |> State.persist()
      |> State.cancel_timeout()
    end

    def with_timeout(state, timeout) do
      ref = Process.send_after(self(), :request_timeout, timeout)
      %{state | request_timeout_ref: ref}
    end
  end

  defmodule RPC do
    def request_ballot(peer, key, ballot),
      do: send_message(peer, key, {:request_ballot, Node.self(), ballot})

    def reject_ballot(peer, key, ballot, previous_ballot),
      do: send_message(peer, key, {:ballot_reject, Node.self(), ballot, previous_ballot})

    def accept_ballot(peer, key, ballot, previous_ballot, previous_value),
      do:
        send_message(
          peer,
          key,
          {:ballot_accept, Node.self(), ballot, previous_ballot, previous_value}
        )

    def begin_ballot(peer, key, ballot, value),
      do: send_message(peer, key, {:begin_ballot, Node.self(), ballot, value})

    def vote(peer, key, ballot),
      do: send_message(peer, key, {:vote, Node.self(), ballot})

    def success(peer, key, value),
      do: send_message(peer, key, {:success, value})

    defp send_message(peer, key, message),
      do: GenServer.cast({MC714.P2.Consensus.Manager.Proxy, peer}, {key, message})
  end

  @doc """
  Propõe um valor para o consenso. O valor proposto pode ou não ser o valor final, a depender se
  algum valor já foi proposto previamente, seguindo a lógica do algoritmo.

  Esta função só pode ser chamada uma vez. Caso contrário, retorna `:already_proposed`.
  """
  @spec propose(t, term) :: {:ok | :noop, term}
  def propose(paxos, value), do: GenServer.call(paxos, {:propose, value}, :infinity)

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    state = %State{
      node: opts[:node],
      key: opts[:key],
      ledger: opts[:ledger],
      acceptors: opts[:acceptors],
      request_timeout: opts[:request_timeout] || 5_000,
      voted: MapSet.new()
    }

    GenServer.start_link(__MODULE__, state, opts)
  end

  @impl GenServer
  def init(state) do
    state = State.load_persistent_state(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:propose, value}, from, state) do
    if state.decided do
      {:reply, {:noop, state.decided_value}, state}
    else
      seq =
        case state.last_tried do
          {seq, _} -> seq
          -1 -> 0
        end

      state =
        state
        |> State.with_proposal(value)
        |> request_ballot(seq + 1)

      state = State.add_callback(state, from)
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast(message, state) when state.decided do
    if elem(message, 0) == :success do
      State.reached_consensus(state)
    else
      peer = elem(message, 1)
      RPC.success(peer, state.key, state.decided_value)
    end

    {:noreply, state}
  end

  def handle_cast({:request_ballot, peer, ballot}, state) do
    state =
      cond do
        # Se não faz parte do conjunto de eleitores, não opina na criação da urna.
        not is_acceptor?(state) ->
          state

        # Não participa de urnas anteriores a alguma em que já concordou em participar.
        ballot < state.previous_ballot ->
          Logger.debug("Rejecting stale ballot #{inspect(ballot)} on consensus #{state.key}")
          RPC.reject_ballot(peer, state.key, ballot, state.previous_ballot)
          state

        # Caso contrário, concorda em participar da urna e não participar em nenhuma urna
        # anterior. Também informa o valor em que votou na maior urna anterior a esta (se votou em
        # alguma).
        true ->
          Logger.debug("Accepting ballot #{inspect(ballot)} on consensus #{state.key}")

          state = State.with_next_ballot(state, ballot)

          RPC.accept_ballot(peer, state.key, ballot, state.previous_ballot, state.previous_value)

          state
      end

    {:noreply, state}
  end

  def handle_cast({:ballot_reject, peer, ballot, max_ballot}, state)
      when ballot == state.last_tried do
    Logger.debug(
      "Ballot on consensus #{state.key} was rejected by peer #{inspect(peer)}: #{inspect(ballot)}, max ballot was " <>
        inspect(max_ballot)
    )

    state = State.add_rejection(state, peer, max_ballot)

    state =
      if is_majority?(state.rejected, state.acceptors) do
        # Caso alguma maioria rejeite nossa urna, ajustamos nosso número de sequência para as
        # próximas propostas.
        {seq, _} = state.max_rejected_ballot
        {max_seq, _} = state.previous_ballot

        seq = max(max_seq, seq) + 1

        Logger.debug(
          "Ballot on consensus #{state.key} rejected by quorum: #{inspect(ballot)}. Trying again with sequence number #{seq}."
        )

        state
        |> request_ballot(seq)
        |> State.cancel_timeout()
      else
        # Caso ainda não tenhamos uma maioria de rejeições, apenas armazenamos o valor da maior urna
        # apresentada em uma rejeição, para uso futuro.
        state
      end

    {:noreply, state}
  end

  def handle_cast({:ballot_accept, peer, ballot, max_ballot, max_ballot_value}, state)
      when ballot == state.last_tried and state.phase == :request_ballot do
    Logger.debug(
      "Ballot on consensus #{state.key} was accepted by peer #{inspect(peer)}: #{inspect(ballot)}. Max ballot was " <>
        inspect(max_ballot) <> ", with value #{inspect(max_ballot_value)}."
    )

    state = State.add_accept(state, peer, max_ballot, max_ballot_value)

    # Caso alguma maioria aceite nossa urna, podemos seguir para a próxima fase.
    state =
      if is_majority?(state.accepted, state.acceptors) do
        quorum = state.accepted

        # O valor escolhido para a urna é o valor da maior urna em que algum dos membros do quorum,
        # ou o valor proposto pelo próprio processo caso nenhuma tal urna exista.
        value =
          if state.max_accepted_ballot != -1 do
            state.max_accepted_value
          else
            state.proposal
          end

        Logger.debug(
          "Ballot on consensus #{state.key} accepted by quorum: #{inspect(ballot)}. Value is #{inspect(value)}."
        )

        # Envia a proposta para cada nó no quorum.
        state = State.enter_propose_phase(state, value)

        for peer <- quorum, do: RPC.begin_ballot(peer, state.key, ballot, value)

        state
      else
        # Caso ainda não tenhamos uma maioria de aceites, apenas armazenamos o valor escolhido na
        # maior urna entre os nós que aceitaram a urna.
        state
      end

    {:noreply, state}
  end

  def handle_cast({:begin_ballot, peer, ballot, value}, state)
      when ballot == state.next_ballot and state.next_ballot > state.previous_ballot do
    Logger.debug(
      "Voting for ballot #{inspect(ballot)} with value #{inspect(value)} on consensus #{state.key}."
    )

    state = State.voted(state, ballot, value)
    RPC.vote(peer, state.key, ballot)

    {:noreply, state}
  end

  def handle_cast({:vote, peer, ballot}, state)
      when ballot == state.last_tried and state.phase == :propose_value do
    Logger.debug(
      "Peer #{inspect(peer)} voted on ballot #{inspect(ballot)} on consensus #{state.key}."
    )

    state = State.add_vote(state, peer)

    state =
      if MapSet.subset?(state.accepted, state.voted) do
        # Quando alguma maioria vota na mesma urna, chegou-se a um consenso.
        Logger.info(
          "Consensus #{state.key} reached on ballot #{inspect(ballot)} with value #{inspect(state.current_value)}."
        )

        state = State.reached_consensus(state)

        for peer <- Node.list(), do: RPC.success(peer, state.key, state.current_value)

        state
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:success, value}, state) do
    Logger.info("Consensus #{state.key} reached with value #{inspect(value)}.")

    state = State.with_value(state, value) |> State.reached_consensus()
    {:noreply, state}
  end

  def handle_cast(message, state) do
    Logger.warn("Message discarded: #{inspect(message)}. State was: #{inspect(state)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:request_timeout, state)
      when state.request_timeout_ref != nil and not state.decided do
    {seq, _} = max(state.last_tried, state.max_rejected_ballot)
    seq = seq + 1

    Logger.warn(
      "Ballot request timed out on consensus #{state.key}. Retrying with sequence number #{seq}."
    )

    state = request_ballot(state, seq)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp request_ballot(state, seq) do
    ballot = {seq, state.node}

    Logger.debug(
      "Requesting creation of ballot #{inspect(ballot)} on consensus #{state.key}. State: #{inspect(state)}"
    )

    state =
      if state.request_timeout != :infinity do
        State.with_timeout(state, state.request_timeout)
      else
        state
      end
      |> State.enter_request_phase(ballot)

    for peer <- [Node.self() | Node.list()], do: RPC.request_ballot(peer, state.key, ballot)

    state
  end

  defp is_acceptor?(state), do: MapSet.member?(state.acceptors, state.node)

  defp is_majority?(subset, set), do: 2 * MapSet.size(subset) > MapSet.size(set)
end
