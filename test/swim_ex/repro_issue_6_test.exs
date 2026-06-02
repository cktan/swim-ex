defmodule SwimEx.ReproIssue6Test do
  use ExUnit.Case

  alias SwimEx.Transport.InMemory.Network
  alias SwimEx.Transport.InMemory
  alias SwimEx.Codec

  setup do
    {:ok, net} = Network.start_link()
    {:ok, t1} = InMemory.start_link(network: net, identity: {"n1", 7000})

    {:ok, p1} = SwimEx.Protocol.start_link(
      host: "n1",
      port: 7000,
      transport: t1,
      transport_mod: InMemory,
      protocol_period: 100_000, # pause regular pinging
      suspicion_timeout: 100
    )

    %{p1: p1, t1: t1}
  end

  test "next_probe_target filters probe_list before picking next target", %{p1: p1, t1: t1} do
    # 1. Add some nodes to the membership
    nodes = for port <- 7001..7005 do
      node = {"n#{port}", port, ""}
      ping = {:ping, node, 1, []}
      {:ok, data} = Codec.encode(ping)
      InMemory.deliver(t1, node, data)
      node
    end

    Process.sleep(20)

    # 2. Modify state directly to simulate a `probe_list` containing both alive and dead/left nodes.
    # We'll set the probe_list to include one valid node at the end, and several invalid nodes before it.
    valid_node = List.last(nodes)
    invalid_node1 = {"n9991", 9991, ""}
    invalid_node2 = {"n9992", 9992, ""}
    invalid_node3 = {"n9993", 9993, ""}

    # Our fake probe list: invalid nodes followed by the valid node.
    # In the old logic, this would recurse 3 times. In the new logic, it uses Enum.reject once.
    probe_list = [invalid_node1, invalid_node2, invalid_node3, valid_node]

    :sys.replace_state(p1, fn state ->
      %{state | probe_list: probe_list}
    end)

    # 3. Trigger a protocol period to select the next probe target
    send(p1, :protocol_period)

    Process.sleep(20)

    # 4. Check the new state. The next probe target should have been valid_node.
    # The `probe_list` should now be empty (since valid_node was the last in the rejected list).
    state = :sys.get_state(p1)

    assert state.probe_list == [], "probe_list should be empty after picking the last valid node"

    # Also, we can verify that a ping was sent to the valid node by checking if it's in pending or ping_times.
    # Instead of checking that, we can directly assert that invalid_nodes are removed.
    
    # We will do a second check. If we set probe_list to just invalid nodes, it should return {nil, state} or pick from reshuffled peers, but importantly probe_list is cleaned.
    :sys.replace_state(p1, fn state ->
      %{state | probe_list: [invalid_node1, invalid_node2]}
    end)

    send(p1, :protocol_period)
    Process.sleep(20)
    
    state = :sys.get_state(p1)
    # Since the initial probe_list was only invalid nodes, it should have been filtered to [],
    # which would then trigger a reshuffle of all alive nodes, leaving length(nodes) - 1 in the probe_list.
    assert length(state.probe_list) == length(nodes) - 1, "should have reshuffled and picked one"
  end
end
