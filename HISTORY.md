# swim-ex — Issue History

Closed issues — fixed or ignored.

---

## ISSUE 8 :: GossipQueue.pack/2 called on every message; profile for large clusters
**Decision:** fixed — 2026-06-02

**Problem:** pack_entries/5 iterates the gossip queue linearly on every outbound ping, ping_req, and ack. In large clusters with high event throughput the repeated linear scan plus sort adds constant overhead that grows with queue depth. No profiling data exists to quantify the impact.

**Solution:** Refactored GossipQueue from flat list to {by_node: map, sorted_keys: :gb_sets} dual structure. enqueue is O(log N), pack is O(k log N), size is O(1). Added entries/1 for testing. Added test covering enqueue-after-pack supersede path. Merged in commit bc3c3d2.

---


## ISSUE 7 :: Add edge-case tests: MTU boundary, clock skew, rapid join/leave, packet reorder
**Decision:** fixed — 2026-06-02

**Problem:** The test suite lacks coverage for four scenarios: (1) gossip pack where exactly one more event would exceed MTU; (2) integration test with simulated NTP clock rollback on one node; (3) a node joining and leaving within a single protocol_period; (4) a suspect event arriving after an alive event for the same incarnation (Membership should drop it, but this is unverified).

**Solution:** Fixed: edge-case tests added (MTU boundary, clock-skew lower-inc rejection, rapid join/leave, packet reorder) plus protocol robustness fixes (startup self-alive gossip, dead-node revival guard). Merged in commit 67ab39f.

---


## ISSUE 6 :: next_probe_target: replace tail-recursion skip with Enum.reject for fairness
**Decision:** fixed — 2026-06-02

**Problem:** next_probe_target/1 skips dead/removed nodes via tail recursion. In steady state this is fine, but under heavy churn it can skip many entries before finding a live node, and the shuffle that follows always uses the full peer list rather than filtering first, meaning probe_list may diverge from membership more than necessary.

**Solution:** Replaced tail-recursive skip loop with upfront Enum.reject using a MapSet of current peers, keeping probe_list consistent with membership in O(n). Merged in commit b5cd708.

---


## ISSUE 10 :: start_suspicion_timer does not refresh timer when incarnation advances while a timer is pending
**Decision:** fixed — 2026-06-02

**Problem:** When suspect(N, inc2) arrives before alive(N, inc2) clears the inc1 timer, start_suspicion_timer sees Map.has_key?(timers, N) is true and skips scheduling. The inc1 timer fires and is discarded (incarnation mismatch), leaving N permanently :suspect at inc2 on that observer until dead(N,...) gossip arrives from peers or N is suspected again at a higher incarnation.

**Solution:** Store {ref, inc} in suspicion_timers instead of bare ref. In start_suspicion_timer, cancel+replace the existing timer when the stored incarnation differs from the node's current incarnation. Update cancel_suspicion_timer and handle_info to handle {ref, inc} tuple and safely delete only when incarnations match.

---

## ISSUE 4 :: Suspicion timer race: stale suspicion_timeout can kill re-suspected node
**Decision:** fixed — 2026-06-02

**Problem:** Process.cancel_timer/1 does not guarantee the message is not already in the mailbox. If a suspicion_timeout fires just as cancel_suspicion_timer runs, handle_info({:suspicion_timeout, node}) will execute, check if the node is still :suspect, and may call dead_node prematurely — even if the node was re-suspected at a higher incarnation whose new timer has not yet fired.

**Solution:** Include incarnation in :suspicion_timeout message and verify it in handle_info before marking node dead. Updated Membership.list/2 and all tests to include incarnation field.

---


## ISSUE 3 :: Zombie node revival: alive gossip may not outpace suspect gossip
**Decision:** fixed — 2026-06-02

**Problem:** When a node transitions from :suspect back to :alive, update_node_alive/2 enqueues one alive gossip event at the default transmit limit. If suspect gossip from other nodes reaches its transmit limit after the alive event is exhausted, some peers may never converge back to :alive and will eventually fire their local suspicion timer, falsely declaring the node dead.

**Solution:** Introduced a `multiplier` to `GossipQueue` entries. Updated `Protocol` to use a `@refutation_multiplier` of 2 for `alive` events that refute a `suspect` or `dead` status, ensuring they propagate further than standard gossip and have a better chance of reaching all nodes despite "competing" suspect gossip.

---


## ISSUE 5 :: Incarnation seeding via system_time unsafe under NTP step-back
**Decision:** ignored — 2026-06-02

**Problem:** Protocol seeds the local node's incarnation with System.system_time(:millisecond). If the node crashes and restarts quickly while NTP steps the clock back, the new incarnation may be <= the old one, causing every other node to ignore the restarting node's alive events (they expect a strictly higher incarnation). This is already flagged in DESIGN.md but has no code-level mitigation.

**Solution:** Won't fix: we don't want an ETS table for reincarnation number.

---


## ISSUE 2 :: Protocol correctness and transport improvements
**Decision:** fixed — 2026-06-02

**Problem:** 
1. `Membership.list/2` defaulted to including dead nodes, contrary to documentation.
2. Nodes did not refute `dead` events about themselves (only `suspect`).
3. DNS resolution in the UDP transport blocked the main protocol logic.
4. Redundant membership updates on indirect acks.

**Solution:**
1. Updated `Membership.list/2` default `include_dead` to `false`.
2. Added self-refutation for `dead` events in `Protocol.apply_single_event/2`.
3. Moved DNS resolution to `UDP` transport's `handle_cast/2` to avoid blocking the `Protocol` GenServer.
4. Removed redundant `update_node_alive/2` call in `Protocol.handle_message({:fwd_ack, ...})`.
5. Added regression test for `dead` event self-refutation.

---

## ISSUE 1 :: Missing gossip piggybacking in relay messages
**Decision:** fixed — 2026-06-02

**Problem:** Relay pings (sent in response to ping_req) and fwd_acks (sent back to original sender) currently carry empty event lists, missing opportunities for gossip dissemination.

**Solution:** Updated handle_message({:ping_req, ...}) and cancel_pending to use GossipQueue.pack, ensuring relay pings and fwd_acks carry gossip events. Also introduced @mtu_margin (128 bytes) to all pack calls to prevent messages from exceeding the 1400-byte MTU due to header overhead.

---


