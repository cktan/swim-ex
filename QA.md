# Quality Assurance & Testing

This document describes the testing infrastructure, strategy, and large-scale validation of the `SwimEx` protocol.

## Test Strategy

`SwimEx` employs a multi-layered testing approach to ensure protocol correctness, reliability under churn, and scalability.

### 1. Unit Tests
Low-level modules like `Codec`, `GossipQueue`, and `Membership` are tested in isolation for correctness of state transitions and data encoding.

### 2. Integration Tests
Found in `test/swim_ex/integration_test.exs`, these tests use the `InMemory` transport to simulate multiple nodes on a single machine. They verify:
*   Small cluster convergence (3–5 nodes).
*   Basic failure detection (suspect → dead).
*   Graceful leave behavior.
*   Self-refutation of false suspicion.

### 3. Scale & Stress Tests
Located in `test/swim_ex/scale_test.exs`, these tests use the `InMemory` transport at high node counts (64+) to stress the gossip and failure detection mechanisms.

**Scenarios covered:**
*   **Staged Startup**: Verifies that a cluster can converge when nodes join in waves.
*   **Partition & Heal**: Uses `InMemory.Network.set_partitions/2` to simulate a "Split Brain" scenario. This verifies that:
    1. Isolated groups remain stable.
    2. Groups eventually merge back into a single cluster after the partition is removed.
*   **High Packet Loss**: Simulates 30% packet loss across all nodes to ensure the protocol is robust against unreliable networks.
*   **Churn Stress**: Randomly stops and restarts groups of nodes to ensure the membership list converges despite constant state changes.
*   **Pause/Unpause**: Isolates a single node until it is declared dead by the cluster, then restores it to verify it can successfully rejoin.

## Testing Infrastructure

### In-Memory Transport
To keep tests fast and deterministic, we use `SwimEx.Transport.InMemory`. This avoids the overhead of the OS network stack and allows for precise fault injection.

### Fault Injection
The `InMemory` transport supports several fault modes:
*   `packet_loss`: (0.0–1.0) Probability of dropping any given packet.
*   `delay_ms`: Fixed latency for packet delivery.
*   `Network.set_partitions(groups)`: Programmatic isolation of node groups.

## Running Tests

### Standard Suite
Runs all unit and integration tests:
```bash
mix test
```

### Scale Suite
Runs the 64-node stress tests (may take 20-40 seconds):
```bash
mix test test/swim_ex/scale_test.exs
```

### Coverage
To check test coverage:
```bash
mix test --cover
```

## Protocol Invariants Verified
*   **No False Positives**: Healthy nodes should not be permanently marked dead (verified by self-refutation tests).
*   **Eventually Consistent**: All healthy nodes eventually agree on the membership list (verified by convergence tests).
*   **Partition Recovery**: The cluster must eventually merge after network healing (verified by partition tests).
