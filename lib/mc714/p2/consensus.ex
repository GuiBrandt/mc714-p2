defmodule MC714.P2.Consensus do
  @moduledoc """
  Módulo de consenso distribuído.
  """

  def decrees(), do: MC714.P2.Consensus.Manager.StateMachine.get_decrees()

  def acceptors(), do: MC714.P2.Consensus.Manager.StateMachine.get_acceptors()

  def request(value), do: GenServer.call(MC714.P2.Consensus, {:request, value})

  def become_acceptor(), do: GenServer.call(MC714.P2.Consensus, :become_acceptor)

  def disconnect(), do: GenServer.call(MC714.P2.Consensus, :disconnect)
end
