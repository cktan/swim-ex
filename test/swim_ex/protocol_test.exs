defmodule SwimEx.ProtocolTest do
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

  test "single node starts with empty membership", %{net: net} do
    {_t, name} = start_node(net, "n1", 7001)
    assert SwimEx.Protocol.members(name, []) == []
  end

  test "two nodes discover each other via seed", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7001)
    {_t2, n2} = start_node(net, "n2", 7001, seeds: [{"n1", 7001}])

    # Wait for a few protocol periods for convergence
    Process.sleep(@t * 8)

    members1 = SwimEx.Protocol.members(n1, include_dead: false)
    members2 = SwimEx.Protocol.members(n2, include_dead: false)

    assert Enum.any?(members1, fn {h, p, _, _, _} -> h == "n2" and p == 7001 end),
           "n1 should know about n2, got: #{inspect(members1)}"

    assert Enum.any?(members2, fn {h, p, _, _, _} -> h == "n1" and p == 7001 end),
           "n2 should know about n1, got: #{inspect(members2)}"
  end

  test "subscriber receives node_up event when node joins", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7002)
    SwimEx.Protocol.subscribe(n1, self())

    {_t2, _n2} = start_node(net, "n2", 7002, seeds: [{"n1", 7002}])

    assert_receive {:swim, :node_up, {"n2", 7002, ""}}, @t * 10
  end

  test "node_suspect event fired when peer stops responding", %{net: net} do
    {t2, _} = start_node(net, "n1", 7003)
    {_t1, n1} = start_node(net, "n2", 7003, seeds: [{"n1", 7003}])

    Process.sleep(@t * 6)
    SwimEx.Protocol.subscribe(n1, self())

    # Cut n1's outbound traffic by setting 100% loss
    InMemory.set_fault(t2, packet_loss: 1.0)

    assert_receive {:swim, :node_suspect, {"n1", 7003, ""}}, @t * 10
  end

  test "node declared dead after suspicion timeout", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7004)
    {t2, _n2} = start_node(net, "n2", 7004, seeds: [{"n1", 7004}])

    Process.sleep(@t * 6)
    SwimEx.Protocol.subscribe(n1, self())

    # Make n2 disappear completely
    InMemory.set_fault(t2, packet_loss: 1.0)

    assert_receive {:swim, :node_suspect, {"n2", 7004, ""}}, @t * 10
    assert_receive {:swim, :node_down, {"n2", 7004, ""}}, @t * 15
  end

  test "members/2 returns alive and suspect, filters dead by default", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7005)
    {t2, _n2} = start_node(net, "n2", 7005, seeds: [{"n1", 7005}])

    Process.sleep(@t * 6)

    SwimEx.Protocol.subscribe(n1, self())
    InMemory.set_fault(t2, packet_loss: 1.0)

    # Wait for dead event, then check immediately before GC runs
    assert_receive {:swim, :node_down, {"n2", 7005, ""}}, @t * 15

    all = SwimEx.Protocol.members(n1, include_dead: true)
    alive_only = SwimEx.Protocol.members(n1, include_dead: false)

    assert Enum.any?(all, fn {h, p, _, s, _} -> h == "n2" and p == 7005 and s == :dead end),
           "n2 should be dead in full list, got: #{inspect(all)}"

    refute Enum.any?(alive_only, fn {h, p, _, _, _} -> h == "n2" and p == 7005 end),
           "n2 should not appear in alive-only list, got: #{inspect(alive_only)}"
  end

  test "subscribe and unsubscribe work", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7006)

    SwimEx.Protocol.subscribe(n1, self())
    SwimEx.Protocol.unsubscribe(n1, self())

    {_t2, _n2} = start_node(net, "n2", 7006, seeds: [{"n1", 7006}])
    Process.sleep(@t * 6)

    refute_receive {:swim, _, _}, 50
  end

  test "leave/1 notifies all peers, not just fanout subset", %{net: net} do
    # 5-node cluster; with the old code only ping_req_fanout (3) nodes get
    # the dead announcement, so 1–2 peers would miss the graceful leave.
    {_t1, n1} = start_node(net, "n1", 8002)
    peers =
      for i <- 2..5 do
        {_t, n} = start_node(net, "n#{i}", 8002, seeds: [{"n1", 8002}])
        n
      end

    Process.sleep(@t * 10)

    # Confirm all peers know n1
    for n <- peers do
      assert Enum.any?(SwimEx.Protocol.members(n, []), fn {h, _, _, _, _} -> h == "n1" end),
             "#{n} should know n1 before leave"
    end

    # Subscribe all peers before leave
    for n <- peers, do: SwimEx.Protocol.subscribe(n, self())

    SwimEx.Protocol.leave(n1)

    # Tight window: far shorter than one protocol period (@t=50ms) so
    # gossip from the 3 directly-notified peers cannot reach a 4th peer
    # in time.  If n1 only broadcasts to ping_req_fanout (3) nodes, the
    # 4th misses the announcement and the assertion times out.
    for _n <- peers do
      assert_receive {:swim, :node_down, {"n1", 8002, ""}}, 5
    end
  end

  test "relay sends fwd_ack with target id as source, not relay id", %{net: net} do
    n1_id = {"n1", 8001, ""}
    n2_id = {"n2", 8001, ""}

    # n1: bare transport so test process receives swim_packets directly
    n1_transport = :transport_n1_8001
    {:ok, _} = InMemory.start_link(network: net, identity: n1_id, name: n1_transport)
    InMemory.set_receiver(n1_transport, self())

    # n2: real protocol node (probe target)
    {_t2, _} = start_node(net, "n2", 8001)

    # n3: real protocol node (relay)
    {_t3, n3_node} = start_node(net, "n3", 8001)
    Process.sleep(@ping_timeout)

    # Ask n3 to relay a ping to n2 on behalf of n1
    seq = 42
    {:ok, req_data} = SwimEx.Codec.encode({:ping_req, n1_id, seq, n2_id, []})
    send(GenServer.whereis(n3_node), {:swim_packet, n1_id, req_data})

    # Wait for fwd_ack to arrive at n1 transport
    assert_receive {:swim_packet, _from, raw}, @t * 4

    {:ok, {:fwd_ack, _relay, _recv_seq, source, _events}} = SwimEx.Codec.decode(raw)
    assert source == n2_id,
           "fwd_ack source should be target #{inspect(n2_id)}, got #{inspect(source)}"
  end

  test "leave/1 removes node from peers' membership", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7007)
    {_t2, n2} = start_node(net, "n2", 7007, seeds: [{"n1", 7007}])

    Process.sleep(@t * 6)

    assert Enum.any?(SwimEx.Protocol.members(n2, include_dead: false), fn {h, _, _, _, _} ->
             h == "n1"
           end)

    SwimEx.Protocol.leave(n1)
    Process.sleep(@t * 4)

    members = SwimEx.Protocol.members(n2, include_dead: false)

    refute Enum.any?(members, fn {h, _, _, _, _} -> h == "n1" end),
           "n1 should have left, got: #{inspect(members)}"
  end

  test "node refutes dead event about itself", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 9001)
    n1_id = {"n1", 9001, ""}

    # n2: mock node to receive the refutation
    n2_id = {"n2", 9001, ""}
    n2_transport = :transport_n2_9001
    {:ok, _} = InMemory.start_link(network: net, identity: n2_id, name: n2_transport)
    InMemory.set_receiver(n2_transport, self())

    # Ensure n1 knows n2 so it has someone to gossip to
    {:ok, ping_from_n2} = SwimEx.Codec.encode({:ping, n2_id, 1, []})
    send(GenServer.whereis(n1), {:swim_packet, n2_id, ping_from_n2})
    assert_receive {:swim_packet, ^n1_id, _}, 100

    # Get n1's current incarnation
    # We can't easily get it from the outside without a subscription or query
    # but we can just send a dead event with a very high incarnation to be sure.
    high_inc = System.system_time(:millisecond) + 1000
    {:ok, dead_msg} = SwimEx.Codec.encode({:ping, n2_id, 2, [{:dead, n1_id, high_inc}]})
    send(GenServer.whereis(n1), {:swim_packet, n2_id, dead_msg})
    # drain ack for seq 2
    assert_receive {:swim_packet, ^n1_id, _}, 100

    # n1 should refute by sending an alive event with high_inc + 1
    # It will send it in its next ping or ack.
    # To speed it up, we can send another ping from n2 and wait for the ack.
    {:ok, ping2} = SwimEx.Codec.encode({:ping, n2_id, 3, []})
    send(GenServer.whereis(n1), {:swim_packet, n2_id, ping2})

    expected_inc = high_inc + 1
    assert_receive {:swim_packet, ^n1_id, raw}, @t * 2
    {:ok, {:ack, ^n1_id, 3, events}} = SwimEx.Codec.decode(raw)

    assert Enum.any?(events, fn
             {:alive, id, inc} -> id == n1_id and inc == expected_inc
             _ -> false
           end)
  end

  test "alive gossip for GC'd node gets refutation multiplier", %{net: net} do
    {_t, name} = start_node(net, "n1", 9010)
    pid = GenServer.whereis(name)

    ghost = {"ghost", 9010, ""}
    peer = {"peer", 9010, ""}

    {:ok, data} = SwimEx.Codec.encode({:ack, peer, 0, [{:alive, ghost, 1}]})
    send(pid, {:swim_packet, peer, data})

    # flush the message before reading state
    :sys.get_state(pid)

    state = :sys.get_state(pid)
    entry = Enum.find(state.gossip_queue.entries, fn e -> elem(e.event, 1) == ghost end)

    assert entry != nil, "alive event for unknown node should be queued"
    assert entry.multiplier == 2, "expected refutation multiplier, got #{inspect(entry)}"
  end
end
