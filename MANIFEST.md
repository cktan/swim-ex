# Project Manifest

This document provides a map of the `swim-ex` source files and their primary responsibilities within the SWIM protocol implementation.

## Core Protocol (`lib/swim_ex/`)

| File | Purpose |
| :--- | :--- |
| `swim_ex.ex` | **Main Entry Point**: Provides the public API for membership queries, subscriptions, and graceful leave. |
| `protocol.ex` | **Protocol Engine**: The central GenServer that drives the SWIM state machine, timers (ping/suspicion), and message handling. |
| `membership.ex` | **Membership State**: Pure functional module managing the cluster member list, state transitions (Alive/Suspect/Dead), and incarnations. |
| `gossip_queue.ex` | **Dissemination Logic**: Manages the priority queue of gossip events and handles packing them into outgoing packets based on MTU and transmit limits. |
| `codec.ex` | **Wire Format**: Handles serialization and deserialization of SWIM messages using Erlang External Term Format (ETF). |
| `supervisor.ex` | **Supervision Tree**: Manages the lifecycle of the Protocol and Transport processes. |
| `transport.ex` | **Transport Behaviour**: Defines the generic interface for sending and receiving binary packets. |
| `transport/udp.ex` | **UDP Implementation**: The production transport implementation using Erlang `:gen_udp`. |

## Support & Testing

| File | Purpose |
| :--- | :--- |
| `test/support/transport_in_memory.ex` | **Simulation Transport**: An in-process transport used for testing. Supports fault injection (loss, delay, partitions). |
| `mix.exs` | **Project Config**: Defines dependencies (`telemetry`, `ex_doc`), application metadata, and compilation options. |

## Test Suites (`test/swim_ex/`)

| File | Purpose |
| :--- | :--- |
| `integration_test.exs` | Verifies multi-node behavior and basic failure detection in small clusters. |
| `scale_test.exs` | Large-scale (64 nodes) stress tests covering churn, high loss, and network partitions. |
| `codec_test.exs` | Unit tests for wire format encoding/decoding. |
| `gossip_queue_test.exs` | Verifies event prioritization and dissemination limits. |
| `membership_test.exs` | Unit tests for state transition rules and incarnation bumping. |
| `protocol_test.exs` | Direct tests of the protocol GenServer logic and timer behavior. |
| `dissemination_test.exs` | Specifically tests how gossip propagates through the cluster. |
