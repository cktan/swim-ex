defmodule SwimEx.Supervisor do
  @moduledoc """
  Top-level supervisor for a SwimEx cluster node.

  Add to your supervision tree:

      children = [
        {SwimEx.Supervisor,
         host: "10.0.0.1",
         port: 7771,
         seeds: [{"10.0.0.2", 7771}]}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

  Options:

    * `:host` — (required) this node's hostname or IP string
    * `:port` — (required) UDP port to bind
    * `:name` — SWIM instance name atom, default `:swim`
    * `:seeds` — list of `{host, port}` seed nodes, default `[]`
    * `:protocol_period` — ms, default 1000
    * `:ping_timeout` — ms, default 200
    * `:ping_req_fanout` — integer, default 3
    * `:suspicion_timeout` — ms, default 3000
    * `:seed_retry_interval` — ms, default 5000
    * `:dead_node_expiry` — ms, default 6000
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, :swim)
    Supervisor.start_link(__MODULE__, opts, name: :"#{name}_supervisor")
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.get(opts, :name, :swim)
    transport_name = :"#{name}_transport"

    children = [
      {SwimEx.Transport.UDP,
       Keyword.merge(opts, transport_name: transport_name, port: Keyword.fetch!(opts, :port))},
      {SwimEx.Protocol,
       Keyword.merge(opts,
         name: name,
         transport: transport_name,
         transport_mod: SwimEx.Transport.UDP
       )}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
