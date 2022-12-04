defmodule MC714.P2.Consensus do
  @moduledoc """
  Módulo de consenso distribuído.
  """

  @spec decrees :: {pos_integer, [term]}
  def decrees(), do: MC714.P2.Consensus.StateMachine.get_decrees()

  @spec acceptors :: {pos_integer, [String.t()]}
  def acceptors(), do: MC714.P2.Consensus.StateMachine.get_acceptors()

  @spec request(term) :: pos_integer
  def request(value), do: GenServer.call(MC714.P2.Consensus, {:request, value}, :infinity)

  @spec sync() :: pos_integer
  def sync(), do: GenServer.call(MC714.P2.Consensus, :sync, :infinity)

  @spec become_acceptor() :: pos_integer | :noop
  def become_acceptor(), do: GenServer.call(MC714.P2.Consensus, :become_acceptor, :infinity)

  @spec disconnect() :: pos_integer | :noop
  def disconnect(), do: GenServer.call(MC714.P2.Consensus, :disconnect, :infinity)
end
