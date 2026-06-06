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
by pointing at one or more known seeds.

```elixir
# Node 7, join via seeds at 10.0.0.1 and 10.0.0.2 
children = [
  {SwimEx.Supervisor,
   host: "10.0.0.7",
   port: 7771,
   seeds:[{"10.0.0.1", 7771}, {"10.0.0.2", 7771}]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Join is asynchronous. Membership converges in the
background within a few protocol periods.


## Node identity

Each node is identified by a 3-tuple `{host, port, cookie}`.
`host` and `port` are required. `cookie` is a user-defined
string (default `""`) that can be used to logically
distinguish clusters sharing the same network.

---

### Handle events

Subscribe to membership changes to react when nodes join or leave.

```elixir
# Subscribe the current process
SwimEx.subscribe()

# Handle notifications in your process loop
receive do
  {:swim, :node_up, {host, port, _cookie}} ->
    IO.puts("Node joined: #{host}:#{port}")

  {:swim, :node_down, {host, port, _cookie}} ->
    IO.puts("Node left: #{host}:#{port}")
end
```

Alternatively, attach a **Telemetry** handler for global
logging or metrics:

```elixir
:telemetry.attach(
  "my-handler",
  [:swim, :node, :up],
  fn _name, _measurements, metadata, _config ->
    {host, port, _} = metadata.peer
    IO.puts("Telemetry: Node up #{host}:#{port}")
  end,
  nil
)
```

---

## Configuration

All options are passed to `SwimEx.Supervisor.start_link/1`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:host` | `String.t()` | **required** | This node's hostname or IP |
| `:port` | `integer` | (req) | UDP port to bind |
| `:cookie` | `string` | `""` | User-defined node cookie |
| `:name` | `atom` | `:swim` | Instance name (for multi-cluster) |

| `:seeds` | `[{host, port} \| {host, port, cookie}]` | `[]` | Seed nodes for join |
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

These functions accept an optional `name` argument (default
`:swim`) to address a named instance:

- `SwimEx.members/0,1,2`
- `SwimEx.subscribe/0,1`
- `SwimEx.unsubscribe/0,1`
- `SwimEx.leave/0,1`

### Query membership

```elixir
# All alive + suspect nodes (dead filtered by default)
SwimEx.members()
#=> [{"10.0.0.2", 7771, "c1", :alive, 3}, {"10.0.0.3", 7771, "c1", :suspect, 1}]

# Include dead entries (useful for debugging)
SwimEx.members(include_dead: true)
#=> [{"10.0.0.2", 7771, "c1", :alive, 3}, {"10.0.0.4", 7771, "c1", :dead, 2}]

# Named instance
SwimEx.members(:my_cluster)
SwimEx.members(:my_cluster, include_dead: false)
```

Each member is a 5-tuple `{host, port, cookie, status, incarnation}`
where `host` is the string passed at startup, `status` is
`:alive`, `:suspect`, or `:dead`, and `incarnation` is the
node's current incarnation number.

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

> **Restart caveat:** if the `Protocol` process crashes and is
> restarted by its supervisor, the subscription list is lost because
> it is held in the process state. Existing subscribers receive no
> notification of this crash (other than via their own monitors).
> Subscribers should monitor the `Protocol` process and re-subscribe
> if it restarts to continue receiving events.

### Graceful leave

```elixir
SwimEx.leave()
```

Increments incarnation, broadcasts a dead announcement
directly to `max(⌈N×0.25⌉, 8)` random peers (where `N`
is the number of alive + suspect peers), then stops the
Protocol process. The supervisor restarts it; call
`Supervisor.stop/1` afterward for a full shutdown.

For an ungraceful stop (no dead broadcast), call
`Supervisor.stop/1` directly on the supervisor.

---

## Multiple instances

Run two independent SwimEx clusters in one BEAM by giving
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

Metadata map: `%{node: {host, port, cookie}, peer: {host, port, cookie}}`
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
| `swim_node` | `{host, port, cookie}` — this node |
| `swim_event` | atom — event being logged |
| `swim_peer` | `{host, port, cookie}` — peer involved |

Configure a metadata-aware formatter (e.g. `LoggerJSON`)
to expose these fields in structured logs.

---

## Node identity and restarts

A node is identified by `{host, port, cookie}`. Identity
is **stable across restarts** — the same tuple reconnects
as the same logical node. A different cookie on the same
address is treated as a distinct node. Stale dead events
from a previous incarnation are rejected because the
restarted node seeds its incarnation number from
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

For multi-node testing without real sockets and fault
injection, see [TESTING.md](TESTING.md).
