defmodule MC714.P2.LogicClock do
  @moduledoc """
  Módulo de relógio lógico.
  """

  use Agent

  @type t :: Agent.agent()
  @type timestamp_t :: non_neg_integer

  @type options :: [Agent.option() | {:initial, timestamp_t} | {:name, atom}]
  @type on_start :: Agent.on_start()

  @spec start_link(options) :: on_start
  def start_link(opts), do: Agent.start_link(fn -> opts[:initial] || 0 end, opts)

  @doc """
  Obtém o timestamp atual do relógio lógico `clock` (por padrão `MC714.P2.LogicClock`).
  """
  @spec timestamp(t) :: timestamp_t
  def timestamp(clock), do: Agent.get(clock, fn t -> t end)

  @doc """
  Avança o timestamp do relógio lógico `clock` (por padrão `MC714.P2.LogicClock`).

  Retorna o timestamp do relógio antes do avanço.
  """
  @spec tick(t) :: timestamp_t
  def tick(clock), do: coalesce(clock, 0)

  @doc """
  Combina o timestamp do relógio lógico `clock` (por padrão `MC714.P2.LogicClock`) com um
  timestamp recebido de outro nó, e avança o relógio.

  A combinação dos timestamps consiste em comparar o timestamp atual do relógio e o recebido e
  atualizar o relógio com o maior dos dois.

  Retorna o timestamp do relógio antes do avanço, mas após combinado com o timestamp recebido.
  """
  @spec coalesce(t, timestamp_t) :: timestamp_t
  def coalesce(clock, timestamp),
    do: Agent.get_and_update(clock, &combine_and_increment(&1, timestamp))

  defp combine_and_increment(t1, t2) do
    t = max(t1, t2)
    {t, t + 1}
  end
end
