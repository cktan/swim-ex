defmodule SwimEx.DisseminationTest do
  use ExUnit.Case

  alias SwimEx.Transport.InMemory
  alias SwimEx.Transport.InMemory.Network
  alias SwimEx.Codec

  @t 50
  @ping_timeout 20

  setup do
    {:ok, net} = Network.start_link()
    %{net: net}
  end

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

  test "relay ping carries gossip events", %{net: net} do
    n1_id = {"n1", 9001, ""}
    n2_id = {"n2", 9001, ""}
    n3_id = {"n3", 9001, ""}

    # n1: mock node (original sender)
    n1_transport = :transport_n1_9001
    {:ok, _} = InMemory.start_link(network: net, identity: n1_id, name: n1_transport)
    InMemory.set_receiver(n1_transport, self())

    # n3: real protocol node (relay)
    {_t3, n3_node} = start_node(net, "n3", 9001)

    # n2: mock node (probe target)
    n2_transport = :transport_n2_9001
    {:ok, _} = InMemory.start_link(network: net, identity: n2_id, name: n2_transport)
    InMemory.set_receiver(n2_transport, self())

    # Give n3 some gossip to spread (e.g. an alive event)
    # We can do this by sending a ping with gossip to n3
    event = {:alive, {"other", 1111, ""}, 100}
    {:ok, ping_data} = Codec.encode({:ping, n1_id, 1, [event]})
    send(GenServer.whereis(n3_node), {:swim_packet, n1_id, ping_data})

    # Wait for n3 to apply gossip (it will also send an ack back to n1)
    assert_receive {:swim_packet, ^n3_id, _}, 100

    # Ask n3 to relay a ping to n2
    seq = 42
    {:ok, req_data} = Codec.encode({:ping_req, n1_id, seq, n2_id, []})
    send(GenServer.whereis(n3_node), {:swim_packet, n1_id, req_data})

    # n2 should receive a ping from n3, and it should carry the event
    assert_receive {:swim_packet, ^n3_id, raw}, @ping_timeout * 2
    {:ok, {:ping, ^n3_id, _relay_seq, events}} = Codec.decode(raw)

    assert event in events, "Relay ping should carry gossip event"
  end

  test "fwd_ack carries gossip events", %{net: net} do
    n1_id = {"n1", 9002, ""}
    n2_id = {"n2", 9002, ""}
    n3_id = {"n3", 9002, ""}

    # n1: mock node (original sender)
    n1_transport = :transport_n1_9002
    {:ok, _} = InMemory.start_link(network: net, identity: n1_id, name: n1_transport)
    InMemory.set_receiver(n1_transport, self())

    # n3: real protocol node (relay)
    {_t3, n3_node} = start_node(net, "n3", 9002)

    # n2: mock node (probe target)
    n2_transport = :transport_n2_9002
    {:ok, _} = InMemory.start_link(network: net, identity: n2_id, name: n2_transport)
    InMemory.set_receiver(n2_transport, self())

    # Give n3 some gossip to spread
    event = {:alive, {"other", 2222, ""}, 200}
    {:ok, ping_data} = Codec.encode({:ping, n1_id, 1, [event]})
    send(GenServer.whereis(n3_node), {:swim_packet, n1_id, ping_data})

    # Wait for n3 to apply gossip (it will also send an ack back to n1)
    assert_receive {:swim_packet, ^n3_id, _}, 100

    # Ask n3 to relay a ping to n2
    seq = 42
    {:ok, req_data} = Codec.encode({:ping_req, n1_id, seq, n2_id, []})
    send(GenServer.whereis(n3_node), {:swim_packet, n1_id, req_data})

    # n2 receives relay ping
    assert_receive {:swim_packet, ^n3_id, relay_ping_raw}, @ping_timeout * 2
    {:ok, {:ping, ^n3_id, relay_seq, _}} = Codec.decode(relay_ping_raw)

    # n2 acks back to n3
    {:ok, ack_data} = Codec.encode({:ack, n2_id, relay_seq, []})
    send(GenServer.whereis(n3_node), {:swim_packet, n2_id, ack_data})

    # n1 should receive fwd_ack from n3, and it should carry the event
    assert_receive {:swim_packet, ^n3_id, fwd_ack_raw}, @ping_timeout * 2
    {:ok, {:fwd_ack, ^n3_id, ^seq, ^n2_id, events}} = Codec.decode(fwd_ack_raw)

    assert event in events, "fwd_ack should carry gossip event"
  end
end
