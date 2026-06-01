defmodule SwimEx.MembershipTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwimEx.Membership

  @node_a {"10.0.0.1", 7771, ""}
  @node_b {"10.0.0.2", 7771, ""}

  # --- Generators ---

  defp node_id do
    gen all host <- string(:alphanumeric, min_length: 1, max_length: 10),
            port <- integer(1..65535),
            cookie <- string(:alphanumeric, max_length: 5) do
      {host, port, cookie}
    end
  end

  defp incarnation, do: integer(0..100)

  defp event do
    gen all kind <- member_of([:alive, :suspect, :dead]),
            node <- node_id(),
            inc <- incarnation() do
      {kind, node, inc}
    end
  end

  # --- Unit tests ---

  test "new node added via add/3 is alive" do
    state = Membership.new() |> Membership.add(@node_a, 1)
    assert %{status: :alive, incarnation: 1} = Membership.get(state, @node_a)
  end

  test "alive event adds unknown node" do
    state = Membership.new() |> Membership.apply_event({:alive, @node_a, 5})
    assert %{status: :alive, incarnation: 5} = Membership.get(state, @node_a)
  end

  test "alive with lower inc rejected" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 10)
      |> Membership.apply_event({:alive, @node_a, 5})

    assert %{incarnation: 10} = Membership.get(state, @node_a)
  end

  test "alive with same inc rejected (no churn from duplicates)" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 10)
      |> Membership.apply_event({:alive, @node_a, 10})

    assert %{status: :alive, incarnation: 10} = Membership.get(state, @node_a)
  end

  test "alive with higher inc updates alive node" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 10)
      |> Membership.apply_event({:alive, @node_a, 11})

    assert %{status: :alive, incarnation: 11} = Membership.get(state, @node_a)
  end

  test "suspect transitions alive node" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 5)
      |> Membership.apply_event({:suspect, @node_a, 5})

    assert %{status: :suspect, incarnation: 5} = Membership.get(state, @node_a)
  end

  test "suspect with lower inc rejected" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 10)
      |> Membership.apply_event({:suspect, @node_a, 9})

    assert %{status: :alive} = Membership.get(state, @node_a)
  end

  test "suspect on unknown node ignored" do
    state = Membership.new() |> Membership.apply_event({:suspect, @node_a, 1})
    assert nil == Membership.get(state, @node_a)
  end

  test "dead transitions alive node" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 5)
      |> Membership.apply_event({:dead, @node_a, 5})

    assert %{status: :dead} = Membership.get(state, @node_a)
  end

  test "dead on unknown node ignored" do
    state = Membership.new() |> Membership.apply_event({:dead, @node_a, 1})
    assert nil == Membership.get(state, @node_a)
  end

  test "dead is final — suspect ignored after dead" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 5)
      |> Membership.apply_event({:dead, @node_a, 5})
      |> Membership.apply_event({:suspect, @node_a, 99})

    assert %{status: :dead} = Membership.get(state, @node_a)
  end

  test "dead is final — alive with same inc rejected after dead" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 5)
      |> Membership.apply_event({:dead, @node_a, 5})
      |> Membership.apply_event({:alive, @node_a, 5})

    assert %{status: :dead} = Membership.get(state, @node_a)
  end

  test "dead node revived by higher-incarnation alive (restart)" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 5)
      |> Membership.apply_event({:dead, @node_a, 5})
      |> Membership.apply_event({:alive, @node_a, 100})

    assert %{status: :alive, incarnation: 100} = Membership.get(state, @node_a)
  end

  test "self-refutation: alive(inc+1) overrides suspect(inc)" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 5)
      |> Membership.apply_event({:suspect, @node_a, 5})
      |> Membership.apply_event({:alive, @node_a, 6})

    assert %{status: :alive, incarnation: 6} = Membership.get(state, @node_a)
  end

  test "gc removes expired dead entries" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 1)
      |> Membership.apply_event({:dead, @node_a, 1})

    # Wait past expiry
    Process.sleep(10)
    state = Membership.gc(state, 5)
    assert nil == Membership.get(state, @node_a)
  end

  test "gc retains recent dead entries" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 1)
      |> Membership.apply_event({:dead, @node_a, 1})

    state = Membership.gc(state, 60_000)
    assert %{status: :dead} = Membership.get(state, @node_a)
  end

  test "member_count excludes dead nodes" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 1)
      |> Membership.add(@node_b, 1)
      |> Membership.apply_event({:dead, @node_a, 1})

    assert Membership.member_count(state) == 1
  end

  test "list/2 include_dead: false filters dead" do
    state =
      Membership.new()
      |> Membership.add(@node_a, 1)
      |> Membership.add(@node_b, 1)
      |> Membership.apply_event({:dead, @node_a, 1})

    result = Membership.list(state, include_dead: false)
    assert length(result) == 1
    assert {"10.0.0.2", 7771, "", :alive} in result
  end

  # --- Property tests ---

  property "no invalid status transitions from any event sequence" do
    check all node <- node_id(),
              events <- list_of(event(), max_length: 20) do
      state = Membership.new() |> Membership.add(node, 0)

      final =
        Enum.reduce(events, state, fn ev, acc ->
          Membership.apply_event(acc, ev)
        end)

      case Membership.get(final, node) do
        nil ->
          # node was evicted somehow — should not happen (add sets it, no remove)
          flunk("node disappeared from membership")

        %{status: status} ->
          assert status in [:alive, :suspect, :dead]
      end
    end
  end

  property "incarnation never decreases within a status" do
    check all node <- node_id(),
              incs <- list_of(incarnation(), min_length: 1, max_length: 20) do
      state = Membership.new() |> Membership.add(node, 0)

      {final, _max_seen} =
        Enum.reduce(incs, {state, 0}, fn inc, {acc, max_inc} ->
          new_acc = Membership.apply_event(acc, {:alive, node, inc})
          member = Membership.get(new_acc, node)
          new_max = max(max_inc, inc)

          if member.status == :alive do
            # incarnation must be >= previous max applied alive inc
            assert member.incarnation >= max_inc
          end

          {new_acc, new_max}
        end)

      _ = final
      :ok
    end
  end

  property "dead is absorbing for suspect events" do
    check all node <- node_id(),
              dead_inc <- incarnation(),
              suspect_incs <- list_of(incarnation(), max_length: 10) do
      state =
        Membership.new()
        |> Membership.add(node, dead_inc)
        |> Membership.apply_event({:dead, node, dead_inc})

      final =
        Enum.reduce(suspect_incs, state, fn inc, acc ->
          Membership.apply_event(acc, {:suspect, node, inc})
        end)

      assert %{status: :dead} = Membership.get(final, node)
    end
  end
end
