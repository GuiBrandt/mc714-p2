defmodule MC714.P2.Application do
  use Application

  @env Mix.env()

  @impl Application
  def start(_type, _args) do
    children = [
      MC714.P2.Mutex.Manager,
      {MC714.P2.Consensus.Manager, request_timeout: 2_000},
      {Plug.Cowboy, scheme: :http, plug: MC714.P2.HttpServer, options: [port: 8080]}
    ]

    children =
      if prod() do
        [cluster_supervisor() | children]
      else
        children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: MC714.P2.Supervisor)
  end

  @impl Application
  def prep_stop(state) do
    paxos_config = Application.fetch_env!(:mc714_p2, :paxos)
    node = paxos_config[:node]
    root = paxos_config[:root]
    if node != root, do: :ok = MC714.P2.Consensus.disconnect()
    MC714.P2.Consensus.StateMachine.commit()
    state
  end

  defp prod, do: @env == :prod

  defp cluster_supervisor do
    topologies = Application.get_env(:libcluster, :topologies)
    {Cluster.Supervisor, [topologies, [name: MC714.P2.ClusterSupervisor]]}
  end
end
