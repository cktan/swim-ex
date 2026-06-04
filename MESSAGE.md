# Message Formats

This document describes the binary packet formats used by
`swim-ex` over UDP.

All messages are encoded using the Erlang External Term Format
(ETF) via `:erlang.term_to_binary/1`.

---

## 1. Node Identity (`node_id`)

The identity of a node is represented as a 3-tuple:
```elixir
{host :: String.t(), port :: :inet.port_number(), cookie :: String.t()}
```
Example:
```elixir
{"127.0.0.1", 7771, "session_abc"}
```

---

## 2. Gossip Events (`event`)

Gossip events propagate membership state changes throughout the
cluster. They are always piggybacked inside message envelopes.

### Event Types

#### Alive
Indicates that a node is alive at the specified incarnation.
```elixir
{:alive, {host, port, cookie}, incarnation}
```

#### Suspect
Indicates that a node is suspected of being dead.
```elixir
{:suspect, {host, port, cookie}, incarnation}
```

#### Dead
Indicates that a node has been declared dead.
```elixir
{:dead, {host, port, cookie}, incarnation}
```

---

## 3. Protocol Message Envelopes

Every UDP packet contains one of the following message shapes.

### a) Ping (`:ping`)
Sent directly to a probe target to test reachability.
```elixir
{:ping, sender :: node_id, seq :: non_neg_integer(), events :: [event()]}
```

### b) Ack (`:ack`)
Sent in response to a direct ping to acknowledge reachability.
```elixir
{:ack, sender :: node_id, seq :: non_neg_integer(), events :: [event()]}
```

### c) Ping-Request (`:ping_req`)
Sent to a relay node to request an indirect ping to a target.
```elixir
{:ping_req, sender :: node_id, seq :: non_neg_integer(), target :: node_id, events :: [event()]}
```

### d) Forward Ack (`:fwd_ack`)
Sent by a relay node back to the prober once it receives an ack.
```elixir
{:fwd_ack, sender :: node_id, seq :: non_neg_integer(), source :: node_id, events :: [event()]}
```
