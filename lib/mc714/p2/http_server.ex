defmodule MC714.P2.HttpServer do
  require Logger
  use Plug.Router

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Poison
  )

  plug(:dispatch)

  def init(options) do
    Logger.info("Server up on #{node()}")
    options
  end

  get "/cluster" do
    status = cluster_status()
    status_code = if status[:peers] == [], do: 503, else: 200

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Poison.encode!(status))
  end

  get "/ledger" do
    conn
    |> honor_consistency()
    |> put_resp_content_type("application/json")
    |> send_resp(200, Poison.encode!(decrees()))
  end

  get "/paxos-acceptors" do
    conn
    |> honor_consistency()
    |> put_resp_content_type("application/json")
    |> send_resp(200, Poison.encode!(paxos_acceptors()))
  end

  post "/decree" do
    case conn.body_params do
      %{"value" => value} ->
        MC714.P2.Consensus.request(value)
        conn |> send_resp(201, "")

      _ ->
        conn |> send_resp(400, "")
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Poison.encode!(not_found()))
  end

  defp honor_consistency(conn) do
    case get_req_header(conn, "x-consistent-read") do
      ["true" | _] -> MC714.P2.Consensus.sync()
      _ -> :ok
    end

    conn
  end

  defp decrees() do
    {seqno, items} = MC714.P2.Consensus.decrees()

    %{
      _seq: seqno,
      decrees: items
    }
  end

  defp paxos_acceptors() do
    {seqno, acceptors} = MC714.P2.Consensus.acceptors()

    %{
      _seq: seqno,
      acceptors: acceptors
    }
  end

  defp cluster_status,
    do: %{
      node: Node.self(),
      peers: Node.list()
    }

  def not_found,
    do: %{
      error: "not_found",
      message: "Route not found"
    }
end
