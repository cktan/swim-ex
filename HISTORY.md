# swim-ex — Issue History

Closed issues — fixed or ignored.

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


