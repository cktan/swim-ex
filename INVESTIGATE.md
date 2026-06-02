# swim-ex — High Effort Code Audit

Findings verified against source on 2026-06-02.

---

## 1. Correctness: The "Zombie" Node (Revival without Gossip)

**File:** `lib/swim_ex/protocol.ex:483-503` (update_node_alive/2)

When a node transitions from `:suspect` or `:dead` back to
`:alive` (e.g., because a `fwd_ack` arrived or the node
restarted with a higher incarnation), `update_node_alive/2`
correctly updates the local membership. However, it only
enqueues an `alive` gossip event if the *previous* status was
not `:alive`.

**The Bug:** If a node is currently `:suspect` locally, and we
receive an `ack` or `fwd_ack` for it, we call
`update_node_alive/2`. It transitions to `:alive` and enqueues
the `alive` event. **But** if other nodes in the cluster
already have this node as `:suspect`, they will keep gossiping
`:suspect` until they hear `:alive`.

If our `alive` gossip event reaches its transmit limit before
all nodes have transitioned back to `:alive`, or if it gets
dropped, some nodes might stay `:suspect` and eventually
transition the node to `:dead` (if the suspicion timer is
local to them).

**Worse:** If we receive a `suspect` event for a node that we
already have as `:suspect` but with a *higher* incarnation,
`Membership.apply_event` updates the incarnation.
`apply_single_event` then calls `start_suspicion_timer` again.
If we then receive an `ack`, we transition to `:alive`.

**Recommended Action:** Increase the transmit multiplier for
self-refutation events (alive events refuting suspect status)
to ensure they spread faster than the suspicions they refute.

---

## 2. Race Condition: Stale Timer firings

**File:** `lib/swim_ex/protocol.ex:168-185`
(`handle_info({:ping_timeout, seq}, ...)` and
`{:indirect_timeout, seq}`)

Timers are started with `Process.send_after(self(),
{:ping_timeout, seq}, ...)`. When an `ack` arrives,
`cancel_pending(seq, state)` calls `Process.cancel_timer(ref)`.

**The Race:** `Process.cancel_timer/1` does not guarantee that
the message isn't already in the mailbox. If the timeout
message is already in the mailbox, `cancel_pending` will
remove the `pending` entry, but the `{:ping_timeout, seq}` or
`{:indirect_timeout, seq}` message will still be processed.

In `handle_info({:ping_timeout, seq}, state)`, there is a
guard:
```elixir
case Map.get(state.pending, seq) do
  {target, _ref, :direct} -> ...
```
This guard *mostly* protects against stale pings because
`cancel_pending` removes the key. However, if a *new* ping
with the *same* `seq` (after wrap-around, though 64-bit ints
make this unlikely) or a delayed message from a previous
state exists, it could cause issues.

**Specific Case:** If `cancel_pending` is called, but the timer
just fired. The message is in the mailbox. `cancel_pending`
finishes. Then `handle_info({:ping_timeout, seq})` runs. It
finds nothing in `pending` and does nothing. This is safe. 

**Wait:** Look at `handle_info({:suspicion_timeout, node},
state)` (line 188):
```elixir
state = Map.update!(state, :suspicion_timers, &Map.delete(&1, node))
case Membership.get(state.membership, node) do
  %{status: :suspect, incarnation: inc} ->
    dead_node(node, inc, state)
```
If `cancel_suspicion_timer` is called but the message is
already in the mailbox, `handle_info` will run. It will check
if the node is still `:suspect`. If it is (maybe it was
re-suspected?), it might kill it prematurely.

**Recommended Action:** Include the incarnation in the
`{:suspicion_timeout, node, incarnation}` message and verify
it matches the node's current incarnation before acting on
the timeout.

---

## 3. Correctness: `next_probe_target` skipping nodes

**File:** `lib/swim_ex/protocol.ex:215-234`

```elixir
[next | rest] ->
  if next in peers do
    {next, %{state | probe_list: rest}}
  else
    # Node left membership; skip and retry
    next_probe_target(%{state | probe_list: rest})
  end
```

If `next` is not in `peers` (meaning it's now `:dead` or
removed), it calls itself recursively. This is fine, but if
the cluster is large and many nodes leave simultaneously, this
could hit a recursion limit (though unlikely for cluster sizes
BEAM handles).

**The bigger issue:** `Enum.shuffle(peers)` is called when
`probe_list` is empty. If `peers` is also empty, it returns
`{nil, state}`. If `peers` has 1 node, it shuffles and picks
it. This is correct round-robin.

**Recommended Action:** Refactor `next_probe_target` to use
`Enum.reject/2` on the `peers` list before shuffling to avoid
recursion, and ensure the `probe_list` is properly managed to
maintain fair round-robin.

---

## 4. Performance: Gossip Packing $O(N^2)$

**File:** `lib/swim_ex/gossip_queue.ex:126-138`

```elixir
defp do_pack([entry | rest], mtu, packed, current_size, n) do
  esize = byte_size(:erlang.term_to_binary(entry.event))
  new_size = if n == 0, do: current_size + 4 + esize, else: current_size + esize - 1
  ...
```

The incremental size calculation is a good optimization, but
`pack_entries` still processes the list linearly. The issue is
that `GossipQueue.pack` is called multiple times per period
(on every ping, ping_req, and ack). If the gossip queue is
large, the constant sorting and packing adds up.

**Recommended Action:** Profile `GossipQueue.pack/2` with large
clusters and, if needed, optimize by maintaining the queue in
a pre-sorted data structure or using a more efficient
packing algorithm.

---

## 5. Potential Leak: Subscriber Monitors

**File:** `lib/swim_ex/protocol.ex:108-111`
(`handle_call({:subscribe, pid}, ...)`), `642-650`
(`remove_subscriber`)

```elixir
defp remove_subscriber(state, pid) do
  case Map.pop(state.subscribers, pid) do
    {nil, _} -> state
    {ref, subscribers} ->
      Process.demonitor(ref, [:flush])
      %{state | subscribers: subscribers}
  end
end
```

The code correctly monitors and demonitors. However, if
`Protocol` crashes and restarts (via Supervisor), the
`subscribers` map is lost. Subscribers will not be
re-registered, and they won't know they need to re-subscribe
unless they also monitor the `Protocol` process.

**Recommended Action:** Add a section to `USAGE.md` explaining
that subscribers must monitor the `Protocol` process and
re-subscribe if it restarts.

---

## 6. Correctness: Incarnation Seeding

**File:** `lib/swim_ex/protocol.ex:94`
`incarnation = System.system_time(:millisecond)`

As noted in `DESIGN.md`, NTP step-back is a risk. Using
`System.system_time` for incarnation is clever but
potentially dangerous if the node crashes and restarts very
quickly while the clock is stepped back.

**Recommended Action:** Combine `System.system_time(:millisecond)`
with a monotonic counter or store the last used incarnation
in an ETS table that survives `Protocol` crashes.

---

## 7. Missing Tests

- **MTU Edge Case:** Test where exactly one more event would
  exceed MTU.
- **Clock Skew:** Integration test with simulated clock
  rollback on one node.
- **Rapid Join/Leave:** Test a node joining and leaving within
  a single `protocol_period`.
- **Packet Reordering:** Test `suspect` arriving *after*
  `alive` for the same incarnation (Membership should handle
  this, but verify).

**Recommended Action:** Create `test/swim_ex/edge_cases_test.exs`
and implement the four listed test scenarios to improve the
suite's robustness.

---

## 8. Potential Uncaught Exceptions

**File:** `lib/swim_ex/codec.ex:32-34` (`decode`)
```elixir
rescue
  _ -> {:error, :invalid}
```
This is safe. However, `:erlang.binary_to_term(bin, [:safe])`
only protects against atom exhaustion. It doesn't protect
against large terms that could cause memory pressure if not
careful (though MTU limits this to 1400 bytes).

**File:** `lib/swim_ex/transport/udp.ex:93` (`ip_to_string`)
```elixir
defp ip_to_string(ip) do
  ip |> :inet.ntoa() |> List.to_string()
end
```
If `:inet.ntoa/1` returns something unexpected, this could
crash the transport. It's unlikely for valid UDP packets.

**Recommended Action:** Add a guard to `ip_to_string/1` to
ensure it only handles valid IP tuples, and add a length
check to `codec.ex` before `binary_to_term/2` to prevent
potential memory exhaustion.

---

## Summary of Correctness Issues

1. **Zombie suspicions**: Revived nodes might not gossip their
   `alive` status long enough to clear all `suspect` states in
   a large cluster.
2. **Suspicion Timer Race**: Stale `suspicion_timeout`
   messages could potentially kill a node that was
   re-suspected but had its *previous* suspicion cancelled.
3. **Round-robin Target Selection**: While mostly correct, it
   relies on `probe_list` which is recalculated every cycle.
   If the membership changes frequently, some nodes might be
   probed more often than others.
