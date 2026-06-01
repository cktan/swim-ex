# swim_ex — Design Specification

All decisions below are locked. See `t` for the original
questionnaire. Changes require explicit revision here first.

---

## 1. Project Identity

- **Package name:** `swim_ex`
- **Hex:** public
- **License:** MIT
- **Elixir/OTP floor:** Elixir 1.15 / OTP 26

---

## 2. Protocol

- **Variant:** SWIM+INF+Susp (incarnation numbers +
  suspicion period before declaring dead)
- **Lifeguard extensions:** out of scope

### Failure detection flow

```
A → B        ping(seq)
# no ack within ping_timeout

A → [C,D,E]  ping_req(seq, target=B)
C → B        ping(seq, relay_to=A)
B → C        ack(seq)
C → A        ack(seq, from=B)

# if still no ack after suspicion_timeout:
A gossips    suspect(B, inc)
```

- Relay ack refutes a suspect immediately, even if
  the suspect timer has already fired.
- A node that receives `suspect(self, inc)` where
  `inc >= own_incarnation` auto-refutes: increments
  incarnation and broadcasts `alive(self, new_inc)`.
  This is transparent to the caller.

---

## 3. Node Identity

- **Wire and API type:** plain 3-tuple `{"host", port, "cookie"}`
  - `host` is a string (IP address or hostname)
  - `port` is an integer
  - `cookie` is a string (user-defined opaque datum). It is optionally specified by the user, defaulting to `""`.
- **Identity key:** the full `{"host", port, "cookie"}` tuple
- **Assigned by:** caller
- **Stability:** stable across restarts (same tuple, new incarnation number). A change in cookie signifies a different node instance even if host/port are reused.

### Node Identification with Cookie

While a node is reachable via its network location (`host` and `port`), the protocol incorporates a `cookie` into the node's strict identity (`{host, port, cookie}`). This cookie allows the application to distinguish between different instances, sessions, or restarts of a node running on the exact same host and port. 

The cookie is optionally specified by the user during node startup or when defining seeds. If not explicitly provided, it defaults to the empty string `""`.

---

## 4. Transport

- **Protocol:** UDP only
- **IP versions:** IPv4 + IPv6
- **Port:** 7771 (default, configurable)
- **MTU:** 1400 bytes (conservative, safe everywhere)
- **Overflow behaviour:** return error — caller
  re-encodes with fewer piggyback events
- **Internal abstraction:** `SWIM.Transport` behaviour
  with a UDP implementation shipped. An `InMemory`
  implementation lives in `test/support/` only and is
  not part of the public API. This boundary allows
  fault injection (packet loss, delay, reorder) in
  tests without exposing a pluggable transport
  contract to callers.

---

## 5. Wire Encoding

- **Format:** ETF (`:erlang.term_to_binary/1`)
- Not polyglot — acceptable for a BEAM-only library.
- **Message shape:**

```elixir
# ping
{:ping, sender :: {host, port}, seq :: non_neg_integer,
        events :: [event]}

# ack
{:ack, sender :: {host, port}, seq :: non_neg_integer,
       events :: [event]}

# ping_req (A asks C to ping B)
{:ping_req, sender :: {host, port}, seq :: non_neg_integer,
            target :: {host, port}, events :: [event]}

# forwarded ack (C tells A that B responded)
{:fwd_ack, sender :: {host, port}, seq :: non_neg_integer,
           source :: {host, port}, events :: [event]}
```

- **Event shape:**

```elixir
{:alive,   {host, port}, incarnation :: non_neg_integer}
{:suspect, {host, port}, incarnation :: non_neg_integer}
{:dead,    {host, port}, incarnation :: non_neg_integer}
```

---

## 6. Security

None. Trust the network (VPC / firewall handles
perimeter). ETF deserialization is safe here because
only trusted cluster nodes communicate on the gossip
port.

---

## 7. Failure Detection Parameters

All parameters are runtime-configurable via start
opts. Defaults are tuned for an 8-node cluster.

| Parameter | Default | Formula / notes |
|-----------|---------|-----------------|
| `protocol_period` | 1000 ms | `T` |
| `ping_timeout` | 200 ms | `T / 5` |
| `ping_req_fanout` | 3 | paper default; `k` |
| `suspicion_timeout` | 3000 ms | `log2(N) × T` at N=8 |
| `seed_retry_interval` | 5000 ms | fixed, not exponential |
| `dead_node_expiry` | 6000 ms | `2 × suspicion_timeout` |

---

## 8. Dissemination

- **Transmit multiplier:** `ceil(log₂(N+1)) × 3` where
  `N` = count of alive + suspect nodes. Recalculated
  dynamically as membership changes.
- **Piggyback budget:** fill up to MTU (1400 bytes)
  per outgoing message.
- **Event types:** `:alive`, `:suspect`, `:dead`.
  No user-defined event type.
- **Priority ordering:** dead → suspect → alive.
  Within the same priority, events with the lowest
  transmit count are packed first.
- **Supersession:** when a higher-incarnation event
  for the same node arrives, the old event is replaced
  in the queue immediately.
- **Expiry:** events are dropped from the queue once
  their transmit count reaches the current multiplier.

---

## 9. Membership State Machine

```
         ping timeout
alive ──────────────────► suspect
  ▲                           │
  │ alive(inc > current)      │ suspicion_timeout
  │                           ▼
  └─────────────────────── dead
```

- **States:** `:alive`, `:suspect`, `:dead`
- **Graceful leave:** treated as `:dead`
  (no separate `:left` state)
- **Incarnation numbers:** always included.
  Seeded at startup with `System.system_time(:millisecond)`.

> **Caveat:** if the system clock steps backward
> (NTP correction) between a node's death and its
> restart, the restarted node's incarnation may be
> lower than the stale dead event. The cluster will
> ignore its alive announcements until the incarnation
> value overtakes the stale one. This window is
> typically milliseconds. Mitigate by ensuring NTP
> is configured with `makestep` rather than slewing.

- **Dead node GC:** dead entries are retained
  internally for `dead_node_expiry` (default 6000 ms)
  to reject stale alive events. After expiry a
  rejoining node with the same identity is treated as
  a fresh member.

---

## 10. Bootstrap / Join

- **Discovery:** caller provides a seed node list.
- **Seed unreachable:** start as a single-node
  cluster and retry seeds every `seed_retry_interval`
  (default 5000 ms, fixed interval).
- **Join mode:** async — the supervisor starts
  immediately and membership converges in the
  background.

---

## 11. API

### Supervision

```elixir
# Add to your supervision tree:
{SWIM.Supervisor, [
  host: "10.0.0.1",          # required
  port: 7771,                 # required
  name: :my_cluster,          # optional, default :swim
  seeds: [{"10.0.0.2", 7771}],
  protocol_period: 1000,
  ping_timeout: 200,
  ping_req_fanout: 3,
  suspicion_timeout: 3000,
  seed_retry_interval: 5000,
  dead_node_expiry: 6000
]}
```

All functions accept an optional `name` argument
(default `:swim`) to target a named instance.

### Querying membership

```elixir
SWIM.members(name \\ :swim, opts \\ [])
# opts: [include_dead: true]  ← default true
# returns: [{"host", port, "cookie", :alive | :suspect | :dead}]
```

### Event subscription

```elixir
SWIM.subscribe(name \\ :swim)    # registers self()
SWIM.unsubscribe(name \\ :swim)  # deregisters self()
```

Messages delivered to the subscriber process:

```elixir
{:swim, :node_up,      {"host", port, "cookie"}}
{:swim, :node_down,    {"host", port, "cookie"}}
{:swim, :node_suspect, {"host", port, "cookie"}}
```

The library monitors each subscriber via
`Process.monitor/1` and removes it automatically
on `:DOWN`.

### Graceful leave

```elixir
SWIM.leave(name \\ :swim)
```

1. Increments own incarnation number.
2. Broadcasts `dead(self, new_inc)` directly to
   `max(⌈N×0.25⌉, 8)` random peers (not via gossip
   queue), where `N` is the number of alive + suspect
   peers.
3. Stops the supervisor tree.

For a silent stop (no dead broadcast), call
`Supervisor.stop/1` directly.

---

## 12. Observability

### Telemetry events

**Membership transitions:**

```elixir
[:swim, :node, :up]      # %{node: {"host", port, "cookie"}}
[:swim, :node, :down]    # %{node: {"host", port, "cookie"}}
[:swim, :node, :suspect] # %{node: {"host", port, "cookie"}}
```

**Metrics:**

```elixir
[:swim, :ping, :rtt]         # measurements: %{duration: ms}
[:swim, :cluster, :size]     # measurements: %{count: n}
[:swim, :message, :dropped]  # measurements: %{count: 1}
```

### Logger metadata

Set on all protocol log lines:

```elixir
[
  swim_node:  {"host", port, "cookie"},  # this node
  swim_event: :suspect,        # event being processed
  swim_peer:  {"host", port, "cookie"}   # peer involved, when relevant
]
```

---

## 13. Ping Target Selection

Each protocol period, the node picks one peer to
ping using **round-robin with periodic shuffle**:
the member list is shuffled when exhausted, then
iterated in order. This bounds detection latency
to `(N-1) × T` in the worst case, avoiding the
unlucky streaks possible with pure random selection.

---

## 14. Testing Strategy

- **Unit tests:** encode/decode roundtrip, state
  machine transitions, gossip queue ordering.
- **Integration tests:** multiple SWIM instances
  in the same BEAM on different ports.
- **Simulated network:** `SWIM.Transport.InMemory`
  (test-only) supports injecting packet loss, delay,
  and reorder for protocol correctness tests.
- **Property tests (StreamData):**
  1. Encoding roundtrip: `∀ msg → encode → decode = msg`
  2. State machine: no invalid transitions regardless
     of event sequence and incarnation values
  3. Gossip queue: packed output always respects
     dead > suspect > alive priority regardless of
     insertion order
- **CI:** no GitHub Actions; run locally with `mix test`.

---

## 15. Non-Goals

- Data replication / CRDTs
- Leader election
- Distributed locking
- Service discovery beyond membership
- Reliable message delivery
- Cross-datacenter topology awareness
- Lifeguard / local health multiplier
- Pluggable public transport API
- Polyglot wire compatibility
