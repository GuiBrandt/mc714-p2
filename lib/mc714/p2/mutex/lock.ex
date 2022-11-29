defmodule MC714.P2.Mutex.Lock do
  @moduledoc """
  Módulo de trava distribuída de exclusão mútua.

  Implementa o algoritmo de Ricart–Agrawala, uma extensão e otimização do
  algoritmo de exclusão mútua de Lamport. (https://doi.org/10.1145/358527.358537)

  O algoritmo funciona sob as seguintes premissas:
    - A rede é confiável (mensagens enviadas são entregues, sem perda de dados)
    - O tempo de transmissão na rede é variável
    - Mensagens podem chegar fora de ordem
    - Nós participantes no algoritmo operam corretamente

  O número de mensagens entre nós necessárias para que uma trava seja decidida
  é de 2 * (N - 1), onde N representa o número de nós na rede.

  Adicionalmente, um mecanismo de timeout é implementado para evitar que um processo espere
  indefinidamente sem nunca conseguir adquirir a trava caso alguma mensagem não seja propagada
  corretamente.
  """

  @type t :: GenServer.server()
  @type options :: [GenServer.option() | {:logic_clock, LogicClock.t()} | {:key, term()}]

  use GenServer

  require Logger
  alias MC714.P2.LogicClock

  defmodule State.Internal do
    @typedoc """
    Informações internas (não relacionadas ao algoritmo) de um processo de exclusão mútua.

    ## Campos
    - `:logic_clock` - Instância de relógio lógico usada pelo processo.
    - `:key` - Chave de exclusão mútua.
    - `:requester` - PID do processo local que pediu acesso à seção crítica.
    - `:timeout_ref` - Identificador do processo de timeout para a requisição.
    """
    @type t :: %__MODULE__{
            logic_clock: LogicClock.t(),
            key: String.t(),
            requester: GenServer.from() | nil,
            timeout_ref: Process.reference() | nil
          }

    defstruct [:logic_clock, :key, requester: nil, timeout_ref: nil]
  end

  defmodule State do
    @typedoc """
    Estado de um processo de exclusão mútua.

    ## Campos
    - `:locking` - Se o processo tem interesse em entrar na seção crítica.
    - `:locked` - Se o processo está na seção crítica.
    - `:request_time` - Timestamp lógico do momento em que se pediu a entrada na seção crítica.
    - `:waiting` - Coleção de nós que ainda não enviaram uma resposta permitindo o acesso à seção
                   crítica.
    - `:deferred` - Lista de nós à espera de resposta para utilizarem a seção crítica.
    """
    @type t :: %__MODULE__{
            locking: boolean,
            locked: boolean,
            request_time: LogicClock.timestamp_t(),
            waiting: MapSet.t(Node.t()),
            deferred: list(Node.t()),
            internal: Internal.t()
          }

    defstruct locking: false,
              locked: false,
              request_time: nil,
              waiting: nil,
              deferred: [],
              internal: nil

    @spec reset(t) :: t
    def reset(state), do: %{state | locking: false, locked: false}

    @spec start_locking(t, GenServer.from(), LogicClock.timestamp_t()) :: t
    def start_locking(state, requester, timestamp),
      do: %{
        state
        | locking: true,
          request_time: timestamp,
          internal: %{state.internal | requester: requester}
      }

    @spec defer(t, Node.t()) :: t
    def defer(state, peer), do: Map.update!(state, :deferred, &[peer | &1])

    @spec with_timeout(t, Process.reference()) :: t
    def with_timeout(state, timeout_ref),
      do: %{state | internal: %{state.internal | timeout_ref: timeout_ref}}

    @spec waiting_for(t, list(Node.t())) :: t
    def waiting_for(state, peers), do: %{state | waiting: MapSet.new(peers)}

    @spec allowed_by(t, Node.t()) :: t
    def allowed_by(state, peer), do: Map.update!(state, :waiting, &MapSet.delete(&1, peer))

    @spec lock_acquired(t) :: t
    def lock_acquired(state),
      do: %{
        state
        | locked: true,
          locking: false,
          internal: %{
            state.internal
            | timeout_ref: nil,
              requester: nil
          }
      }
  end

  defmodule RPC do
    def request_lock(peer, key, timestamp),
      do: send_message(peer, key, :request_lock, timestamp)

    def allow_lock(peer, key, timestamp),
      do: send_message(peer, key, :allow_lock, timestamp)

    defp send_message(peer, key, message_type, timestamp),
      do: GenServer.cast({MC714.P2.Mutex, peer}, {key, {message_type, Node.self(), timestamp}})
  end

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    state = %State{
      internal: %State.Internal{
        logic_clock: opts[:logic_clock] || MC714.P2.LogicClock,
        key: opts[:key]
      }
    }

    GenServer.start_link(__MODULE__, state, opts)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  defguardp is_locking(state) when state.locking or state.locked

  @impl GenServer
  def handle_call({:lock, _}, _, state) when is_locking(state) do
    {:reply, {:failed, :already_locking}, state}
  end

  def handle_call({:lock, timeout}, requester, state) do
    timestamp = LogicClock.tick(state.internal.logic_clock)
    peers = [Node.self() | Node.list()]

    for peer <- peers, do: RPC.request_lock(peer, state.internal.key, timestamp)

    timeout_ref = Process.send_after(self(), :timeout, timeout)

    state =
      state
      |> State.start_locking(requester, timestamp)
      |> State.with_timeout(timeout_ref)
      |> State.waiting_for(peers)

    {:noreply, state}
  end

  def handle_call(:release, _, state) when not state.locked do
    {:reply, {:failed, :not_locked}, state}
  end

  def handle_call(:release, _from, state) do
    resolve_deferred(state)
    state = State.reset(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:request_lock, peer, peer_timestamp}, state) do
    # Ajustamos o relógio lógico com base na mensagem recebida.
    local_timestamp = LogicClock.coalesce(state.internal.logic_clock, peer_timestamp)

    Logger.info(
      "Peer #{peer} requested lock #{inspect(state.internal.key)} at t = #{local_timestamp}" <>
        ", with t = #{peer_timestamp}"
    )

    # Se estamos na seção crítica ou temos interesse nela (e fizemos o pedido antes do pedido que
    # recebemos), colocamos a mensagem na fila de espera.
    state =
      if has_lock_priority(state, peer, peer_timestamp) do
        State.defer(state, peer)
      else
        # Se não, avançamos o relógio lógico e respondemos imediatamente permitindo o acesso à
        # seção crítica ao remetente da mensagem.
        local_timestamp = LogicClock.tick(state.internal.logic_clock)
        allow_lock(peer, state.internal.key, local_timestamp)

        # O estado não se altera.
        state
      end

    {:noreply, state}
  end

  # Se não temos interesse em entrar na seção crítica ou se o timestamp da mensagem de permissão é
  # anterior ao timestamp do pedido (o pedido não aconteceu antes da permissão), ignoramos a
  # mensagem.
  def handle_cast({:allow_lock, _, timestamp}, state)
      when not state.locking or timestamp <= state.request_time,
      do: {:noreply, state}

  def handle_cast({:allow_lock, peer, timestamp}, state) do
    # Ajustamos o relógio lógico com base na mensagem recebida.
    timestamp = LogicClock.coalesce(state.internal.logic_clock, timestamp)

    Logger.info("Lock #{inspect(state.internal.key)} allowed by peer #{peer} at t = #{timestamp}")

    # Atualizamos a lista de nós faltantes e confirmamos se podemos entrar na seção crítica.
    state =
      state
      |> State.allowed_by(peer)
      |> confirm_lock

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:timeout, state) when state.locking do
    Logger.info("Request for lock #{inspect(state.internal.key)} timed out")
    GenServer.reply(state.internal.requester, {:failed, :timeout})
    resolve_deferred(state)
    state = State.reset(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:timeout, state), do: {:noreply, state}

  defp has_lock_priority(state, peer, peer_timestamp) do
    cond do
      state.locked -> true
      not state.locking -> false
      state.request_time < peer_timestamp -> true
      state.request_time > peer_timestamp -> false
      state.request_time == peer_timestamp -> Node.self() < peer
    end
  end

  defp resolve_deferred(state) do
    timestamp = MC714.P2.LogicClock.tick(state.internal.logic_clock)
    for peer <- state.deferred, do: allow_lock(peer, state.internal.key, timestamp)
    :ok
  end

  defp allow_lock(peer, key, timestamp) do
    Logger.info("Lock #{inspect(key)} allowed for peer #{peer} at t = #{timestamp}")
    RPC.allow_lock(peer, key, timestamp)
  end

  defp confirm_lock(state) do
    cond do
      # Se ainda faltam nós confirmarem a requisição, mantemos o estado de espera.
      MapSet.size(state.waiting) != 0 ->
        state

      # Se não, podemos cancelar o timeout; caso o cancelamento falhe, consideramos que o
      # tempo limite foi excedido, e limpamos o estado.
      !Process.cancel_timer(state.internal.timeout_ref) ->
        State.reset(state)

      # Caso contrário, confirmamos a aquisição do mutex ao processo que o pediu e atualizamos o
      # estado indicando que o nó atual está na seção crítica.
      true ->
        GenServer.reply(state.internal.requester, :ok)
        State.lock_acquired(state)
    end
  end
end
