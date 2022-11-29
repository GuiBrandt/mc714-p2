defmodule MC714.P2.Mutex do
  @moduledoc """
  Módulo de exclusão mútua distribuída.
  """

  @type lock_failure_reason :: :already_locking | :timeout
  @type on_lock :: :ok | {:failed, lock_failure_reason}

  @type release_failure_reason :: :not_locked
  @type on_release :: :ok | {:failed, release_failure_reason}

  @doc """
  Pede acesso à seção crítica, usando a trava `mutex` (por padrão, `MC714.P2.Mutex`)
  com timeout de `timeout` milissegundos (por padrão, 5000ms).

  Retorna `:ok` em caso de sucesso ou `{:failed, <motivo>}` em caso de falha.

  O motivo de falha pode ser:
  - `:already_locking`: outro processo neste nó já pediu ou tem acesso à seção crítica.
  - `:timeout`: A requisição expirou antes que o acesso à seção crítica pudesse ser obtido.
  """
  @spec lock(term) :: on_lock
  @spec lock(term, pos_integer | :infinity) :: on_lock
  def lock(key, timeout \\ :infinity),
    do: GenServer.call(MC714.P2.Mutex, {key, {:lock, timeout}}, :infinity)

  @doc """
  Sinaliza o fim da seção crítica, usando a trava `mutex` (por padrão, `MC714.P2.Mutex`).

  Retorna `:ok` em caso de sucesso ou `{:failed, <motivo>}` em caso de falha.

  O motivo de falha pode ser:
  - `:not_locked`: o nó não está na seção crítica.
  """
  @spec release(term) :: on_release
  def release(key), do: GenServer.call(MC714.P2.Mutex, {key, :release})
end
