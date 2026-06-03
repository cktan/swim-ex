# Code Review - SwimEx

Detailed code review of the `swim-ex` project, focusing on resource management, recursion, and exception handling.

## 1. Resource Leaks & Memory Management

### [LOW] Socket Resource Management in `SwimEx.Transport.UDP`
The UDP socket is opened in `init/1` and stored in the GenServer state.

**Issue:**
- There is no `terminate/2` callback to explicitly call `:gen_udp.close(socket)`.
- While Erlang's VM closes sockets when the owner process terminates, it is best practice to explicitly close resources in `terminate/2` to ensure clean shutdown, especially if the code is ever adapted to non-process-linked resources.

**Recommendation:**
Add a `terminate/2` callback to `lib/swim_ex/transport/udp.ex` that closes the socket.

## 2. Recursion vs. Tail-Recursion

### [PASS] `SwimEx.GossipQueue`
The primary recursive function in the project is `do_collect_pack/6` in `lib/swim_ex/gossip_queue.ex`.

**Analysis:**
- The function is correctly **tail-recursive**. It passes updated state and accumulators to the next call, and the final result is returned without further processing of the stack.
- It uses `:gb_sets` for efficient ordered operations, avoiding $O(N^2)$ behavior on list manipulations.

### [PASS] General Usage
Most iterative logic across the project (e.g., `Protocol.apply_gossip_events`, `Membership.list`) utilizes Elixir's `Enum` module (e.g., `Enum.reduce`, `Enum.map`, `Enum.reject`). These are implemented efficiently and do not pose stack overflow risks for typical cluster sizes.

## 3. Exception Handling

### [PASS] `SwimEx.Codec`
The `decode/1` function in `lib/swim_ex/codec.ex` uses a `try/rescue` block to handle potential errors from `:erlang.binary_to_term/2`.

**Analysis:**
- It correctly uses the `[:safe]` option to prevent atom exhaustion.
- It catches all exceptions and returns `{:error, :invalid}`, which is then handled by the `Protocol` GenServer by dropping the packet and logging a warning. This prevents a single malicious or malformed packet from crashing the entire protocol process.

### [PASS] `SwimEx.Protocol`
Message handling is structured to be robust against malformed data.
- Packet decoding errors are caught and logged.
- Missing configuration keys in `init/1` use `fetch!`, which is appropriate as it causes a supervised crash on invalid startup configuration.

## 4. Other Observations

### MTU Calculation Accuracy
In `lib/swim_ex/gossip_queue.ex`, the `do_collect_pack` function estimates the size of encoded events using `byte_size(:erlang.term_to_binary(entry.event))`.

**Observation:**
- While the `Codec` indeed uses `term_to_binary`, the hardcoded offsets (`+ 4 + esize`, `+ esize - 1`) are approximations of list/tuple overhead.
- `Protocol.ex` mitigates this by using `@mtu_margin` (128 bytes), which provides a generous buffer against miscalculations. This is a sound engineering trade-off.

### Subscription Monitoring
The `Protocol` GenServer correctly monitors subscriber processes using `Process.monitor/1` and cleans up its state upon receiving `:DOWN` messages. It also uses `Process.demonitor(ref, [:flush])` in the `unsubscribe` call to prevent stale messages in the mailbox.
