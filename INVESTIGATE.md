# Code Review Findings: swim-ex

Findings verified against source on 2026-06-01.
Status key: ✅ Confirmed · ⚠️ Confirmed with correction · ❌ Not found

---

## 1. ✅ Critical Bug: Missing Target Update on Indirect Ack

**File:** `lib/swim_ex/protocol.ex`

In the SWIM protocol, when a direct `ping` fails, a node sends
`ping_req` to $k$ random peers. If those peers successfully ping
the target, they send back an indirect ack (`fwd_ack` in this
codebase).

While `handle_message/3` for `fwd_ack` correctly cancels the
pending timeout (preventing the node from being marked `:dead`),
it **fails to update the target node's status to `:alive`**.

**Root cause (verified):** In `cancel_pending/2` (line 432), the
relay builds the `fwd_ack` message with its own ID as `source`:

```elixir
# lib/swim_ex/protocol.ex:432
fwd_msg = {:fwd_ack, state.self_id, orig_seq, state.self_id, []}
```

So when the originator handles it (line 401–406), `source` is the
*relay*, not the actual probe target:

```elixir
# lib/swim_ex/protocol.ex:401
defp handle_message({:fwd_ack, from, seq, source, events}, _source_addr, state) do
  state = apply_gossip_events(events, state)
  state = update_node_alive(source, state)  # marks relay alive, not target
  _ = from
  cancel_pending(seq, state)                # cancels timer but doesn't mark target alive
end
```

`cancel_pending/2` for the `:indirect` case (lines 424–428) only
cancels the timer and removes the pending entry — it does not call
`update_node_alive/2` for the target.

**Impact:** If a node was already `:suspect`, an indirect ack
stops it from becoming `:dead`, but it will **not** transition
back to `:alive`. The node stays `:suspect` until a direct `ping`
eventually succeeds or the suspicion timer fires.

---

## 2. ✅ Inefficiency: Gossip Packing Complexity

**File:** `lib/swim_ex/gossip_queue.ex`

The `pack/3` function re-encodes the entire candidate list on
every iteration to check against the MTU:

```elixir
# lib/swim_ex/gossip_queue.ex:124
defp pack_entries([entry | rest], mtu, packed) do
  candidate_events = Enum.map([entry | packed], & &1.event)
  encoded_size = byte_size(:erlang.term_to_binary(candidate_events)) # O(N) on every step

  if encoded_size <= mtu do
    pack_entries(rest, mtu, [entry | packed])
  else
    {packed, [entry | rest]}
  end
end
```

**Impact:** This is $O(N^2)$ where $N$ is the number of events in
the queue. For large clusters with many events, this packing step
(which happens on every protocol period and every ack) will become
increasingly expensive.

---

## 3. ⚠️ Reliability: Graceful Leave

**File:** `lib/swim_ex/protocol.ex`

The `leave/1` function broadcasts a single `dead` announcement
to a small random subset of nodes (lines 342–356):

```elixir
# lib/swim_ex/protocol.ex:342
defp broadcast_dead_self(state) do
  event = {:dead, state.self_id, state.incarnation}
  targets =
    state.membership.members
    |> Enum.filter(fn {_, m} -> m.status in [:alive, :suspect] end)
    |> Enum.map(fn {node, _} -> node end)
    |> Enum.take_random(state.ping_req_fanout)  # Default 3 nodes

  msg = {:ack, state.self_id, 0, [event]}
  case Codec.encode(msg) do
    {:ok, data} -> Enum.each(targets, &transport_send(state, &1, data))
    _ -> :ok
  end
end
```

**Correction to original finding:** The code sends to up to
`ping_req_fanout` (3) nodes, not a single packet. However, each
node receives exactly one UDP datagram with no retry. If all
packets are lost, the cluster waits out the full suspicion
timeout.

**Impact:** No retry mechanism. Packet loss causes the cluster to
treat the departure as a crash rather than a clean leave.

---

## 4. ✅ Bottleneck: Synchronous UDP Transport

**File:** `lib/swim_ex/transport/udp.ex`

The `send/3` operation is a synchronous `GenServer.call`
(line 26):

```elixir
# lib/swim_ex/transport/udp.ex:24
def send(server, {host, port}, data) when is_binary(data) do
  case resolve(host) do
    {:ok, ip} -> GenServer.call(server, {:send, ip, port, data})
    {:error, _} = err -> err
  end
end
```

**Note on impact:** Incoming UDP packets are delivered via
`handle_info`, which queues behind pending `call` requests. The
real bottleneck is that the `Protocol` GenServer blocks during
every send, delaying its own timer and message processing.

**Impact:** Protocol GenServer stalls on every outgoing message
until the UDP GenServer completes the send. Under send-heavy
periods (e.g., indirect ping fanout), timer accuracy degrades.

---

## 5. ✅ Minor: IPv6 Address Representation

**File:** `lib/swim_ex/transport/udp.ex`

The `ip_to_string/1` helper for IPv6 does not use standard
compressed notation (lines 109–114):

```elixir
# lib/swim_ex/transport/udp.ex:109
defp ip_to_string({a, b, c, d, e, f, g, h}) do
  [a, b, c, d, e, f, g, h]
  |> Enum.map(&Integer.to_string(&1, 16))
  |> Enum.map(&String.downcase/1)
  |> Enum.join(":")
end
```

**Impact:** Produces `0:0:0:0:0:0:0:1` instead of `::1`. If
these strings are used for identity comparisons or logging in a
heterogeneous environment, it could cause confusion or matching
failures.

---

## 6. ⚠️ Architecture: Large GenServer

**File:** `lib/swim_ex/protocol.ex`

The `SwimEx.Protocol` module is **658 lines** (original finding
said "over 400" — understated). It mixes protocol state
transitions with GenServer boilerplate, timer management, and
networking calls.

**Recommendation:** Consider separating the protocol logic into a
pure functional state machine (like `SwimEx.Membership`) or using
`gen_statem` to better manage the different protocol states and
timeouts.
