defmodule SwimEx.Transport.UDP do
  @moduledoc """
  UDP transport using a single dual-stack (IPv4+IPv6) socket.

  Opens an `:inet6` socket with `ipv6_v6only: false` so it accepts
  both IPv4 and IPv6 traffic on one port. On Linux this is the
  default; on platforms where dual-stack is unavailable the socket
  falls back to IPv4-only.
  """

  use GenServer
  @behaviour SwimEx.Transport

  defstruct [:socket, :receiver]

  # --- Public API ---

  @impl SwimEx.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:transport_name])
  end

  @impl SwimEx.Transport
  def send(server, {host, port}, data) when is_binary(data) do
    case resolve(host) do
      {:ok, ip} ->
        GenServer.cast(server, {:send, ip, port, data})
        :ok

      {:error, _} = err ->
        err
    end
  end

  @impl SwimEx.Transport
  def set_receiver(server, pid) do
    GenServer.call(server, {:set_receiver, pid})
  end

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
  def handle_cast({:send, ip, port, data}, state) do
    _ = :gen_udp.send(state.socket, ip, port, data)
    {:noreply, state}
  end

  def handle_call({:set_receiver, pid}, _from, state) do
    {:reply, :ok, %{state | receiver: pid}}
  end

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

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Helpers ---

  defp resolve(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        case :inet.getaddr(charlist, :inet6) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> :inet.getaddr(charlist, :inet)
        end
    end
  end

  defp ip_to_string(ip) do
    ip |> :inet.ntoa() |> List.to_string()
  end
end
