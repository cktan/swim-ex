# Branch Review Problems

## wip/23 — latency jitter and delay stress

**Branch commit:** `8c4cc08`

**Problem: `delay_ms` never reaches the InMemory transport.**

`node_opts/4` starts the transport with fixed options:

```elixir
{:ok, t_pid} =
  InMemory.start_link(
    network: net,
    identity: {host, port, ""},
    name: transport_name
  )
```

The `extra` keyword list (which contains `delay_ms`) is
merged only into the `Protocol.start_link` call, and
`Protocol.init/1` does not read or forward `delay_ms`.
`InMemory.start_link/1` never sees the option, so the
transport always defaults to `delay_ms: 0`.

The test passes as a plain convergence test, but it does
not exercise the high-latency scenario it claims to test.

**Fix:** Either (a) thread `delay_ms` (and `packet_loss`,
which has the same bug in the existing packet-loss stress
test) through `node_opts` into `InMemory.start_link`, or
(b) call `InMemory.set_fault/2` after each node is started
to inject the delay.

---

## wip/24 — bootstrap storm simulation

**Branch commit:** `053e6bd`

**Problem: GenServer processes started inside
`Task.async_stream` are killed when the tasks exit.**

The test starts 63 nodes inside `Task.async_stream`:

```elixir
client_nodes =
  2..64
  |> Task.async_stream(
    fn i -> node_opts(net, "boot_node_#{i}", seed_port,
                      seeds: [seed]) end,
    max_concurrency: 64,
    timeout: 30_000
  )
  |> Enum.map(fn {:ok, node} -> node end)
```

`node_opts` calls `GenServer.start_link` (via
`Protocol.start_link` and `InMemory.start_link`), which
uses `:proc_lib.start_link` and records the calling process
as the OTP `$ancestors` parent. The calling process here
is the task process, not the test process.

`gen_server`'s main loop traps exits and matches:

```erlang
{'EXIT', Parent, Reason} -> terminate(Reason, ...)
```

When the task process exits normally after returning its
result, the GenServers it spawned receive
`{'EXIT', TaskPid, :normal}` where `TaskPid == Parent`,
and call `terminate/2`. All 63 client nodes are dead by
the time `wait_for/2` begins, so the convergence assertion
can never succeed.

**Fix:** Call `node_opts` from the test process, not from
spawned tasks. Since each node connects to the seed
independently and begins gossiping immediately, starting
them in a tight sequential loop from the test process
produces the same burst-join effect for the SWIM layer.
Replace `Task.async_stream` with a plain `for` comprehension
or `Enum.map`.
