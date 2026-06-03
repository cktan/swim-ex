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
*   **Staged Startup, Failure Detection & Pause/Unpause**:
    Brings 64 nodes online in two waves, kills one node
    outright, pauses a second node (100% packet loss) until
    declared dead, then restores it. Verifies event
    delivery to subscribers, dead-entry GC, and graceful
    leave.
*   **Partition & Heal**: Uses `InMemory.Network.set_partitions/2`
    to split 64 nodes into two groups of 32. Verifies each
    group stabilises at 31 visible members, then merges
    back to 63 after the partition is cleared.
*   **4-way Partition & Gradual Heal**: Splits 64 nodes into
    four groups of 16, verifies each group stabilises at
    15 visible members, then heals in two stages (A+B and
    C+D, then full heal) confirming incremental recovery.
*   **Asymmetric Partition (1 vs 63)**: Isolates the seed
    node from the 63-node majority. Verifies both sides
    converge to their correct reduced view and reunite
    after healing.
*   **High Packet Loss**: Simulates 30% packet loss across
    all nodes to ensure the protocol is robust against
    unreliable networks.
*   **Churn Stress**: Stops nodes 50–60 and waits for the
    cluster to declare them dead, then restarts them.
    Verifies full re-convergence.
*   **Half-cluster Restart (Immediate)**: Kills nodes 1–32
    (including the seed) and immediately restarts them with
    `incarnation: 2`. Verifies the incarnation mechanism
    overrides stale dead entries.
*   **Half-cluster Restart (Staged)**: Same kill, but waits
    for the surviving 32 nodes to mark all killed nodes as
    dead before restarting with `incarnation: 2`. A stricter
    test of dead-node refutation.
*   **Rolling Upgrade Simulation**: Cycles through all 64
    nodes in batches of 8, stopping and restarting each
    batch with `incarnation: 2` while leaving the rest of
    the cluster live. Verifies uninterrupted convergence
    across a full rolling upgrade.
*   **High Latency Jitter and Delay Stress**: Assigns each
    node a fixed send delay (0/8/16/24 ms in rotation).
    Nodes with 24 ms delay exceed `@ping_timeout` (20 ms),
    so all their direct pings time out and the indirect-ping
    path is exercised for every probe. Verifies convergence
    under heterogeneous latency.
*   **Bootstrap Storm**: Starts a single seed, then spawns
    all 63 remaining nodes in rapid sequential succession
    from the test process, simulating a simultaneous cold
    boot. Verifies the cluster converges despite the seed
    receiving a burst of join requests.

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
Runs the 64-node stress tests (may take 2-3 minutes):
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
