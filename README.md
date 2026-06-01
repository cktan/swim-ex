# swim_ex

A SWIM+INF+Susp cluster membership library for Elixir.

Nodes in a cluster automatically discover each other,
detect failures, and converge on a shared view of
membership — all over UDP, with no central coordinator.

```elixir
children = [
  {SwimEx.Supervisor,
   host: "10.0.0.1",
   port: 7771,
   seeds: [{"10.0.0.2", 7771}, {"10.0.0.3", 7771}]}
]

SwimEx.subscribe()
# receives {:swim, :node_up, {"10.0.0.2", 7771}} etc.

SwimEx.members()
#=> [{"10.0.0.2", 7771, :alive}, {"10.0.0.3", 7771, :suspect}]
```

---

## What is SWIM?

SWIM (Scalable Weakly-consistent Infection-style
Membership) is a gossip protocol from a 2002 Cornell
paper. Each node periodically pings one other node. If
the ping fails, it asks a few random nodes to relay an
indirect ping. Only if both fail does the target become
suspect. After a suspicion timeout it is declared dead.

This library implements the SWIM+INF+Susp variant, which
adds:

- **Incarnation numbers** — each node carries a
  monotonically increasing counter. A suspected node
  can refute false positives by broadcasting an alive
  event with a higher incarnation number.
- **Suspicion period** — a configurable delay between
  first suspecting a node and declaring it dead,
  reducing false positives from GC pauses or
  transient packet loss.

---

## Tradeoffs

### SWIM, not Raft or Paxos

swim_ex detects membership changes; it does not provide
consensus, leader election, or reliable delivery. If you
need those, layer them on top with a library such as
Ra. swim_ex's value is low overhead: O(1) messages per
node per period regardless of cluster size.

### ETF wire format

Messages are encoded with `:erlang.term_to_binary/1`.
This is trivially fast in Elixir and requires zero
dependencies, but it means non-BEAM nodes cannot
participate. If polyglot clusters matter, the codec
module is the only place that needs to change.

### UDP, no reliability layer

SWIM is designed for UDP. Occasional dropped messages
are tolerable — the protocol's redundant gossip and
repeated pinging absorb them. Adding TCP would reduce
false positives in pathological networks but defeats
much of SWIM's simplicity. The tradeoff is documented;
Lifeguard extensions (Hashicorp's local health
multiplier) were deliberately excluded to keep the
implementation small.

### Stable identity, time-seeded incarnation

A node's identity is its `{host, port}` pair, stable
across restarts. On each startup, the incarnation
number is seeded from `System.system_time(:millisecond)`
so a restarted node can always override stale dead
events from its previous life — without needing a
persistent incarnation counter on disk. The caveat:
a large NTP step-back in the window between crash and
restart can delay re-joining. See DESIGN.md §9 for the
full analysis.

### Pure functional core

The membership state machine (`SwimEx.Membership`) and
gossip queue (`SwimEx.GossipQueue`) are pure functions
over immutable structs. `SwimEx.Protocol` is a thin
GenServer shell that owns timers and sockets and
delegates all state transitions to those modules. This
separation makes the protocol logic testable without
starting any processes, and makes the StreamData
property tests possible.

### In-memory transport for tests

The production transport is UDP only. An
`SwimEx.Transport.InMemory` implementation lives in
`test/support/` and is not part of the public API. It
lets integration tests inject packet loss, delay, and
reorder without any real sockets. A shared
`Network` process acts as the routing hub between
in-memory nodes.

---

## Status

Early release. The protocol implementation is complete
and tested, but the library has not been run in
production. Bug reports and pull requests welcome.

**Tested on:** Elixir 1.15 / OTP 26.

---

## Documentation

- **[USAGE.md](USAGE.md)** — installation, configuration
  reference, API, telemetry, and testing guide
- **[DESIGN.md](DESIGN.md)** — full design decisions and
  rationale, including every tradeoff answered before
  the first line of code was written

---

## License

MIT. See [LICENSE](LICENSE).
