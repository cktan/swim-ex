defmodule SwimEx do
  @moduledoc """
  SWIM+INF+Susp cluster membership protocol.

  ## Quick start

      children = [
        {SwimEx.Supervisor, host: "10.0.0.1", port: 7771,
                            seeds: [{"10.0.0.2", 7771}]}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      SwimEx.subscribe()
      SwimEx.members()

  ## Membership events

  After calling `subscribe/1`, the calling process receives
  messages of the form:

      {:swim, event, node_id}

  where `event` is one of:

    * `:node_up` — a node became (or was confirmed) alive
    * `:node_suspect` — a node is suspected dead
    * `:node_down` — a node is confirmed dead

  and `node_id` is `{host, port, cookie}`.
  """

  @default_name :swim

  @doc """
  Returns current cluster members (alive + suspect by default).

  ## Parameters
    - `name`: (optional) The registered name of the SwimEx instance. Defaults to `:swim`.
    - `opts`: (optional) A keyword list of options.
      - `:include_dead`: Boolean. If true, includes nodes marked as dead. Defaults to `false`.

  ## Returns
    - A list of members, where each member is a tuple: `{host, port, cookie, status, incarnation}`.
  """
  @spec members(atom(), keyword()) :: [{String.t(), :inet.port_number(), String.t(), SwimEx.Membership.status(), non_neg_integer()}]
  def members(name \\ @default_name, opts \\ []) do
    SwimEx.Protocol.members(name, opts)
  end

  @doc """
  Subscribes the calling process to membership events.

  The caller receives messages of the form
  `{:swim, event, node_id}` where `event` is
  `:node_up`, `:node_suspect`, or `:node_down`, and
  `node_id` is `{host, port, cookie}`. See the module
  doc for details.

  ## Parameters
    - `name`: (optional) The registered name of the
      SwimEx instance. Defaults to `:swim`.

  ## Returns
    - `:ok`
  """
  @spec subscribe(atom()) :: :ok
  def subscribe(name \\ @default_name) do
    SwimEx.Protocol.subscribe(name, self())
  end

  @doc """
  Unsubscribes the calling process from membership events.

  ## Parameters
    - `name`: (optional) The registered name of the SwimEx instance. Defaults to `:swim`.

  ## Returns
    - `:ok`
  """
  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(name \\ @default_name) do
    SwimEx.Protocol.unsubscribe(name, self())
  end

  @doc """
  Broadcasts a "dead" status for the local node, then stops the
  Protocol process.

  Call this before stopping the application for a graceful
  shutdown that immediately informs peers. The supervisor will
  restart the process afterward; stop the application (or the
  SwimEx supervisor) separately to prevent the restart.

  ## Parameters
    - `name`: (optional) The registered name of the SwimEx
      instance. Defaults to `:swim`.

  ## Returns
    - `:ok`
  """
  @spec leave(atom()) :: :ok
  def leave(name \\ @default_name) do
    SwimEx.Protocol.leave(name)
  end

  @doc """
  Records out-of-band evidence that `peer` is alive.

  Use this when the application has direct, first-hand
  proof that a peer is reachable — for example a
  successful HTTP request received from it — that the
  SWIM failure detector may not have observed. SWIM
  probes run over UDP; this lets a successful exchange
  over another channel (e.g. TCP) count as liveness
  evidence and suppress false-positive suspicion.

  The hint is asynchronous and advisory, applied to the
  local view only:

    * If `peer` is currently suspected, its suspicion
      timer is cancelled and an `alive` event is
      re-disseminated, so this node will not declare
      `peer` dead.
    * If `peer` is already alive, the call is a no-op.
    * A dead `peer` is **not** revived — that requires a
      higher incarnation from the peer itself.

  It cannot override a same-incarnation suspicion already
  circulating elsewhere in the cluster; only the peer's
  own self-refutation is authoritative cluster-wide.

  ## Parameters
    - `name`: (optional) The registered name of the
      SwimEx instance. Defaults to `:swim`.
    - `peer`: The `{host, port, cookie}` of the peer
      known to be alive.

  ## Returns
    - `:ok`
  """
  @spec hint_alive(atom(), SwimEx.Membership.node_id()) :: :ok
  def hint_alive(name \\ @default_name, peer) do
    SwimEx.Protocol.hint_alive(name, peer)
  end
end
