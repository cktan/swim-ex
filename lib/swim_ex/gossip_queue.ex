defmodule SwimEx.GossipQueue do
  @moduledoc """
  Priority gossip event queue with transmit-count tracking.

  Events are packed into outgoing messages in priority order:
  dead (0) > suspect (1) > alive (2). Within the same priority,
  events with the lowest transmit count are packed first.

  Transmit multiplier: ceil(log2(N+1)) where N = alive+suspect
  count. Events are dropped once their count reaches the limit.

  Higher-incarnation events for the same node supersede older
  entries immediately on enqueue.
  """

  @type node_id :: {String.t(), :inet.port_number()}
  @type event :: SwimEx.Codec.event()

  @type entry :: %{
          event: event(),
          priority: 0 | 1 | 2,
          transmit_count: non_neg_integer(),
          multiplier: pos_integer()
        }

  @type t :: %__MODULE__{
          by_node: %{node_id() => entry()},
          sorted_keys: term()
        }
  defstruct by_node: %{}, sorted_keys: :gb_sets.new()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec enqueue(t(), event(), pos_integer()) :: t()
  def enqueue(%__MODULE__{} = q, event, multiplier \\ 1) when multiplier > 0 do
    p = priority(event)
    node = node_of(event)
    inc = inc_of(event)

    case Map.get(q.by_node, node) do
      nil ->
        entry = make_entry(event, p, multiplier)

        %{
          q
          | by_node: Map.put(q.by_node, node, entry),
            sorted_keys: :gb_sets.add_element({p, 0, node}, q.sorted_keys)
        }

      existing ->
        existing_inc = inc_of(existing.event)

        cond do
          inc > existing_inc ->
            entry = make_entry(event, p, multiplier)

            %{
              q
              | by_node: Map.put(q.by_node, node, entry),
                sorted_keys:
                  q.sorted_keys
                  |> then(&:gb_sets.delete_any({existing.priority, existing.transmit_count, node}, &1))
                  |> then(&:gb_sets.add_element({p, 0, node}, &1))
            }

          inc == existing_inc and p < existing.priority ->
            effective = max(multiplier, existing.multiplier)
            entry = make_entry(event, p, effective)

            %{
              q
              | by_node: Map.put(q.by_node, node, entry),
                sorted_keys:
                  q.sorted_keys
                  |> then(&:gb_sets.delete_any({existing.priority, existing.transmit_count, node}, &1))
                  |> then(&:gb_sets.add_element({p, 0, node}, &1))
            }

          true ->
            q
        end
    end
  end

  @doc """
  Pack events into a message payload up to `mtu` bytes.
  Returns `{packed_events, updated_queue}`.

  Increments transmit count on packed events and drops those
  that have reached the limit for the given alive+suspect count N.
  """
  @spec pack(t(), non_neg_integer(), non_neg_integer()) :: {[event()], t()}
  def pack(%__MODULE__{} = q, n, mtu) do
    limit = transmit_limit(n)

    {packed_entries, remaining_keys, remaining_by_node} =
      do_collect_pack(q.sorted_keys, q.by_node, mtu, [], 2, 0)

    {final_keys, final_by_node} =
      Enum.reduce(packed_entries, {remaining_keys, remaining_by_node}, fn entry, {keys_acc, nodes_acc} ->
        requeue_after_pack(entry, limit, keys_acc, nodes_acc)
      end)

    packed_events = Enum.map(packed_entries, & &1.event)
    {packed_events, %{q | sorted_keys: final_keys, by_node: final_by_node}}
  end

  defp do_collect_pack(keys, by_node, mtu, packed, current_size, n) do
    case :gb_sets.is_empty(keys) do
      true ->
        {Enum.reverse(packed), keys, by_node}

      false ->
        {key, remaining_keys} = :gb_sets.take_smallest(keys)
        {_p, _tc, node} = key
        entry = Map.fetch!(by_node, node)

        esize = byte_size(:erlang.term_to_binary(entry.event))
        new_size = if n == 0, do: current_size + 4 + esize, else: current_size + esize - 1

        if new_size <= mtu do
          do_collect_pack(remaining_keys, Map.delete(by_node, node), mtu, [entry | packed], new_size, n + 1)
        else
          {Enum.reverse(packed), keys, by_node}
        end
    end
  end

  defp requeue_after_pack(entry, limit, keys, by_node) do
    new_count = entry.transmit_count + 1

    if new_count >= limit * entry.multiplier do
      {keys, by_node}
    else
      new_entry = %{entry | transmit_count: new_count}
      node = node_of(entry.event)
      p = entry.priority

      {
        :gb_sets.add_element({p, new_count, node}, keys),
        Map.put(by_node, node, new_entry)
      }
    end
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = q), do: map_size(q.by_node)

  @doc """
  Returns all entries in the queue in priority order.
  Used primarily for testing and debugging.
  """
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{} = q) do
    q.sorted_keys
    |> :gb_sets.to_list()
    |> Enum.map(fn {_, _, node} -> Map.fetch!(q.by_node, node) end)
  end

  @spec transmit_limit(non_neg_integer()) :: non_neg_integer()
  def transmit_limit(0), do: 1
  def transmit_limit(n), do: ceil(:math.log2(n + 1)) * 3

  # --- Private ---

  defp priority({:dead, _, _}), do: 0
  defp priority({:suspect, _, _}), do: 1
  defp priority({:alive, _, _}), do: 2

  defp node_of({_, node, _}), do: node
  defp inc_of({_, _, inc}), do: inc

  defp make_entry(event, priority, multiplier) do
    %{event: event, priority: priority, transmit_count: 0, multiplier: multiplier}
  end
end
