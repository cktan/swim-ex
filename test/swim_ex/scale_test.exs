defmodule SwimEx.ScaleTest do
  @moduledoc """
  Large scale stress tests for SwimEx.
  """

  use ExUnit.Case

  alias SwimEx.Transport.InMemory
  alias SwimEx.Transport.InMemory.Network

  @t 40
  @ping_timeout 20
  @suspicion_mult 4
  @convergence_timeout @t * 150 

  defp node_opts(net, host, port, extra \\ []) do
    transport_name = :"t_#{host}_#{port}"
    node_name = :"n_#{host}_#{port}"

    {:ok, t_pid} =
      InMemory.start_link(
        network: net,
        identity: {host, port, ""},
        name: transport_name
      )

    {:ok, n_pid} =
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
            seed_retry_interval: @t * 10,
            dead_node_expiry: @t * 40
          ],
          extra
        )
      )

    %{t: transport_name, n: node_name, t_pid: t_pid, n_pid: n_pid, host: host, port: port}
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
        Process.sleep(min(20, remaining))
        do_wait(deadline, check_fn)
      end
    end
  end

  defp all_converged?(nodes, expected_count) do
    Enum.all?(nodes, fn node ->
      members = SwimEx.Protocol.members(node.n, include_dead: false)
      length(members) == expected_count - 1
    end)
  end

  setup do
    {:ok, net} = Network.start_link()
    %{net: net}
  end

  @tag timeout: 240_000
  test "64-node network: staged startup, failure detection, and pause/unpause", %{net: net} do
    seed_host = "node_1"
    seed_port = 1000
    seed = {seed_host, seed_port}
    
    odd_indices = Enum.take_every(1..64, 2)
    odd_nodes = for i <- odd_indices do
      opts = if i == 1, do: [], else: [seeds: [seed]]
      node_opts(net, "node_#{i}", 1000, opts)
    end

    result = wait_for(@convergence_timeout, fn -> all_converged?(odd_nodes, 32) end)
    assert result == :ok, "32 odd nodes did not converge"

    even_indices = Enum.drop_every(1..64, 2)
    even_nodes = for i <- even_indices do
      node_opts(net, "node_#{i}", 1000, seeds: [seed])
    end

    all_nodes = Enum.sort_by(odd_nodes ++ even_nodes, fn n -> n.host end)
    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(all_nodes, 64) end)
    assert result == :ok, "64 nodes did not converge"

    # Subscribe a collector process to a handful of nodes (e.g., 5 random nodes)
    # We filter out node_7 (which is about to be killed) and node_14 (which will be paused/gracefully leave later)
    subscriber_nodes =
      all_nodes
      |> Enum.filter(fn n -> n.host not in ["node_7", "node_14"] end)
      |> Enum.take(5)

    parent = self()
    collectors =
      for node <- subscriber_nodes do
        spawn_link(fn ->
          SwimEx.Protocol.subscribe(node.n, self())
          loop_collector(parent, node.host)
        end)
      end

    # Kill node 7
    node_7 = Enum.find(all_nodes, fn n -> n.host == "node_7" end)
    GenServer.stop(node_7.n_pid)
    GenServer.stop(node_7.t_pid)
    remaining_nodes = List.delete(all_nodes, node_7)

    result = wait_for(@t * @suspicion_mult * 20, fn ->
      Enum.all?(remaining_nodes, fn node ->
        members = SwimEx.Protocol.members(node.n, include_dead: true)
        entry = Enum.find(members, fn {h, _, _, _, _} -> h == "node_7" end)
        entry != nil and elem(entry, 3) == :dead
      end)
    end)
    assert result == :ok, "node_7 was not recognized as dead"

    # Assert each subscriber received a :node_down event for node_7
    for node <- subscriber_nodes do
      host = node.host
      assert_receive {^host, {:swim, :node_down, {"node_7", 1000, ""}}}, @t * @suspicion_mult * 20
    end

    # Clean up collector processes
    Enum.each(collectors, fn pid ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end)

    # Wait for node_7 dead entry to be garbage collected after dead_node_expiry (@t * 40 = 1600ms)
    # We use a budget of @t * 50 (2000ms) to allow periodic GC to execute
    result = wait_for(@t * 50, fn ->
      Enum.all?(remaining_nodes, fn node ->
        members = SwimEx.Protocol.members(node.n, include_dead: true)
        entry = Enum.find(members, fn {h, _, _, _, _} -> h == "node_7" end)
        entry == nil
      end)
    end)
    assert result == :ok, "node_7 dead entry was not garbage collected after dead_node_expiry"

    # Pause node 14
    node_14 = Enum.find(all_nodes, fn n -> n.host == "node_14" end)
    InMemory.set_fault(node_14.t, packet_loss: 1.0)

    result = wait_for(@t * @suspicion_mult * 20, fn ->
      Enum.all?(remaining_nodes, fn node ->
        if node.host == "node_14" do
           true
        else
          members = SwimEx.Protocol.members(node.n, include_dead: true)
          entry = Enum.find(members, fn {h, _, _, _, _} -> h == "node_14" end)
          entry != nil and elem(entry, 3) == :dead
        end
      end)
    end)
    assert result == :ok, "node_14 was not recognized as dead"

    # Unpause node 14
    InMemory.set_fault(node_14.t, packet_loss: 0.0)

    result = wait_for(@convergence_timeout * 3, fn ->
      members_14 = SwimEx.Protocol.members(node_14.n, include_dead: false)
      length(members_14) == 62 and 
      Enum.all?(remaining_nodes, fn node ->
        if node.host == "node_14" do
          true
        else
          members = SwimEx.Protocol.members(node.n, include_dead: false)
          entry = Enum.find(members, fn {h, _, _, _, _} -> h == "node_14" end)
          entry != nil and elem(entry, 3) == :alive
        end
      end)
    end)
    assert result == :ok, "node_14 did not rejoin successfully"

    # Graceful leave node 14
    IO.puts("Testing graceful leave on node_14...")
    SwimEx.Protocol.leave(node_14.n)
    remaining_after_leave = List.delete(remaining_nodes, node_14)

    result = wait_for(@t * 5, fn ->
      Enum.all?(remaining_after_leave, fn node ->
        members = SwimEx.Protocol.members(node.n, include_dead: true)
        entry = Enum.find(members, fn {h, _, _, _, _} -> h == "node_14" end)
        entry != nil and elem(entry, 3) == :dead
      end)
    end)
    assert result == :ok, "node_14 graceful leave was not recognized as dead within deadline"

    # Clean up node 14 transport
    GenServer.stop(node_14.t_pid)
  end

  @tag timeout: 120_000
  test "64-node network: partition and heal", %{net: net} do
    seed = {"p_node_1", 2000}
    nodes = for i <- 1..64 do
      opts = if i == 1, do: [], else: [seeds: [seed]]
      node_opts(net, "p_node_#{i}", 2000, opts)
    end

    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed"

    # Partition into two groups
    group_a = for i <- 1..32, do: "p_node_#{i}"
    group_b = for i <- 33..64, do: "p_node_#{i}"
    
    IO.puts("Setting partition between Group A (1-32) and Group B (33-64)...")
    Network.set_partitions(net, [group_a, group_b])

    # Each group should eventually see everyone in the OTHER group as dead
    IO.puts("Waiting for split brain to stabilize...")
    result = wait_for(@t * @suspicion_mult * 25, fn ->
      Enum.all?(nodes, fn node ->
        members = SwimEx.Protocol.members(node.n, include_dead: false)
        length(members) == 31 # only knows 31 others in its group
      end)
    end)
    assert result == :ok, "partition did not result in split brain"

    # Heal the partition
    IO.puts("Healing partition...")
    Network.clear_partitions(net)

    # Cluster should merge back to 64
    result = wait_for(@convergence_timeout * 4, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "cluster did not heal after partition"
  end

  @tag timeout: 120_000
  test "64-node network: asymmetric partition (1 vs 63)", %{net: net} do
    seed = {"ap_node_1", 2500}
    nodes = for i <- 1..64 do
      opts = if i == 1, do: [], else: [seeds: [seed]]
      node_opts(net, "ap_node_#{i}", 2500, opts)
    end

    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed"

    # Partition into one isolated node (the seed) and 63 majority nodes
    isolated_host = "ap_node_1"
    isolated_group = [isolated_host]
    majority_group = for i <- 2..64, do: "ap_node_#{i}"

    IO.puts("Isolating ap_node_1 from the other 63 nodes...")
    Network.set_partitions(net, [isolated_group, majority_group])

    # Isolated node should mark all 63 others as dead
    # 63 majority nodes should mark the isolated node as dead
    IO.puts("Waiting for asymmetric partition to stabilize...")
    result = wait_for(@t * @suspicion_mult * 25, fn ->
      isolated_node = Enum.find(nodes, fn n -> n.host == isolated_host end)
      isolated_members = SwimEx.Protocol.members(isolated_node.n, include_dead: false)

      majority_nodes = Enum.filter(nodes, fn n -> n.host != isolated_host end)
      
      length(isolated_members) == 0 and
        Enum.all?(majority_nodes, fn node ->
          members = SwimEx.Protocol.members(node.n, include_dead: false)
          entry = Enum.find(members, fn {h, _, _, _, _} -> h == isolated_host end)
          length(members) == 62 and entry == nil
        end)
    end)
    assert result == :ok, "asymmetric partition stabilization failed"

    # Heal the partition
    IO.puts("Healing asymmetric partition...")
    Network.clear_partitions(net)

    # Cluster should merge back to 64
    result = wait_for(@convergence_timeout * 4, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "cluster did not heal after asymmetric partition"
  end

  @tag timeout: 120_000
  test "64-node network: 30% packet loss stress", %{net: net} do
    seed = {"lossy_node_1", 3000}
    nodes = for i <- 1..64 do
      opts = if i == 1, do: [packet_loss: 0.3], else: [seeds: [seed], packet_loss: 0.3]
      node_opts(net, "lossy_node_#{i}", 3000, opts)
    end

    IO.puts("Waiting for convergence with 30% packet loss...")
    # Should take much longer
    result = wait_for(@convergence_timeout * 6, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "convergence with 30% packet loss failed"
  end

  @tag timeout: 120_000
  test "64-node network: churn stress (restarting nodes)", %{net: net} do
    seed = {"churn_node_1", 4000}
    nodes = for i <- 1..64 do
      opts = if i == 1, do: [], else: [seeds: [seed]]
      node_opts(net, "churn_node_#{i}", 4000, opts)
    end

    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed"

    IO.puts("Starting churn: killing and restarting nodes...")
    # Kill nodes 50-60
    for i <- 50..60 do
      n = Enum.at(nodes, i-1)
      GenServer.stop(n.n_pid)
      GenServer.stop(n.t_pid)
    end

    # Wait for others to see them as dead
    Process.sleep(@t * @suspicion_mult * 15)

    # Restart them
    for i <- 50..60 do
      node_opts(net, "churn_node_#{i}", 4000, seeds: [seed])
    end

    IO.puts("Waiting for re-convergence after churn...")
    result = wait_for(@convergence_timeout * 4, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "re-convergence after churn failed"
  end

  @tag timeout: 120_000
  test "64-node network: half-cluster restart immediately (immediate revival)", %{net: net} do
    seed_host = "half_churn_node_1"
    seed_port = 5000
    seed = {seed_host, seed_port}
    
    # Start all 64 nodes with incarnation 1
    nodes = for i <- 1..64 do
      opts = if i == 1, do: [incarnation: 1], else: [seeds: [seed], incarnation: 1]
      node_opts(net, "half_churn_node_#{i}", seed_port, opts)
    end

    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed"

    IO.puts("Killing half the cluster immediately (including seed)...")
    # Kill nodes 1 to 32 (indices 0 to 31)
    killed_nodes = Enum.slice(nodes, 0, 32)
    for n <- killed_nodes do
      GenServer.stop(n.n_pid)
      GenServer.stop(n.t_pid)
    end

    IO.puts("Restarting killed nodes immediately with incarnation 2...")
    # Restart them immediately with incarnation 2, replacing their records in our tracking list
    nodes =
      Enum.map(nodes, fn n ->
        host_num = String.to_integer(String.replace(n.host, ~r/\D/, ""))
        if host_num <= 32 do
          opts = if host_num == 1, do: [incarnation: 2], else: [seeds: [seed], incarnation: 2]
          node_opts(net, n.host, seed_port, opts)
        else
          n
        end
      end)

    IO.puts("Waiting for re-convergence after immediate half-cluster restart...")
    result = wait_for(@convergence_timeout * 5, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "re-convergence failed after immediate half-cluster restart"
  end

  @tag timeout: 120_000
  test "64-node network: half-cluster restart after death detection (staged revival)", %{net: net} do
    seed_host = "half_staged_node_1"
    seed_port = 5500
    seed = {seed_host, seed_port}

    # Start all 64 nodes with incarnation 1
    nodes = for i <- 1..64 do
      opts = if i == 1, do: [incarnation: 1], else: [seeds: [seed], incarnation: 1]
      node_opts(net, "half_staged_node_#{i}", seed_port, opts)
    end

    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed"

    IO.puts("Killing half the cluster (including seed)...")
    # Kill nodes 1 to 32 (indices 0 to 31)
    killed_nodes = Enum.slice(nodes, 0, 32)
    for n <- killed_nodes do
      GenServer.stop(n.n_pid)
      GenServer.stop(n.t_pid)
    end

    IO.puts("Waiting for the remaining 32 nodes to detect death...")
    remaining_nodes = Enum.slice(nodes, 32, 32)
    result = wait_for(@t * @suspicion_mult * 20, fn ->
      Enum.all?(remaining_nodes, fn node ->
        members = SwimEx.Protocol.members(node.n, include_dead: true)
        Enum.all?(1..32, fn i ->
          entry = Enum.find(members, fn {h, _, _, _, _} -> h == "half_staged_node_#{i}" end)
          entry != nil and elem(entry, 3) == :dead
        end)
      end)
    end)
    assert result == :ok, "dead nodes were not recognized as dead"

    IO.puts("Restarting killed nodes with incarnation 2 after death detection...")
    # Restart them with incarnation 2, replacing their records in our tracking list
    nodes =
      Enum.map(nodes, fn n ->
        host_num = String.to_integer(String.replace(n.host, ~r/\D/, ""))
        if host_num <= 32 do
          opts = if host_num == 1, do: [incarnation: 2], else: [seeds: [seed], incarnation: 2]
          node_opts(net, n.host, seed_port, opts)
        else
          n
        end
      end)

    IO.puts("Waiting for re-convergence after staged half-cluster restart...")
    result = wait_for(@convergence_timeout * 5, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "re-convergence failed after staged half-cluster restart"
  end

  defp loop_collector(parent, host) do
    receive do
      msg ->
        send(parent, {host, msg})
        loop_collector(parent, host)
    end
  end
end
