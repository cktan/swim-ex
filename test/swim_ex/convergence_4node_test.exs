defmodule SwimEx.Convergence4NodeTest do
  @moduledoc """
  Diagnostic test for 4-node join convergence speed.

  Reproduces the distcache ClusterRebalanceTest step 4 scenario using InMemory
  transport at @t=50ms. Measures how many protocol periods elapse between the
  4th node starting and all 4 nodes seeing 4 alive members.

  Interpretation:
  - periods <= 10 : SWIM convergence is fine. Root cause of distcache slowness
                    is protocol_period=1000ms (default) in test_cluster mode.
                    Fix: add `protocol_period: 100` to swim_opts in
                    distcache application.ex:148.
  - periods > 10  : SWIM convergence itself is slow — investigate swim-ex.
  """

  use ExUnit.Case

  alias SwimEx.Transport.InMemory
  alias SwimEx.Transport.InMemory.Network

  @t 50
  @ping_timeout div(@t, 2)
  @suspicion_timeout @t * 5
  @seed_retry @t * 3
  @dead_node_expiry @t * 20

  @port 4100

  defp node_opts(net, host, extra \\ []) do
    tname = :"t_conv_#{host}"
    nname = :"n_conv_#{host}"

    {:ok, _} =
      InMemory.start_link(
        network: net,
        identity: {host, @port, ""},
        name: tname
      )

    {:ok, _} =
      SwimEx.Protocol.start_link(
        Keyword.merge(
          [
            host: host,
            port: @port,
            name: nname,
            transport: tname,
            transport_mod: InMemory,
            protocol_period: @t,
            ping_timeout: @ping_timeout,
            ping_req_fanout: 3,
            suspicion_timeout: @suspicion_timeout,
            seed_retry_interval: @seed_retry,
            dead_node_expiry: @dead_node_expiry
          ],
          extra
        )
      )

    nname
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

  defp all_see_n_peers(names, n) do
    Enum.all?(names, fn name ->
      members = SwimEx.Protocol.members(name, include_dead: false)
      length(members) == n
    end)
  end

  setup do
    {:ok, net} = Network.start_link()
    %{net: net}
  end

  test "4th node joins converged 3-node cluster: measure protocol periods to convergence",
       %{net: net} do
    seed = {"c4_n1", @port}

    n1 = node_opts(net, "c4_n1")
    n2 = node_opts(net, "c4_n2", seeds: [seed])
    n3 = node_opts(net, "c4_n3", seeds: [seed])

    assert :ok = wait_for(@t * 40, fn -> all_see_n_peers([n1, n2, n3], 2) end),
           "3-node cluster did not converge within #{@t * 40}ms"

    t0 = System.monotonic_time(:millisecond)

    n4 = node_opts(net, "c4_n4", seeds: [seed])

    result = wait_for(@t * 60, fn -> all_see_n_peers([n1, n2, n3, n4], 3) end)

    elapsed = System.monotonic_time(:millisecond) - t0
    periods = div(elapsed, @t)

    IO.puts(
      "\n[convergence_4node] 4th node join: #{periods} protocol periods (#{elapsed}ms @ @t=#{@t}ms)"
    )

    if periods <= 10 do
      IO.puts(
        "[convergence_4node] SWIM is fast. Distcache slowness is protocol_period=1000ms (default). " <>
          "Fix: add `protocol_period: 100` to swim_opts in distcache application.ex:148."
      )
    else
      IO.puts(
        "[convergence_4node] #{periods} periods is slow — may indicate a swim-ex convergence issue."
      )
    end

    assert result == :ok,
           "4-node convergence timed out after #{@t * 60}ms"

    assert periods <= 20,
           "4-node convergence took #{periods} protocol periods; expected <= 20. " <>
             "If SWIM itself is fine, fix: add protocol_period: 100 to distcache test_cluster config."
  end
end
