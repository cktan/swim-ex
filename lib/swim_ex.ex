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

  @doc "Returns current cluster members (alive + suspect by default)."
  def members(name \\ @default_name, opts \\ []) do
    SwimEx.Protocol.members(name, opts)
  end

  @doc "Subscribes the calling process to membership events."
  def subscribe(name \\ @default_name) do
    SwimEx.Protocol.subscribe(name, self())
  end

  @doc "Unsubscribes the calling process from membership events."
  def unsubscribe(name \\ @default_name) do
    SwimEx.Protocol.unsubscribe(name, self())
  end

  @doc "Broadcasts dead, then stops the supervisor tree."
  def leave(name \\ @default_name) do
    SwimEx.Protocol.leave(name)
  end
end
