import Config

config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "mc714-p2-nodes",
        application_name: "mc714_p2",
        polling_interval: 5_000
      ]
    ]
  ]
