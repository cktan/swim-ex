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
        identity: {host, port},
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

    assert Enum.any?(members1, fn {h, p, _} -> h == "n2" and p == 7001 end),
           "n1 should know about n2, got: #{inspect(members1)}"

    assert Enum.any?(members2, fn {h, p, _} -> h == "n1" and p == 7001 end),
           "n2 should know about n1, got: #{inspect(members2)}"
  end

  test "subscriber receives node_up event when node joins", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7002)
    SwimEx.Protocol.subscribe(n1, self())

    {_t2, _n2} = start_node(net, "n2", 7002, seeds: [{"n1", 7002}])

    assert_receive {:swim, :node_up, {"n2", 7002}}, @t * 10
  end

  test "node_suspect event fired when peer stops responding", %{net: net} do
    {t2, _} = start_node(net, "n1", 7003)
    {_t1, n1} = start_node(net, "n2", 7003, seeds: [{"n1", 7003}])

    Process.sleep(@t * 6)
    SwimEx.Protocol.subscribe(n1, self())

    # Cut n1's outbound traffic by setting 100% loss
    InMemory.set_fault(t2, packet_loss: 1.0)

    assert_receive {:swim, :node_suspect, {"n1", 7003}}, @t * 10
  end

  test "node declared dead after suspicion timeout", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7004)
    {t2, _n2} = start_node(net, "n2", 7004, seeds: [{"n1", 7004}])

    Process.sleep(@t * 6)
    SwimEx.Protocol.subscribe(n1, self())

    # Make n2 disappear completely
    InMemory.set_fault(t2, packet_loss: 1.0)

    assert_receive {:swim, :node_suspect, {"n2", 7004}}, @t * 10
    assert_receive {:swim, :node_down, {"n2", 7004}}, @t * 15
  end

  test "members/2 returns alive and suspect, filters dead by default", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7005)
    {t2, _n2} = start_node(net, "n2", 7005, seeds: [{"n1", 7005}])

    Process.sleep(@t * 6)

    SwimEx.Protocol.subscribe(n1, self())
    InMemory.set_fault(t2, packet_loss: 1.0)

    # Wait for dead event, then check immediately before GC runs
    assert_receive {:swim, :node_down, {"n2", 7005}}, @t * 15

    all = SwimEx.Protocol.members(n1, include_dead: true)
    alive_only = SwimEx.Protocol.members(n1, include_dead: false)

    assert Enum.any?(all, fn {h, p, s} -> h == "n2" and p == 7005 and s == :dead end),
           "n2 should be dead in full list, got: #{inspect(all)}"

    refute Enum.any?(alive_only, fn {h, p, _} -> h == "n2" and p == 7005 end),
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

  test "leave/1 removes node from peers' membership", %{net: net} do
    {_t1, n1} = start_node(net, "n1", 7007)
    {_t2, n2} = start_node(net, "n2", 7007, seeds: [{"n1", 7007}])

    Process.sleep(@t * 6)

    assert Enum.any?(SwimEx.Protocol.members(n2, include_dead: false), fn {h, _, _} ->
             h == "n1"
           end)

    SwimEx.Protocol.leave(n1)
    Process.sleep(@t * 4)

    members = SwimEx.Protocol.members(n2, include_dead: false)

    refute Enum.any?(members, fn {h, _, _} -> h == "n1" end),
           "n1 should have left, got: #{inspect(members)}"
  end
end
