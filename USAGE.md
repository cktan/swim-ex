# swim_ex Usage Guide

swim_ex implements the SWIM+INF+Susp cluster membership
protocol. Nodes discover each other, detect failures, and
propagate membership changes via gossip over UDP.

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:swim_ex, "~> 0.1"}
  ]
end
```

---

## Quick Start

Add `SwimEx.Supervisor` to your application's supervision
tree. The first node starts alone; subsequent nodes join
by pointing at a known seed.

```elixir
# Node 1 (first node, no seeds)
children = [
  {SwimEx.Supervisor,
   host: "10.0.0.1",
   port: 7771}
]
Supervisor.start_link(children, strategy: :one_for_one)

# Node 2 (joins — all seeds pinged until no longer alone)
children = [
  {SwimEx.Supervisor,
   host: "10.0.0.2",
   port: 7771,
   seeds: [{"10.0.0.1", 7771}, {"10.0.0.3", 7771}]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Join is asynchronous. Membership converges in the
background within a few protocol periods.

---

## Configuration

All options are passed to `SwimEx.Supervisor.start_link/1`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:host` | `String.t()` | **required** | This node's hostname or IP |
| `:port` | `integer` | (req) | UDP port to bind |
| `:cookie` | `string` | `""` | User-defined node cookie |
| `:name` | `atom` | `:swim` | Instance name (for multi-cluster) |

| `:seeds` | `[{host, port}]` | `[]` | Seed nodes for join |
| `:protocol_period` | `ms` | `1000` | How often to probe one peer |
| `:ping_timeout` | `ms` | `200` | Direct ack wait time |
| `:ping_req_fanout` | `integer` | `3` | Indirect ping relay count |
| `:suspicion_timeout` | `ms` | `3000` | Suspect → dead delay |
| `:seed_retry_interval` | `ms` | `5000` | Retry interval if no peers |
| `:dead_node_expiry` | `ms` | `6000` | How long to keep dead entries |

### Tuning for cluster size

The defaults target an 8-node cluster. For larger
clusters, scale timeouts with `log2(N)`:

```elixir
n = 50
{SwimEx.Supervisor,
 host: "10.0.0.1",
 port: 7771,
 protocol_period: 1000,
 suspicion_timeout: ceil(:math.log2(n + 1)) * 1000,
 dead_node_expiry:  ceil(:math.log2(n + 1)) * 2000}
```

---

## API

All functions accept an optional `name` argument (default
`:swim`) to address a named instance.

### Query membership

```elixir
# All alive + suspect nodes (dead filtered by default)
SwimEx.members()
#=> [{"10.0.0.2", 7771, "c1", :alive}, {"10.0.0.3", 7771, "c1", :suspect}]

# Include dead entries (useful for debugging)
SwimEx.members(include_dead: true)
#=> [{"10.0.0.2", 7771, "c1", :alive}, {"10.0.0.4", 7771, "c1", :dead}]

# Named instance
SwimEx.members(:my_cluster)
SwimEx.members(:my_cluster, include_dead: false)
```

Each member is a 4-tuple `{host, port, cookie, status}` where
`host` is the string passed at startup and `status` is
`:alive`, `:suspect`, or `:dead`.

### Subscribe to events

```elixir
SwimEx.subscribe()      # registers self()
SwimEx.unsubscribe()    # deregisters self()

# Named instance
SwimEx.subscribe(:my_cluster)
```

The calling process receives messages:

```elixir
{:swim, :node_up,      {"10.0.0.2", 7771, "c1"}}  # node joined or recovered
{:swim, :node_down,    {"10.0.0.2", 7771, "c1"}}  # node declared dead
{:swim, :node_suspect, {"10.0.0.2", 7771, "c1"}}  # node missed a ping
```

Dead subscriber processes are removed automatically via
`Process.monitor/1`.

### Graceful leave

```elixir
SwimEx.leave()
```

Increments incarnation, broadcasts a dead announcement
directly to `max(⌈N×0.25⌉, 8)` random peers (where `N`
is the number of alive + suspect peers), then stops the
supervisor tree.

For an ungraceful stop (no dead broadcast), call
`Supervisor.stop/1` directly on the supervisor.

---

## Multiple instances

Run two independent SWIM clusters in one BEAM by giving
each a distinct `:name`:

```elixir
children = [
  {SwimEx.Supervisor, name: :cluster_a, host: "10.0.0.1", port: 7771},
  {SwimEx.Supervisor, name: :cluster_b, host: "10.0.0.1", port: 7772}
]

SwimEx.members(:cluster_a)
SwimEx.subscribe(:cluster_b)
```

---

## Telemetry

swim_ex emits the following `:telemetry` events. Attach
handlers using `:telemetry.attach/4`.

### Membership events

```
[:swim, :node, :up]       — node joined or recovered
[:swim, :node, :down]     — node declared dead
[:swim, :node, :suspect]  — node missed a ping
```

Metadata map: `%{node: {host, port}, peer: {host, port}}`
(`node` = this node, `peer` = affected node).

### Metric events

```
[:swim, :ping, :rtt]        — ping round-trip time
[:swim, :cluster, :size]    — current alive+suspect count
[:swim, :message, :dropped] — invalid/undecodable packet
```

`[:swim, :ping, :rtt]` carries `measurements: %{duration: ms}`.
`[:swim, :cluster, :size]` carries `measurements: %{count: n}`.
`[:swim, :message, :dropped]` carries `measurements: %{count: 1}`.

### Example: Prometheus via telemetry_metrics

```elixir
# In your Telemetry supervisor:
def metrics do
  [
    Telemetry.Metrics.counter("swim.node.up.count"),
    Telemetry.Metrics.counter("swim.node.down.count"),
    Telemetry.Metrics.summary("swim.ping.rtt.duration"),
    Telemetry.Metrics.last_value("swim.cluster.size.count")
  ]
end
```

---

## Logger metadata

All protocol log lines include structured metadata:

| Key | Value |
|-----|-------|
| `swim_node` | `{host, port}` — this node |
| `swim_event` | atom — event being logged |
| `swim_peer` | `{host, port}` — peer involved |

Configure a metadata-aware formatter (e.g. `LoggerJSON`)
to expose these fields in structured logs.

---

## Failure detection flow

```
Every protocol_period ms:
  Pick one peer (round-robin, shuffled each cycle)
  Send ping(seq) → wait ping_timeout ms
    ↓ ack received        → peer stays :alive
    ↓ no ack (timeout)
  Send ping_req to k relays → wait ping_timeout ms
    ↓ fwd_ack received    → peer stays :alive
    ↓ no ack (timeout)
  Gossip suspect(peer, inc)
  Start suspicion timer (suspicion_timeout ms)
    ↓ alive(inc > current) received → cancel, stays :alive
    ↓ timer fires
  Gossip dead(peer, inc)
```

A suspected node that receives the suspect gossip
automatically refutes it: it increments its own
incarnation and broadcasts `alive(self, new_inc)`.

---

## Node identity and restarts

A node is identified by `{host, port}`. Identity is
**stable across restarts** — the same address reconnects
as the same logical node. Stale dead events from a
previous incarnation are rejected because the restarted
node seeds its incarnation number from
`System.system_time(:millisecond)`, which is always
higher than any incarnation from the prior run.

> **NTP caveat:** if the system clock steps backward
> (NTP correction) between a crash and restart, the
> node's new incarnation may be lower than the stale
> dead event. Membership recovery is delayed until the
> clock overtakes the old value. Use NTP with `makestep`
> rather than slewing to minimise this window.

---

## Testing

Use `SwimEx.Transport.InMemory` (in `test/support/`) to
run multi-node scenarios in a single BEAM without real
sockets. It supports fault injection for protocol
correctness tests.

```elixir
alias SwimEx.Transport.InMemory
alias SwimEx.Transport.InMemory.Network

setup do
  {:ok, net} = Network.start_link()
  %{net: net}
end

test "two nodes converge", %{net: net} do
  {:ok, t1} = InMemory.start_link(network: net,
                identity: {"n1", 7771}, name: :t1)
  {:ok, _}  = SwimEx.Protocol.start_link(
                host: "n1", port: 7771, name: :n1,
                transport: :t1,
                transport_mod: InMemory,
                protocol_period: 30,
                ping_timeout: 15,
                suspicion_timeout: 90,
                seed_retry_interval: 150,
                dead_node_expiry: 300)

  {:ok, t2} = InMemory.start_link(network: net,
                identity: {"n2", 7771}, name: :t2)
  {:ok, _}  = SwimEx.Protocol.start_link(
                host: "n2", port: 7771, name: :n2,
                transport: :t2,
                transport_mod: InMemory,
                protocol_period: 30,
                ping_timeout: 15,
                suspicion_timeout: 90,
                seed_retry_interval: 150,
                dead_node_expiry: 300,
                seeds: [{"n1", 7771}])

  Process.sleep(300)
  assert [{"n2", 7771, :alive}] = SwimEx.Protocol.members(:n1, [])
end
```

### Fault injection

```elixir
# Drop all outbound packets from t2 (simulate crash)
InMemory.set_fault(t2, packet_loss: 1.0)

# Add 50ms delivery delay
InMemory.set_fault(t2, delay_ms: 50)

# Restore normal operation
InMemory.set_fault(t2, packet_loss: 0.0, delay_ms: 0)
```

---

## Non-goals

swim_ex intentionally does not provide:

- Data replication or CRDTs
- Leader election or distributed locking
- Service discovery beyond cluster membership
- Reliable message delivery
- Cross-datacenter topology awareness
- Polyglot wire compatibility (ETF only)
