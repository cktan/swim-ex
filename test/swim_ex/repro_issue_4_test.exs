defmodule SwimEx.ReproIssue4Test do
  use ExUnit.Case

  alias SwimEx.Transport.InMemory.Network
  alias SwimEx.Transport.InMemory
  alias SwimEx.Codec

  @t 50

  setup do
    {:ok, net} = Network.start_link()
    {:ok, t1} = InMemory.start_link(network: net, identity: {"n1", 7000})
    
    {:ok, p1} = SwimEx.Protocol.start_link(
      host: "n1",
      port: 7000,
      transport: t1,
      transport_mod: InMemory,
      protocol_period: 100_000,
      suspicion_timeout: @t * 10
    )
    
    # Register n2 in membership as alive
    n2 = {"n2", 7000, ""}
    ping = {:ping, n2, 1, []}
    {:ok, data} = Codec.encode(ping)
    InMemory.deliver(t1, n2, data)
    
    Process.sleep(20) # Wait for ping to be processed
    
    # Get current incarnation of n2
    members = SwimEx.Protocol.members(p1, [include_dead: true])
    {"n2", 7000, "", _status, inc1} = Enum.find(members, fn {h, _p, _, _, _} -> h == "n2" end)
    
    %{p1: p1, t1: t1, n2: n2, inc1: inc1}
  end

  test "stale suspicion_timeout does not kill re-suspected node", %{p1: p1, t1: t1, n2: n2, inc1: inc1} do
    SwimEx.Protocol.subscribe(p1, self())
    
    # We use a third node to deliver gossip so we don't trigger update_node_alive(n2)
    other = {"other", 8000, ""}

    # 1. Suspect n2 at inc1
    suspect_1 = {:suspect, n2, inc1}
    ping_suspect_1 = {:ping, other, 2, [suspect_1]}
    {:ok, data1} = Codec.encode(ping_suspect_1)
    InMemory.deliver(t1, other, data1)
    
    assert_receive {:swim, :node_suspect, ^n2}, 500
    
    # 2. Suspect n2 at higher inc
    inc2 = inc1 + 1
    suspect_2 = {:suspect, n2, inc2}
    ping_suspect_2 = {:ping, other, 3, [suspect_2]}
    {:ok, data2} = Codec.encode(ping_suspect_2)
    InMemory.deliver(t1, other, data2)
    
    # Should get another suspect event because incarnation changed
    assert_receive {:swim, :node_suspect, ^n2}, 500
    
    # 3. Send STALE suspicion_timeout (simulating it was already in mailbox)
    # This is from the OLD incarnation (inc1)
    send(p1, {:suspicion_timeout, n2, inc1})
    
    # With the fix, n2 should NOT be marked dead.
    refute_receive {:swim, :node_down, ^n2}, 200
    
    # Let's check membership - should still be suspect
    members = SwimEx.Protocol.members(p1, include_dead: true)
    {"n2", 7000, "", status, inc} = Enum.find(members, fn {h, _p, _, _, _} -> h == "n2" end)
    
    assert status == :suspect, "Node should still be suspect, but was #{status}"
    assert inc == inc2, "Incarnation should be #{inc2}, but was #{inc}"

    # 4. Now send the CORRECT suspicion_timeout
    send(p1, {:suspicion_timeout, n2, inc2})
    assert_receive {:swim, :node_down, ^n2}, 500

    # Verify it is indeed dead now
    members = SwimEx.Protocol.members(p1, include_dead: true)
    {"n2", 7000, "", status, _} = Enum.find(members, fn {h, _p, _, _, _} -> h == "n2" end)
    assert status == :dead
  end
end
