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
          transmit_count: non_neg_integer()
        }

  @type t :: %__MODULE__{entries: [entry()]}
  defstruct entries: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec enqueue(t(), event()) :: t()
  def enqueue(%__MODULE__{} = q, event) do
    p = priority(event)
    node = node_of(event)
    inc = inc_of(event)

    entries =
      case find_existing(q.entries, node) do
        nil ->
          [make_entry(event, p) | q.entries]

        existing ->
          existing_inc = inc_of(existing.event)

          cond do
            inc > existing_inc ->
              [make_entry(event, p) | reject_node(q.entries, node)]

            inc == existing_inc and p < existing.priority ->
              [make_entry(event, p) | reject_node(q.entries, node)]

            true ->
              q.entries
          end
      end

    %{q | entries: entries}
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
    sorted = sort(q.entries)
    {packed_entries, _rest} = pack_entries(sorted, mtu, [])
    packed_set = MapSet.new(packed_entries)

    new_entries =
      Enum.flat_map(sorted, fn entry ->
        if MapSet.member?(packed_set, entry) do
          new_count = entry.transmit_count + 1
          if new_count >= limit, do: [], else: [%{entry | transmit_count: new_count}]
        else
          [entry]
        end
      end)

    packed_events = packed_entries |> Enum.reverse() |> Enum.map(& &1.event)
    {packed_events, %{q | entries: new_entries}}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = q), do: length(q.entries)

  @spec transmit_limit(non_neg_integer()) :: non_neg_integer()
  def transmit_limit(0), do: 1
  def transmit_limit(n), do: ceil(:math.log2(n + 1)) * 3

  # --- Private ---

  defp priority({:dead, _, _}), do: 0
  defp priority({:suspect, _, _}), do: 1
  defp priority({:alive, _, _}), do: 2

  defp node_of({_, node, _}), do: node
  defp inc_of({_, _, inc}), do: inc

  defp make_entry(event, priority) do
    %{event: event, priority: priority, transmit_count: 0}
  end

  defp find_existing(entries, node) do
    Enum.find(entries, fn e -> node_of(e.event) == node end)
  end

  defp reject_node(entries, node) do
    Enum.reject(entries, fn e -> node_of(e.event) == node end)
  end

  defp sort(entries) do
    Enum.sort_by(entries, fn e -> {e.priority, e.transmit_count} end)
  end

  # Greedily pack entries until adding the next would exceed mtu.
  # Tracks encoded list size incrementally (O(N)) instead of re-encoding
  # the full candidate list on every step.
  #
  # ETF list size formula:
  #   empty list  = 2 bytes (version + NIL tag)
  #   first elem  = base + 4 + elem_standalone_size
  #   nth elem    = current + elem_standalone_size - 1
  defp pack_entries(entries, mtu, packed) do
    n = length(packed)
    initial_size =
      if n == 0,
        do: 2,
        else: byte_size(:erlang.term_to_binary(Enum.map(packed, & &1.event)))
    do_pack(entries, mtu, packed, initial_size, n)
  end

  defp do_pack([], _mtu, packed, _size, _n), do: {packed, []}

  defp do_pack([entry | rest], mtu, packed, current_size, n) do
    esize = byte_size(:erlang.term_to_binary(entry.event))
    new_size = if n == 0, do: current_size + 4 + esize, else: current_size + esize - 1

    if new_size <= mtu do
      do_pack(rest, mtu, [entry | packed], new_size, n + 1)
    else
      {packed, [entry | rest]}
    end
  end
end
