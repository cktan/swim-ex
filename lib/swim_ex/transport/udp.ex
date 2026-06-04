defmodule SwimEx.Transport.UDP do
  @moduledoc """
  UDP transport using a single dual-stack (IPv4+IPv6) socket.

  Opens an `:inet6` socket with `ipv6_v6only: false` so it accepts
  both IPv4 and IPv6 traffic on one port. On Linux this is the
  default; on platforms where dual-stack is unavailable the socket
  falls back to IPv4-only.
  """

  use GenServer
  require Logger
  @behaviour SwimEx.Transport

  defstruct [:socket, :receiver]

  # --- Public API ---

  @doc """
  Starts the UDP transport.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  @impl SwimEx.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:transport_name])
  end

  @doc """
  Sends data to a node.
  """
  @spec send(GenServer.server(), SwimEx.Transport.node_id(), binary()) :: :ok
  @impl SwimEx.Transport
  def send(server, {host, port}, data) when is_binary(data) do
    GenServer.cast(server, {:send, host, port, data})
    :ok
  end

  @doc """
  Sets the receiver process for incoming SWIM packets.
  """
  @spec set_receiver(GenServer.server(), pid()) :: :ok
  @impl SwimEx.Transport
  def set_receiver(server, pid) do
    GenServer.call(server, {:set_receiver, pid})
  end

  @doc """
  Closes the transport socket.
  """
  @spec close(GenServer.server()) :: :ok
  @impl SwimEx.Transport
  def close(server) do
    GenServer.call(server, :close)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    socket_opts = [
      :binary,
      {:active, true},
      :inet6,
      {:ipv6_v6only, false}
    ]

    case :gen_udp.open(port, socket_opts) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket, receiver: nil}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:send, host, port, data}, state) do
    case resolve(host) do
      {:ok, ip} ->
        _ = :gen_udp.send(state.socket, ip, port, data)

      {:error, reason} ->
        Logger.warning("failed to resolve host: #{inspect(host)} (reason: #{inspect(reason)})")
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:set_receiver, pid}, _from, state) do
    {:reply, :ok, %{state | receiver: pid}}
  end

  @impl GenServer
  def handle_call(:close, _from, state) do
    :gen_udp.close(state.socket)
    {:reply, :ok, %{state | socket: nil}}
  end

  @impl GenServer
  def handle_info({:udp, _socket, ip, port, data}, state) do
    if state.receiver do
      host = ip_to_string(ip)
      Kernel.send(state.receiver, {:swim_packet, {host, port}, data})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{socket: socket}) when not is_nil(socket) do
    :gen_udp.close(socket)
  end

  def terminate(_reason, _state), do: :ok

  # --- Helpers ---

  defp resolve(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, {a, b, c, d}} ->
        # Convert IPv4 to IPv4-mapped IPv6 for the inet6 socket.
        {:ok, {0, 0, 0, 0, 0, 0xFFFF, a * 256 + b, c * 256 + d}}

      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        case :inet.getaddr(charlist, :inet6) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> :inet.getaddr(charlist, :inet)
        end
    end
  end

  defp ip_to_string({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    "#{div(ab, 256)}.#{rem(ab, 256)}.#{div(cd, 256)}.#{rem(cd, 256)}"
  end

  defp ip_to_string(ip) do
    ip |> :inet.ntoa() |> List.to_string()
  end
end
