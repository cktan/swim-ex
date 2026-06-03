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

  Events will be sent as messages to the calling process.

  ## Parameters
    - `name`: (optional) The registered name of the SwimEx instance. Defaults to `:swim`.

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
end
