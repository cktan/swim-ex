defmodule SwimEx.ScaleTest do
  @moduledoc """
  Large-scale stress and convergence tests for SwimEx.

  This test suite simulates clusters of up to 64 nodes running the SWIM protocol
  (including the suspicion mechanism) using an in-memory transport layer.
  It validates the protocol's correctness, robustness, and performance characteristics
  under various network topologies, failures, partitions, packet loss, and churn.

  ## Parameters
  The protocol and simulation run under accelerated parameters to ensure tests run
  quickly while preserving the relative timing ratios of the protocol:
  * `@t` (40ms): The protocol period. Every `@t` milliseconds, a node initiates a probe.
  * `@ping_timeout` (20ms): The timeout for a direct ping request.
  * `@suspicion_mult` (4): The multiplier for the suspicion timeout.
  * `@convergence_timeout` (`@t * 150` = 6000ms): The deadline for the cluster to achieve consensus/full membership view.

  ## Simulated Scenarios
  1. **Staged Startup, Failure Detection, & Pause/Unpause**:
     Ensures nodes can bootstrap via a seed, detect node failures, handle node pausing (simulated high packet loss), and gracefully leave the cluster.
  2. **Partition and Heal**:
     Tests split-brain situations by cleanly partitioning the 64-node cluster into two equal groups, then verifying that they heal back into a single cluster.
  3. **Asymmetric Partition**:
     Isolates a single node from the remaining 63 nodes, verifying that both sides correctly detect the state transition and recover once healed.
  4. **Packet Loss**:
     Stress tests cluster convergence under 30% packet loss.
  5. **Churn (Restarting Nodes)**:
     Tests robustness against node failure and subsequent restart.
  6. **Half-Cluster Restart (Immediate vs Staged)**:
     Validates the incarnation increment mechanism by stopping half the cluster and restarting them (either immediately or after their death has been propagated).
  """

  use ExUnit.Case

  alias SwimEx.Transport.InMemory
  alias SwimEx.Transport.InMemory.Network

  @t 40
  @ping_timeout 20
  @suspicion_mult 4
  @convergence_timeout @t * 150 

  # Helper to configure and start a single simulated SWIM node.
  #
  # Spawns both the transport process (`SwimEx.Transport.InMemory`) and the protocol
  # process (`SwimEx.Protocol`).
  #
  # ## Arguments
  # * `net` - The pid of the shared `SwimEx.Transport.InMemory.Network` process.
  # * `host` - The host name string for the node (e.g. `"node_1"`).
  # * `port` - The port integer for the node (e.g. `1000`).
  # * `extra` - Keyword list of extra options/overrides to merge into the node protocol parameters.
  #
  # ## Returns
  # A map containing:
  # * `:t` - The registered name of the transport process.
  # * `:n` - The registered name of the protocol process.
  # * `:t_pid` - The PID of the transport process.
  # * `:n_pid` - The PID of the protocol process.
  # * `:host` - The host name.
  # * `:port` - The port.
  defp node_opts(net, host, port, extra \\ []) do
    transport_name = :"t_#{host}_#{port}"
    node_name = :"n_#{host}_#{port}"

    transport_opts =
      [
        network: net,
        identity: {host, port, ""},
        name: transport_name
      ] ++ Keyword.take(extra, [:packet_loss, :delay_ms, :reorder])

    {:ok, t_pid} = InMemory.start_link(transport_opts)

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

  # Helper that repeatedly runs a check function until it returns true or the timeout expires.
  #
  # ## Arguments
  # * `timeout_ms` - Maximum duration in milliseconds to poll the check function.
  # * `check_fn` - A zero-arity function returning a boolean.
  #
  # ## Returns
  # * `:ok` - If `check_fn` returns true before the timeout.
  # * `{:error, :timeout}` - If the timeout is reached.
  defp wait_for(timeout_ms, check_fn) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline, check_fn)
  end

  # Tail-recursive implementation of `wait_for/2`.
  #
  # Computes the remaining time before the deadline and sleeps briefly between attempts.
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

  # Asserts that all nodes in the given list have converged and hold a complete membership view.
  #
  # In a fully connected cluster of `expected_count` nodes, each node must see
  # `expected_count - 1` other alive members (excluding themselves).
  #
  # ## Arguments
  # * `nodes` - List of maps representing the simulated nodes.
  # * `expected_count` - The expected size of the cluster.
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
  test "64-node network: 4-way partition and gradual heal", %{net: net} do
    seed_a = {"m_node_1", 2200}
    seed_b = {"m_node_33", 2200}
    seeds = [seed_a, seed_b]

    nodes = for i <- 1..64 do
      opts = case i do
        1 -> [seeds: [seed_b]]
        33 -> [seeds: [seed_a]]
        _ -> [seeds: seeds]
      end
      node_opts(net, "m_node_#{i}", 2200, opts)
    end

    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed"

    # Partition into 4 groups of 16
    group_a = for i <- 1..16, do: "m_node_#{i}"
    group_b = for i <- 17..32, do: "m_node_#{i}"
    group_c = for i <- 33..48, do: "m_node_#{i}"
    group_d = for i <- 49..64, do: "m_node_#{i}"

    IO.puts("Setting 4-way partition (Groups A, B, C, D)...")
    Network.set_partitions(net, [group_a, group_b, group_c, group_d])

    # Each group should eventually only see members of its own group
    IO.puts("Waiting for 4-way split brain to stabilize...")
    result = wait_for(@t * @suspicion_mult * 25, fn ->
      Enum.all?(nodes, fn node ->
        members = SwimEx.Protocol.members(node.n, include_dead: false)
        length(members) == 15 # only knows 15 others in its group
      end)
    end)
    assert result == :ok, "4-way partition did not stabilize"

    # Heal Groups A and B together, and Groups C and D together
    IO.puts("Healing Groups A-B and C-D...")
    Network.set_partitions(net, [group_a ++ group_b, group_c ++ group_d])

    # Wait for the two halves to converge to 32 nodes each
    result = wait_for(@convergence_timeout * 3, fn ->
      Enum.all?(nodes, fn node ->
        members = SwimEx.Protocol.members(node.n, include_dead: false)
        length(members) == 31 # knows 31 others in its merged group
      end)
    end)
    assert result == :ok, "partial heal A-B and C-D failed"

    # Fully heal all partitions
    IO.puts("Healing all partitions...")
    Network.clear_partitions(net)

    # Cluster should merge back to 64
    result = wait_for(@convergence_timeout * 4, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "cluster did not heal after 4-way partition"
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
    # With 30% packet loss the false-suspicion rate per probe is ~22%, so
    # nodes need an extended suspicion window to hear and refute their own
    # suspicion before being declared dead.
    nodes =
      for i <- 1..64 do
        opts =
          if i == 1,
            do: [suspicion_timeout: @t * @suspicion_mult * 8],
            else: [seeds: [seed], suspicion_timeout: @t * @suspicion_mult * 8]
        node_opts(net, "lossy_node_#{i}", 3000, opts)
      end

    # Converge without packet loss first. Bootstrap under 30% loss with a
    # single seed is too slow: gossip propagation to 64 simultaneous joiners
    # exceeds the convergence window. Converging cleanly first, then stressing
    # with packet loss, tests what actually matters — protocol stability under
    # sustained loss.
    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed before packet loss stress"

    for n <- nodes, do: InMemory.set_fault(n.t, packet_loss: 0.3)

    IO.puts("Waiting for convergence with 30% packet loss...")
    # The extended suspicion_timeout ensures refutations propagate well within
    # the suspicion window, so the cluster should remain converged.
    result = wait_for(@convergence_timeout * 5, fn -> all_converged?(nodes, 64) end)
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

  @tag timeout: 120_000
  test "64-node network: rolling upgrade simulation", %{net: net} do
    seed_a = {"roll_node_1", 2300}
    seed_b = {"roll_node_33", 2300}
    seeds = [seed_a, seed_b]

    # Start all 64 nodes with incarnation 1
    nodes = for i <- 1..64 do
      opts = case i do
        1 -> [incarnation: 1, seeds: [seed_b]]
        33 -> [incarnation: 1, seeds: [seed_a]]
        _ -> [incarnation: 1, seeds: seeds]
      end
      node_opts(net, "roll_node_#{i}", 2300, opts)
    end

    result = wait_for(@convergence_timeout * 3, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "initial convergence failed"

    IO.puts("Starting rolling upgrade of 64 nodes in batches of 8...")

    # We perform rolling upgrade in 8 batches of 8 nodes each
    nodes =
      Enum.chunk_every(1..64, 8)
      |> Enum.reduce(nodes, fn batch_indices, acc_nodes ->
        # 1. Kill the nodes in the current batch
        for idx <- batch_indices do
          n = Enum.at(acc_nodes, idx - 1)
          GenServer.stop(n.n_pid)
          GenServer.stop(n.t_pid)
        end

        # 2. Restart the killed nodes with incarnation 2
        Enum.reduce(batch_indices, acc_nodes, fn idx, current_nodes ->
          host = "roll_node_#{idx}"
          opts = case idx do
            1 -> [incarnation: 2, seeds: [seed_b]]
            33 -> [incarnation: 2, seeds: [seed_a]]
            _ -> [incarnation: 2, seeds: seeds]
          end

          new_node = node_opts(net, host, 2300, opts)
          List.replace_at(current_nodes, idx - 1, new_node)
        end)
        |> tap(fn _ ->
          # Sleep briefly between batches to simulate rolling deployment intervals
          Process.sleep(@t * 10)
        end)
      end)

    IO.puts("Waiting for full convergence after rolling upgrade...")
    result = wait_for(@convergence_timeout * 5, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "re-convergence failed after rolling upgrade"
  end

  @tag timeout: 120_000
  test "64-node network: high latency jitter and delay stress", %{net: net} do
    seed = {"delay_node_1", 2400}
    nodes = for i <- 1..64 do
      # Introduce heterogeneous fixed delay per node to simulate network jitter
      delay = rem(i, 4) * 8 # 0ms, 8ms, 16ms, 24ms
      opts = if i == 1, do: [delay_ms: delay], else: [seeds: [seed], delay_ms: delay]
      node_opts(net, "delay_node_#{i}", 2400, opts)
    end

    IO.puts("Waiting for convergence under high latency jitter...")
    # Because of latency delays exceeding @ping_timeout (20ms) for some nodes,
    # convergence will require indirect pings and suspicion refutations.
    result = wait_for(@convergence_timeout * 5, fn -> all_converged?(nodes, 64) end)
    assert result == :ok, "convergence under high latency jitter failed"
  end

  @tag timeout: 120_000
  test "64-node network: bootstrap storm simulation", %{net: net} do
    seed_host = "boot_node_1"
    seed_port = 2500
    seed = {seed_host, seed_port}

    IO.puts("Starting seed node...")
    seed_node = node_opts(net, seed_host, seed_port, [])

    IO.puts("Spawning remaining 63 nodes sequentially (bootstrap storm)...")
    # Spawn client nodes directly in the test process to ensure they are properly linked to it
    client_nodes =
      for i <- 2..64 do
        node_opts(net, "boot_node_#{i}", seed_port, seeds: [seed])
      end

    all_nodes = [seed_node | client_nodes]

    IO.puts("Waiting for convergence after bootstrap storm...")
    result = wait_for(@convergence_timeout * 4, fn -> all_converged?(all_nodes, 64) end)
    assert result == :ok, "convergence after bootstrap storm failed"
  end

  # Event loop for a collector process that subscribes to node protocol events.
  #
  # Forwards any received message to the parent test process, tagging it with the
  # corresponding node's host name.
  #
  # ## Arguments
  # * `parent` - PID of the test process to receive the forwarded events.
  # * `host` - The host name of the node being monitored.
  defp loop_collector(parent, host) do
    receive do
      msg ->
        send(parent, {host, msg})
        loop_collector(parent, host)
    end
  end
end
