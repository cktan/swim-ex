defmodule SwimEx.GossipQueueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwimEx.GossipQueue

  @node_a {"10.0.0.1", 7771}
  @node_b {"10.0.0.2", 7771}
  @node_c {"10.0.0.3", 7771}
  @big_mtu 1400
  @tiny_mtu 64

  # --- Unit tests ---

  test "enqueue adds event" do
    q = GossipQueue.new() |> GossipQueue.enqueue({:alive, @node_a, 1})
    assert GossipQueue.size(q) == 1
  end

  test "higher-incarnation event supersedes lower" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:alive, @node_a, 1})
      |> GossipQueue.enqueue({:alive, @node_a, 2})

    assert GossipQueue.size(q) == 1
    {events, _} = GossipQueue.pack(q, 8, @big_mtu)
    assert [{:alive, @node_a, 2}] = events
  end

  test "lower-incarnation event does not supersede higher" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:alive, @node_a, 5})
      |> GossipQueue.enqueue({:alive, @node_a, 3})

    assert GossipQueue.size(q) == 1
    {events, _} = GossipQueue.pack(q, 8, @big_mtu)
    assert [{:alive, @node_a, 5}] = events
  end

  test "dead supersedes suspect with same incarnation" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:suspect, @node_a, 5})
      |> GossipQueue.enqueue({:dead, @node_a, 5})

    assert GossipQueue.size(q) == 1
    {events, _} = GossipQueue.pack(q, 8, @big_mtu)
    assert [{:dead, @node_a, 5}] = events
  end

  test "alive does not supersede suspect with same incarnation" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:suspect, @node_a, 5})
      |> GossipQueue.enqueue({:alive, @node_a, 5})

    assert GossipQueue.size(q) == 1
    {events, _} = GossipQueue.pack(q, 8, @big_mtu)
    assert [{:suspect, @node_a, 5}] = events
  end

  test "events for different nodes coexist" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:alive, @node_a, 1})
      |> GossipQueue.enqueue({:alive, @node_b, 1})

    assert GossipQueue.size(q) == 2
  end

  test "pack returns events in priority order: dead before suspect before alive" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:alive, @node_a, 1})
      |> GossipQueue.enqueue({:suspect, @node_b, 1})
      |> GossipQueue.enqueue({:dead, @node_c, 1})

    {events, _} = GossipQueue.pack(q, 8, @big_mtu)
    kinds = Enum.map(events, &elem(&1, 0))
    assert kinds == Enum.sort_by(kinds, fn
      :dead -> 0
      :suspect -> 1
      :alive -> 2
    end)
  end

  test "pack respects mtu — stops before overflow" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:alive, @node_a, 1})
      |> GossipQueue.enqueue({:alive, @node_b, 1})
      |> GossipQueue.enqueue({:alive, @node_c, 1})

    {events, _} = GossipQueue.pack(q, 8, @tiny_mtu)
    assert length(events) < 3

    if length(events) > 0 do
      encoded = byte_size(:erlang.term_to_binary(events))
      assert encoded <= @tiny_mtu
    end
  end

  test "pack increments transmit count on packed events" do
    q =
      GossipQueue.new()
      |> GossipQueue.enqueue({:alive, @node_a, 1})

    {_events, q2} = GossipQueue.pack(q, 8, @big_mtu)
    # Pack again — still present but with count 1
    {events2, _q3} = GossipQueue.pack(q2, 8, @big_mtu)
    assert [{:alive, @node_a, 1}] = events2
  end

  test "event dropped from queue after transmit limit reached" do
    n = 1
    limit = GossipQueue.transmit_limit(n)

    q = GossipQueue.new() |> GossipQueue.enqueue({:alive, @node_a, 1})

    final_q =
      Enum.reduce(1..limit, q, fn _, acc ->
        {_, acc} = GossipQueue.pack(acc, n, @big_mtu)
        acc
      end)

    assert GossipQueue.size(final_q) == 0
  end

  test "pack size estimate matches actual encoding across a range of mtus" do
    nodes = for i <- 1..20, do: {"10.0.#{i}.1", 7771}
    q = Enum.reduce(nodes, GossipQueue.new(), fn n, acc ->
      GossipQueue.enqueue(acc, {:alive, n, 1})
    end)

    for mtu <- [60, 100, 200, 500, @big_mtu] do
      {packed, _} = GossipQueue.pack(q, 20, mtu)

      if packed != [] do
        actual = byte_size(:erlang.term_to_binary(packed))
        assert actual <= mtu, "mtu=#{mtu}: packed #{actual} bytes exceeds mtu"
      end
    end
  end

  test "transmit_limit/1 is ceil(log2(N+1))" do
    assert GossipQueue.transmit_limit(0) == 1
    assert GossipQueue.transmit_limit(1) == 1
    assert GossipQueue.transmit_limit(3) == 2
    assert GossipQueue.transmit_limit(7) == 3
    assert GossipQueue.transmit_limit(8) == 4
    assert GossipQueue.transmit_limit(15) == 4
    assert GossipQueue.transmit_limit(16) == 5
  end

  # --- Property tests ---

  defp node_id do
    gen all host <- string(:alphanumeric, min_length: 1, max_length: 8),
            port <- integer(1..9999) do
      {host, port}
    end
  end

  defp event do
    gen all kind <- member_of([:alive, :suspect, :dead]),
            node <- node_id(),
            inc <- integer(0..50) do
      {kind, node, inc}
    end
  end

  property "packed output respects dead > suspect > alive priority" do
    check all events <- list_of(event(), min_length: 1, max_length: 20) do
      q = Enum.reduce(events, GossipQueue.new(), &GossipQueue.enqueue(&2, &1))
      {packed, _} = GossipQueue.pack(q, 20, @big_mtu)

      kinds = Enum.map(packed, fn {k, _, _} -> k end)
      priority_vals = Enum.map(kinds, fn
        :dead -> 0
        :suspect -> 1
        :alive -> 2
      end)

      assert priority_vals == Enum.sort(priority_vals)
    end
  end

  property "packed events always fit within mtu" do
    check all events <- list_of(event(), min_length: 1, max_length: 10),
              mtu <- integer(32..@big_mtu) do
      q = Enum.reduce(events, GossipQueue.new(), &GossipQueue.enqueue(&2, &1))
      {packed, _} = GossipQueue.pack(q, 8, mtu)

      if packed != [] do
        encoded = byte_size(:erlang.term_to_binary(packed))
        assert encoded <= mtu
      end
    end
  end

  property "at most one entry per node in queue" do
    check all events <- list_of(event(), min_length: 1, max_length: 30) do
      q = Enum.reduce(events, GossipQueue.new(), &GossipQueue.enqueue(&2, &1))

      nodes = Enum.map(q.entries, fn e -> elem(e.event, 1) end)
      assert length(nodes) == length(Enum.uniq(nodes))
    end
  end
end
