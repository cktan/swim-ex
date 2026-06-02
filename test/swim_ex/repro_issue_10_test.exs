defmodule SwimEx.ReproIssue10Test do
  use ExUnit.Case

  alias SwimEx.Transport.InMemory.Network
  alias SwimEx.Transport.InMemory
  alias SwimEx.Codec

  @suspicion_timeout 100

  setup do
    {:ok, net} = Network.start_link()
    {:ok, t1} = InMemory.start_link(network: net, identity: {"n1", 7000})

    {:ok, p1} = SwimEx.Protocol.start_link(
      host: "n1",
      port: 7000,
      transport: t1,
      transport_mod: InMemory,
      protocol_period: 100_000,
      suspicion_timeout: @suspicion_timeout
    )

    # Register n2 in membership as alive
    n2 = {"n2", 7000, ""}
    ping = {:ping, n2, 1, []}
    {:ok, data} = Codec.encode(ping)
    InMemory.deliver(t1, n2, data)

    Process.sleep(20)

    # Get current incarnation of n2
    members = SwimEx.Protocol.members(p1, include_dead: true)
    {"n2", 7000, "", _status, inc1} = Enum.find(members, fn {h, _p, _, _, _} -> h == "n2" end)

    %{p1: p1, t1: t1, n2: n2, inc1: inc1}
  end

  test "suspicion timer is refreshed when incarnation advances", %{p1: p1, t1: t1, n2: n2, inc1: inc1} do
    SwimEx.Protocol.subscribe(p1, self())

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

    # 3. Wait for the suspicion timeout.
    # The first timer (for inc1) should fire around @suspicion_timeout.
    # It will be ignored because the current incarnation is inc2.
    # If the bug is present, NO new timer was started for inc2.
    # So the node will remain :suspect indefinitely.

    # Wait long enough for both potential timers.
    Process.sleep(@suspicion_timeout * 2)

    # Check if the node is dead. If the fix works, it should be dead.
    # If the bug exists, it will still be suspect.
    members = SwimEx.Protocol.members(p1, include_dead: true)
    {"n2", 7000, "", status, _inc} = Enum.find(members, fn {h, _p, _, _, _} -> h == "n2" end)

    assert status == :dead, "expected :dead but got #{status}"
  end
end
