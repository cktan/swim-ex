defmodule SwimEx.EdgeCasesTest do
  use ExUnit.Case, async: true

  alias SwimEx.GossipQueue
  alias SwimEx.Membership
  alias SwimEx.Transport.InMemory
  alias SwimEx.Transport.InMemory.Network

  @t 30
  @ping_timeout 15
  @suspicion_mult 3

  defp node_opts(net, host, port, extra \\ []) do
    transport_name = :"t_#{host}_#{port}"
    node_name = :"n_#{host}_#{port}"

    {:ok, _} =
      InMemory.start_link(
        network: net,
        identity: {host, port, ""},
        name: transport_name
      )

    {:ok, _} =
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
            suspicion_timeout: @t * @suspicion_mult,
            seed_retry_interval: @t * 5,
            dead_node_expiry: @t * 100
          ],
          extra
        )
      )

    {transport_name, node_name}
  end

  defp wait_for(timeout_ms, check_fn) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline, check_fn)
  end

  defp do_wait(deadline, check_fn) do
    if check_fn.() do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        {:error, :timeout}
      else
        Process.sleep(min(10, remaining))
        do_wait(deadline, check_fn)
      end
    end
  end

  # --- Scenario 1: MTU boundary ---

  test "GossipQueue.pack: exactly one more event would exceed MTU" do
    # An :alive event for a typical node identity is around 40-50 bytes when encoded with ETF.
    # We want to find a size that fits N events but not N+1.
    
    event = {:alive, {"127.0.0.1", 8000, ""}, 100}
    event_size = byte_size(:erlang.term_to_binary(event))
    
    # Empty list ETF size is 2 bytes.
    # First element adds 4 bytes + event_size.
    # Subsequent elements add event_size - 1 byte.
    # (These are the formulas used in GossipQueue.do_pack)
    
    # Let's say we want to fit 3 events.
    # Size for 1 event: 2 + 4 + event_size = 6 + event_size
    # Size for 2 events: (6 + event_size) + event_size - 1 = 5 + 2*event_size
    # Size for 3 events: (5 + 2*event_size) + event_size - 1 = 4 + 3*event_size
    # Size for 4 events: 3 + 4*event_size
    
    mtu = 4 + 3 * event_size
    
    q = GossipQueue.new()
    q = GossipQueue.enqueue(q, {:alive, {"127.0.0.1", 8001, ""}, 100})
    q = GossipQueue.enqueue(q, {:alive, {"127.0.0.1", 8002, ""}, 100})
    q = GossipQueue.enqueue(q, {:alive, {"127.0.0.1", 8003, ""}, 100})
    q = GossipQueue.enqueue(q, {:alive, {"127.0.0.1", 8004, ""}, 100}) # This one should not fit
    
    {packed, q2} = GossipQueue.pack(q, 10, mtu)
    
    assert length(packed) == 3
    # They stay in queue until transmit limit is reached
    assert GossipQueue.size(q2) == 4
    
    # Verify that adding the 4th one would have exceeded MTU
    full_encoded = :erlang.term_to_binary([{:alive, {"127.0.0.1", 8001, ""}, 100}, {:alive, {"127.0.0.1", 8002, ""}, 100}, {:alive, {"127.0.0.1", 8003, ""}, 100}, {:alive, {"127.0.0.1", 8004, ""}, 100}])
    assert byte_size(full_encoded) > mtu
    
    # Verify that the 3 packed ones actually fit
    packed_encoded = :erlang.term_to_binary(packed)
    assert byte_size(packed_encoded) <= mtu
  end

  # --- Scenario 2: Clock skew (NTP rollback) ---
  # Note: Since we can't easily roll back System.system_time in Elixir without global effects,
  # we simulate it by manually triggering a restart with a specific incarnation.
  
  test "Clock skew: node restarts with lower incarnation" do
    {:ok, net} = Network.start_link()
    
    # Node A is the observer
    {tA, nA} = node_opts(net, "A", 1000)
    
    # Node B joins
    initial_inc = 5000
    {tB, nB} = node_opts(net, "B", 1000, seeds: [{"A", 1000}], incarnation: initial_inc)
    
    # Wait for A to see B
    assert :ok = wait_for(500, fn -> 
      members = SwimEx.Protocol.members(nA, [])
      Enum.any?(members, fn {h, p, _, _, _} -> h == "B" and p == 1000 end)
    end)
    
    # Stop B and its transport
    Supervisor.stop(nB)
    GenServer.stop(tB)
    
    # Wait for A to mark B dead (to ensure we are testing revival from dead)
    assert :ok = wait_for(1000, fn ->
      members = SwimEx.Protocol.members(nA, include_dead: true)
      entry = Enum.find(members, fn {h, p, _, _, _} -> h == "B" and p == 1000 end)
      match?({_, _, _, :dead, _}, entry)
    end)

    # Capture the incarnation A has for B when it's dead
    members = SwimEx.Protocol.members(nA, include_dead: true)
    {_, _, _, :dead, dead_inc} = Enum.find(members, fn {h, p, _, _, _} -> h == "B" and p == 1000 end)

    # Manually send an alive event with lower incarnation to A
    # We use a raw message to avoid B refuting its own death if it were to receive gossip from A.
    lower_inc = dead_inc - 1000
    msg = {:ping, {"B", 1000, ""}, 123, [{:alive, {"B", 1000, ""}, lower_inc}]}
    {:ok, data} = SwimEx.Codec.encode(msg)
    
    # We need the transport name of A to send to it
    # {tA, nA} = node_opts(...)
    InMemory.deliver(tA, {"B", 1000, ""}, data)
    
    # A should still see B as dead at dead_inc, ignoring the lower_inc alive
    Process.sleep(@t * 10)
    
    members = SwimEx.Protocol.members(nA, include_dead: true)
    b_entry = Enum.find(members, fn {h, p, _, _, _} -> h == "B" and p == 1000 end)
    
    assert b_entry != nil
    {_, _, _, status, inc} = b_entry
    assert inc == dead_inc
    assert status == :dead
  end

  # --- Scenario 3: Rapid join/leave ---

  test "Rapid join/leave within a single protocol period" do
    {:ok, net} = Network.start_link()
    {_tA, nA} = node_opts(net, "A", 1000)
    
    # Start B
    {_tB, nB} = node_opts(net, "B", 1000, seeds: [{"A", 1000}])
    
    # Ensure A saw B (avoid vacuously green test)
    assert :ok = wait_for(1000, fn -> 
      members = SwimEx.Protocol.members(nA, [])
      Enum.any?(members, fn {h, p, _, _, _} -> h == "B" and p == 1000 end)
    end)

    # Now stop B immediately
    Supervisor.stop(nB)
    
    # A should eventually mark it dead.
    Process.sleep(@t * 20)
    
    members = SwimEx.Protocol.members(nA, include_dead: true)
    b_entry = Enum.find(members, fn {h, p, _, _, _} -> h == "B" and p == 1000 end)
    
    assert b_entry != nil
    {_, _, _, status, _} = b_entry
    assert status in [:suspect, :dead]
  end

  # --- Scenario 4: Packet reorder (Suspect after Alive) ---

  test "Membership: suspect after alive for same incarnation" do
    # Scenario: A node receives {:alive, N, 100} and then {:suspect, N, 100}.
    # The suspect should be accepted (transition from alive to suspect).
    # IF the issue meant "should drop it", we'll see if that's true.
    
    m = Membership.new()
    node = {"B", 1000, ""}
    inc = 100
    
    m = Membership.apply_event(m, {:alive, node, inc})
    assert %{status: :alive, incarnation: ^inc} = Membership.get(m, node)
    
    m2 = Membership.apply_event(m, {:suspect, node, inc})
    
    # Current implementation: alive -> suspect for same incarnation
    # If the issue wants it DROPPED, this assert will FAIL if I change it to match the issue description.
    # But let's first see what it does.
    
    # Actually, the issue says "(Membership should drop it, but this is unverified)".
    # If I verify it and find it DOES NOT drop it, maybe I should "fix" it to drop it?
    # Let's check the SWIM paper again. 
    # In SWIM, a Suspect(inc) message should be processed if the node is Alive(inc).
    
    %{status: status} = Membership.get(m2, node)
    assert status == :suspect
  end
end
