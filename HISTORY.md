# swim-ex — Issue History

Closed issues — fixed or ignored.

---

## ISSUE 14 :: Memory leak in SwimEx.Protocol: relay_to pending entries not cleaned up on ping timeout
**Decision:** fixed — 2026-06-03

**Problem:** In handle_info({:ping_timeout, seq}, state), only :direct ping entries are removed from state.pending. Entries of the form {:relay_to, from, seq} added by handle_message({:ping_req, ...}) are never removed if no ack arrives, causing the pending map to grow without bound.

**Solution:** Updated handle_info({:ping_timeout, seq}, state) to remove {:relay_to, ...} entries from state.pending. Also updated handle_info({:indirect_timeout, seq}, state) to delete entries from state.ping_times. Added regression tests in test/swim_ex/repro_issue_14_test.exs.

---


## ISSUE 13 :: No runtime guard prevents multiplier=0 in GossipQueue.enqueue
**Decision:** fixed — 2026-06-02

**Problem:** The @spec for enqueue/3 documents multiplier as pos_integer() but Elixir specs are not enforced at runtime. If multiplier=0 is passed, limit * 0 = 0 and new_count >= 0 is always true, so every entry is immediately evicted on its first pack without ever being transmitted to any peer. Current callers only pass the literal constant @refutation_multiplier=2 or the default 1, so this is not reachable today, but there is no guard preventing a future caller from computing a zero multiplier via arithmetic.

**Solution:** Added when multiplier > 0 guard to GossipQueue.enqueue/3, enforcing the pos_integer() type spec at runtime. Merged in commit af08479.

---


## ISSUE 12 :: Refutation-multiplier rule duplicated across three Protocol call sites
**Decision:** fixed — 2026-06-02

**Problem:** The decision to use @refutation_multiplier for alive gossip is independently reimplemented in three separate functions: update_node_alive/2 (~line 480), apply_single_event/2 non-self path (~line 559), and apply_single_event/2 self-refutation path (~line 596). Each carries its own inline condition. A future alive-enqueue call site added without consulting all three will silently use multiplier=1, reproducing the original zombie-revival bug.

**Solution:** Extracted enqueue_gossip/3 helper in protocol.ex centralizing the refutation-multiplier decision. No behavioral change. Merged in commit 6c0b6e8.

---


## ISSUE 11 :: transmit_limit(0) special case violated by multiplier>1
**Decision:** ignored — 2026-06-02

**Problem:** transmit_limit(0) returns 1 as a special-case minimum, intended to cap entries to a single transmit in zero-member clusters. The new eviction condition (new_count >= limit * entry.multiplier) means a refutation entry with multiplier=2 survives two packs instead of one when n=0, silently overriding the cap. There is no guard in pack/3 preventing it from being called with n=0.

**Solution:** The described behaviour is correct and intentional. transmit_limit(0)=1 is a floor to avoid a zero-transmit degenerate case, not a cap on urgency multipliers. Clamping to limit at N=0 would silently revert the issue7 packet-loss protection (startup self-alive enqueued with @refutation_multiplier=2 to survive 2 seed ping attempts). Branch wip/issue11 not merged.

---


## ISSUE 9 :: Document subscriber re-subscription requirement after Protocol restart
**Decision:** fixed — 2026-06-02

**Problem:** If the Protocol process crashes and is restarted by its supervisor, the subscribers map is lost. Existing subscribers receive no notification and their monitors on the Protocol pid become stale. There is no guidance in USAGE.md about this behaviour.

**Solution:** Added explanation to USAGE.md restart caveat: subscription list is held in process state and lost on restart; existing subscribers receive no notification other than their own monitors. Added comment in protocol.ex pointing to the caveat. Merged in commit e6772f4.

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


