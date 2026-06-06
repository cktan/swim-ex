# swim_ex Testing Guide

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
  assert [{"n2", 7771, "", :alive, _}] = SwimEx.Protocol.members(:n1, [])
end
```

## Fault injection

```elixir
# Drop all outbound packets from t2 (simulate crash)
InMemory.set_fault(t2, packet_loss: 1.0)

# Add 50ms delivery delay
InMemory.set_fault(t2, delay_ms: 50)

# Restore normal operation
InMemory.set_fault(t2, packet_loss: 0.0, delay_ms: 0)
```
