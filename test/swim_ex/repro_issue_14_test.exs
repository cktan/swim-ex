defmodule SwimEx.ReproIssue14Test do
  use ExUnit.Case

  alias SwimEx.Transport.InMemory
  alias SwimEx.Transport.InMemory.Network

  @t 50
  @ping_timeout 20

  defp start_node(net, host, port, opts \\ []) do
    transport_name = :"transport_#{host}_#{port}"
    node_name = :"node_#{host}_#{port}"

    {:ok, _t} =
      InMemory.start_link(
        network: net,
        identity: {host, port, ""},
        name: transport_name
      )

    {:ok, _p} =
      SwimEx.Protocol.start_link(
        Keyword.merge(
          [
            host: host,
            port: port,
            name: node_name,
            transport: transport_name,
            transport_mod: InMemory,
            protocol_period: @t,
            ping_timeout: @ping_timeout,
            ping_req_fanout: 3,
            suspicion_timeout: @t * 3,
            seed_retry_interval: @t * 5,
            dead_node_expiry: @t * 6
          ],
          opts
        )
      )

    {transport_name, node_name}
  end

  setup do
    {:ok, net} = Network.start_link()
    %{net: net}
  end

  test "ping_req pending entries are cleaned up on timeout", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7001)
    n1_pid = GenServer.whereis(n1)

    _n1_id = {"n1", 7001, ""}
    other_node = {"other", 7001, ""}
    target_node = {"target", 7001, ""}

    # Send a ping_req to n1. n1 will try to ping target_node.
    seq = 1
    {:ok, data} = SwimEx.Codec.encode({:ping_req, other_node, seq, target_node, []})
    send(n1_pid, {:swim_packet, other_node, data})

    # Get state to find the relay_seq
    state = :sys.get_state(n1_pid)
    assert map_size(state.pending) == 1
    {relay_seq, {^target_node, _ref, {:relay_to, ^other_node, ^seq}}} = Enum.at(state.pending, 0)

    # Wait for ping_timeout to expire
    Process.sleep(@ping_timeout + 20)

    # Check state again
    state = :sys.get_state(n1_pid)
    assert Map.get(state.pending, relay_seq) == nil, "Pending entry for relay_seq #{relay_seq} should have been cleaned up"
  end

  test "ping_times are cleaned up on indirect timeout", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7002)
    n1_pid = GenServer.whereis(n1)

    # Add another node to the cluster so we have someone to ping
    target_node = {"target", 7002, ""}
    state = :sys.get_state(n1_pid)
    membership = SwimEx.Membership.add(state.membership, target_node, 0)
    :sys.replace_state(n1_pid, fn s -> %{s | membership: membership} end)

    # Trigger a protocol period to start a ping
    send(n1_pid, :protocol_period)

    # Wait for the ping to be sent and timeout to indirect
    Process.sleep(@ping_timeout + 20)

    # Now it should be in indirect state
    state = :sys.get_state(n1_pid)
    assert map_size(state.pending) == 1
    {seq, {^target_node, _ref, :indirect}} = Enum.at(state.pending, 0)
    assert Map.has_key?(state.ping_times, seq)

    # Wait for indirect timeout to expire
    Process.sleep(@ping_timeout + 20)

    # Check state again
    state = :sys.get_state(n1_pid)
    assert Map.get(state.pending, seq) == nil
    assert Map.get(state.ping_times, seq) == nil, "ping_times for seq #{seq} should have been cleaned up"
  end
end
