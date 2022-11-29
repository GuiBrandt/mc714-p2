defmodule MC714.P2.Consensus do
  @moduledoc """
  Módulo de consenso distribuído.
  """

  def decrees(), do: MC714.P2.Consensus.StateMachine.get_decrees()

  def acceptors(), do: MC714.P2.Consensus.StateMachine.get_acceptors()

  def request(value), do: GenServer.call(MC714.P2.Consensus, {:request, value}, :infinity)

  def become_acceptor(), do: GenServer.call(MC714.P2.Consensus, :become_acceptor, :infinity)

  def disconnect(), do: GenServer.call(MC714.P2.Consensus, :disconnect, :infinity)
end
