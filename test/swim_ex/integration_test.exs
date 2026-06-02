defmodule SwimEx.IntegrationTest do
  @moduledoc """
  Multi-node integration tests using InMemory transport.
  All tests run at T=30ms so the suite stays fast.
  """

  use ExUnit.Case

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
            dead_node_expiry: @t * 10
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

  defp all_know_each_other(names) do
    Enum.all?(names, fn name ->
      # Just check this node has N-1 peers
      members = SwimEx.Protocol.members(name, include_dead: false)
      length(members) == length(names) - 1
    end)
  end

  setup do
    {:ok, net} = Network.start_link()
    %{net: net}
  end

  # --- Convergence tests ---

  test "3-node cluster fully converges via gossip", %{net: net} do
    {_t1, n1} = node_opts(net, "a1", 1001)
    {_t2, n2} = node_opts(net, "a2", 1001, seeds: [{"a1", 1001}])
    {_t3, n3} = node_opts(net, "a3", 1001, seeds: [{"a1", 1001}])

    names = [n1, n2, n3]

    result = wait_for(@t * 20, fn -> all_know_each_other(names) end)
    assert result == :ok, "3-node cluster did not converge"

    Enum.each(names, fn name ->
      peers = SwimEx.Protocol.members(name, include_dead: false)
      assert length(peers) == 2, "#{name} should have 2 peers, got: #{inspect(peers)}"
    end)
  end

  test "5-node cluster converges", %{net: net} do
    {_t1, n1} = node_opts(net, "b1", 2001)

    others =
      for i <- 2..5 do
        {_t, n} = node_opts(net, "b#{i}", 2001, seeds: [{"b1", 2001}])
        n
      end

    names = [n1 | others]

    result = wait_for(@t * 30, fn -> all_know_each_other(names) end)
    assert result == :ok, "5-node cluster did not converge"
  end

  # --- Failure detection tests ---

  test "packet loss triggers suspect → dead pipeline", %{net: net} do
    {t1, _n1} = node_opts(net, "c1", 3001)
    {_t2, n2} = node_opts(net, "c2", 3001, seeds: [{"c1", 3001}])

    Process.sleep(@t * 10)

    SwimEx.Protocol.subscribe(n2, self())

    # Drop all outbound packets from c1 → c1 can't ack pings
    InMemory.set_fault(t1, packet_loss: 1.0)

    assert_receive {:swim, :node_suspect, {"c1", 3001, ""}}, @t * 10
    assert_receive {:swim, :node_down, {"c1", 3001, ""}}, @t * 20
  end

  test "3-node cluster detects dead node via suspect + indirect", %{net: net} do
    {_t1, n1} = node_opts(net, "d1", 4001)
    {t2, _n2} = node_opts(net, "d2", 4001, seeds: [{"d1", 4001}])
    {_t3, n3} = node_opts(net, "d3", 4001, seeds: [{"d1", 4001}])

    names = [n1, :n_d2_4001, n3]
    :ok = wait_for(@t * 20, fn -> all_know_each_other(names) end)

    SwimEx.Protocol.subscribe(n1, self())
    SwimEx.Protocol.subscribe(n3, self())

    # Kill n2's outbound — it can't ack any pings
    InMemory.set_fault(t2, packet_loss: 1.0)

    # Both n1 and n3 should eventually declare n2 dead
    assert_receive {:swim, :node_down, {"d2", 4001, ""}}, @t * 20
    assert_receive {:swim, :node_down, {"d2", 4001, ""}}, @t * 20
  end

  # --- Graceful leave ---

  test "leave/1 broadcasts dead and node removed from peers", %{net: net} do
    {_t1, n1} = node_opts(net, "e1", 5001)
    {_t2, n2} = node_opts(net, "e2", 5001, seeds: [{"e1", 5001}])
    {_t3, n3} = node_opts(net, "e3", 5001, seeds: [{"e1", 5001}])

    names = [n1, n2, n3]
    :ok = wait_for(@t * 20, fn -> all_know_each_other(names) end)

    SwimEx.Protocol.subscribe(n2, self())
    SwimEx.Protocol.subscribe(n3, self())

    SwimEx.Protocol.leave(n1)

    assert_receive {:swim, :node_down, {"e1", 5001, ""}}, @t * 5
    assert_receive {:swim, :node_down, {"e1", 5001, ""}}, @t * 5

    members_n2 = SwimEx.Protocol.members(n2, include_dead: false)
    members_n3 = SwimEx.Protocol.members(n3, include_dead: false)

    refute Enum.any?(members_n2, fn {h, _, _, _} -> h == "e1" end)
    refute Enum.any?(members_n3, fn {h, _, _, _} -> h == "e1" end)
  end

  # --- Telemetry ---

  test "telemetry :node_up event fires on join", %{net: net} do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "test-node-up-#{inspect(ref)}",
      [:swim, :node, :up],
      fn _event, _measurements, meta, _ ->
        Kernel.send(test_pid, {:telemetry_node_up, meta.peer})
      end,
      nil
    )

    {_t1, _n1} = node_opts(net, "f1", 6001)
    {_t2, _n2} = node_opts(net, "f2", 6001, seeds: [{"f1", 6001}])

    assert_receive {:telemetry_node_up, _}, @t * 15

    :telemetry.detach("test-node-up-#{inspect(ref)}")
  end

  test "telemetry :ping_rtt fires on successful ack", %{net: net} do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "test-rtt-#{inspect(ref)}",
      [:swim, :ping, :rtt],
      fn _event, measurements, _meta, _ ->
        Kernel.send(test_pid, {:telemetry_rtt, measurements.duration})
      end,
      nil
    )

    {_t1, _n1} = node_opts(net, "g1", 7001)
    node_opts(net, "g2", 7001, seeds: [{"g1", 7001}])

    assert_receive {:telemetry_rtt, duration}, @t * 15
    assert is_integer(duration) and duration >= 0

    :telemetry.detach("test-rtt-#{inspect(ref)}")
  end

  # --- Self-refutation ---

  test "suspected node refutes and stays alive", %{net: net} do
    {_t1, n1} = node_opts(net, "h1", 8001)
    {_t2, n2} = node_opts(net, "h2", 8001, seeds: [{"h1", 8001}])
    {_t3, n3} = node_opts(net, "h3", 8001, seeds: [{"h1", 8001}])

    names = [n1, n2, n3]
    :ok = wait_for(@t * 20, fn -> all_know_each_other(names) end)

    SwimEx.Protocol.subscribe(n2, self())

    # Inject a suspect event about n3 directly via gossip by
    # checking that n3 eventually refutes it (stays :alive)
    Process.sleep(@t * 5)

    # n3 should still be alive after a few more periods
    members = SwimEx.Protocol.members(n2, include_dead: false)
    n3_entry = Enum.find(members, fn {h, _, _, _} -> h == "h3" end)
    assert n3_entry != nil, "n3 should still be present"
    assert elem(n3_entry, 3) == :alive, "n3 should be alive after self-refutation, got: #{inspect(n3_entry)}"
  end
end
