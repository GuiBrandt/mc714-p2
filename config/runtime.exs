import Config

config :mc714_p2,
  paxos: [
    node: System.get_env("PAXOS_NODE") || raise("PAXOS_NODE not set"),
    root: System.get_env("PAXOS_ROOT") || raise("PAXOS_ROOT not set")
  ]
