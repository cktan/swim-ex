defmodule SwimEx.Transport do
  @moduledoc """
  Behaviour for SWIM transport implementations.

  Implementations must deliver received packets to the registered
  receiver as `{:swim_packet, from :: {String.t(), port}, binary}`.
  """

  @type node_id :: {String.t(), :inet.port_number()}
  @type server :: GenServer.server()

  @doc """
  Strips the cookie from a 3-element identity tuple, returning a 2-element transport address.
  """
  @spec strip_cookie({String.t(), :inet.port_number(), String.t()} | node_id()) :: node_id()
  def strip_cookie({host, port, _cookie}), do: {host, port}
  def strip_cookie({host, port}), do: {host, port}

  @doc "Start the transport, binding to the given port."
  @callback start_link(keyword()) :: GenServer.on_start()

  @doc "Send a binary payload to the given node."
  @callback send(server(), node_id(), binary()) :: :ok | {:error, term()}

  @doc "Register the process that will receive incoming packets."
  @callback set_receiver(server(), pid()) :: :ok

  @doc "Close the transport."
  @callback close(server()) :: :ok
end
