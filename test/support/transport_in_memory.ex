defmodule SwimEx.Transport.InMemory do
  @moduledoc """
  In-memory transport for testing. Registered transports can send
  to each other by name ({host, port} identity).

  Supports fault injection per transport instance:
    - `packet_loss`: float 0.0–1.0, probability of dropping a packet
    - `delay_ms`: integer, fixed delivery delay in milliseconds
    - `reorder`: boolean, randomly reorder packets within a window

  Usage in tests:

      {:ok, net} = SwimEx.Transport.InMemory.Network.start_link()
      {:ok, t1} = SwimEx.Transport.InMemory.start_link(
        network: net, identity: {"node1", 7771}
      )
      {:ok, t2} = SwimEx.Transport.InMemory.start_link(
        network: net, identity: {"node2", 7771}
      )
      SwimEx.Transport.InMemory.set_receiver(t1, self())
      SwimEx.Transport.InMemory.send(t1, {"node2", 7771}, <<"hello">>)
  """

  use GenServer
  @behaviour SwimEx.Transport

  defstruct [:network, :identity, :receiver, :packet_loss, :delay_ms, :reorder]

  # --- Public API ---

  @impl SwimEx.Transport
  def start_link(opts) do
    gen_opts = case Keyword.fetch(opts, :name) do
      {:ok, name} -> [name: name]
      :error -> []
    end
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl SwimEx.Transport
  def send(server, {_, _, _} = to, data) when is_binary(data) do
    GenServer.cast(server, {:send, to, data})
  end

  @impl SwimEx.Transport
  def send(server, to, data) when is_binary(data) do
    GenServer.cast(server, {:send, to, data})
  end

  @impl SwimEx.Transport
  def set_receiver(server, pid) do
    GenServer.call(server, {:set_receiver, pid})
  end

  @impl SwimEx.Transport
  def close(server) do
    GenServer.call(server, :close)
  end

  def set_fault(server, opts) do
    GenServer.call(server, {:set_fault, opts})
  end

  # Called by the Network to deliver an inbound packet.
  def deliver(server, from, data) do
    GenServer.cast(server, {:deliver, from, data})
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    network = Keyword.fetch!(opts, :network)
    identity = Keyword.fetch!(opts, :identity)
    SwimEx.Transport.InMemory.Network.register(network, identity, self())

    state = %__MODULE__{
      network: network,
      identity: identity,
      receiver: nil,
      packet_loss: Keyword.get(opts, :packet_loss, 0.0),
      delay_ms: Keyword.get(opts, :delay_ms, 0),
      reorder: Keyword.get(opts, :reorder, false)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:set_receiver, pid}, _from, state) do
    {:reply, :ok, %{state | receiver: pid}}
  end

  def handle_call({:set_fault, opts}, _from, state) do
    state =
      state
      |> maybe_put(:packet_loss, opts[:packet_loss])
      |> maybe_put(:delay_ms, opts[:delay_ms])
      |> maybe_put(:reorder, opts[:reorder])

    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    SwimEx.Transport.InMemory.Network.unregister(state.network, state.identity)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:send, to, data}, state) do
    unless drop?(state.packet_loss) do
      deliver_fn = fn ->
        SwimEx.Transport.InMemory.Network.route(state.network, state.identity, to, data)
      end

      if state.delay_ms > 0 do
        Process.send_after(self(), {:delayed_send, deliver_fn}, state.delay_ms)
      else
        deliver_fn.()
      end
    end

    {:noreply, state}
  end

  def handle_cast({:deliver, from, data}, state) do
    if state.receiver do
      Kernel.send(state.receiver, {:swim_packet, from, data})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:delayed_send, deliver_fn}, state) do
    deliver_fn.()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Helpers ---

  defp drop?(rate) when rate <= 0.0, do: false
  defp drop?(rate), do: :rand.uniform() < rate

  defp maybe_put(state, _key, nil), do: state
  defp maybe_put(state, key, val), do: Map.put(state, key, val)
end

defmodule SwimEx.Transport.InMemory.Network do
  @moduledoc "Registry and routing hub for InMemory transports."

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def register(network, identity, pid) do
    GenServer.call(network, {:register, identity, pid})
  end

  def unregister(network, identity) do
    GenServer.call(network, {:unregister, identity})
  end

  def route(network, from, to, data) do
    GenServer.cast(network, {:route, from, to, data})
  end

  @doc """
  Sets a partition between two sets of node hosts.
  `groups` is a list of lists of host strings.
  Communication is only allowed WITHIN each group.
  Communication BETWEEN groups is dropped.
  """
  def set_partitions(network, groups) do
    GenServer.call(network, {:set_partitions, groups})
  end

  def clear_partitions(network) do
    GenServer.call(network, :clear_partitions)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{registry: %{}, partitions: nil}}

  @impl GenServer
  def handle_call({:register, identity, pid}, _from, state) do
    {:reply, :ok, %{state | registry: Map.put(state.registry, identity, pid)}}
  end

  def handle_call({:unregister, identity}, _from, state) do
    {:reply, :ok, %{state | registry: Map.delete(state.registry, identity)}}
  end

  def handle_call({:set_partitions, groups}, _from, state) do
    # Create a map: host -> group_index
    map = for {group, idx} <- Enum.with_index(groups),
              host <- group,
              into: %{},
              do: {host, idx}
    {:reply, :ok, %{state | partitions: map}}
  end

  def handle_call(:clear_partitions, _from, state) do
    {:reply, :ok, %{state | partitions: nil}}
  end

  @impl GenServer
  def handle_cast({:route, from, to, data}, state) do
    if allowed?(from, to, state.partitions) do
      case Map.get(state.registry, to) do
        nil -> :ok
        pid -> SwimEx.Transport.InMemory.deliver(pid, from, data)
      end
    end

    {:noreply, state}
  end

  defp allowed?(_from, _to, nil), do: true
  defp allowed?({f_h, _, _}, {t_h, _, _}, partitions), do: allowed_host?(f_h, t_h, partitions)
  defp allowed?({f_h, _}, {t_h, _}, partitions), do: allowed_host?(f_h, t_h, partitions)

  defp allowed_host?(f_h, t_h, partitions) do
    f_group = Map.get(partitions, f_h)
    t_group = Map.get(partitions, t_h)
    f_group == t_group
  end
end
