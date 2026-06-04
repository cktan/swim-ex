defmodule SwimEx.Protocol do
  @moduledoc """
  SWIM+INF+Susp protocol state machine.

  Owns all membership state, the gossip queue, pending ping
  tracking, and suspicion timers. The Transport process owns
  the socket; this GenServer drives everything else.

  ## Message flow

      Period fires → pick probe target T
        → send ping(seq) to T
        → wait ping_timeout
      ping_timeout fires (no direct ack)
        → send ping_req(seq, target=T) to k random nodes
        → wait ping_timeout again (indirect)
      indirect_timeout fires (no indirect ack)
        → gossip suspect(T, inc)
        → start suspicion timer
      suspicion_timeout fires
        → gossip dead(T, inc)

  Acks at any stage cancel the relevant timer and update
  membership. A suspect node can refute by sending
  alive(self, inc+1).
  """

  use GenServer
  require Logger

  alias SwimEx.{Codec, GossipQueue, Membership}

  @default_protocol_period 1000
  @default_ping_timeout 200
  @default_ping_req_fanout 3
  @default_suspicion_timeout 3000
  @default_seed_retry_interval 5000
  @default_dead_node_expiry 6000

  @mtu_margin 128
  @refutation_multiplier 2

  defstruct [
    :self_id,
    :cookie,
    :incarnation,
    :transport,
    :transport_mod,
    :swim_name,
    :protocol_period,
    :ping_timeout,
    :ping_req_fanout,
    :suspicion_timeout,
    :seed_retry_interval,
    :dead_node_expiry,
    :membership,
    :gossip_queue,
    :probe_list,
    :pending,
    :suspicion_timers,
    :seq,
    :subscribers,
    :seeds,
    :ping_times
  ]

  # --- Public API ---

  @doc """
  Starts the SWIM protocol GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, :swim)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns current cluster members.
  """
  @spec members(GenServer.server(), keyword()) :: [{String.t(), :inet.port_number(), String.t(), SwimEx.Membership.status(), non_neg_integer()}]
  def members(name, opts) do
    GenServer.call(name, {:members, opts})
  end

  @doc """
  Subscribes a process to membership events.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(name, pid) do
    GenServer.call(name, {:subscribe, pid})
  end

  @doc """
  Unsubscribes a process from membership events.
  """
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(name, pid) do
    GenServer.call(name, {:unsubscribe, pid})
  end

  @doc """
  Notifies the cluster that this node is leaving and stops the process.
  """
  @spec leave(GenServer.server()) :: :ok
  def leave(name) do
    GenServer.call(name, :leave, 10_000)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    cookie = Keyword.get(opts, :cookie, "")
    transport = Keyword.fetch!(opts, :transport)
    transport_mod = Keyword.get(opts, :transport_mod, SwimEx.Transport.UDP)

    incarnation = Keyword.get(opts, :incarnation, System.system_time(:millisecond))
    self_id = {host, port, cookie}

    gossip_queue = GossipQueue.new()
    state = %__MODULE__{
      self_id: self_id,
      cookie: cookie,
      incarnation: incarnation,
      transport: transport,
      transport_mod: transport_mod,
      swim_name: Keyword.get(opts, :name, :swim),
      protocol_period: Keyword.get(opts, :protocol_period, @default_protocol_period),
      ping_timeout: Keyword.get(opts, :ping_timeout, @default_ping_timeout),
      ping_req_fanout: Keyword.get(opts, :ping_req_fanout, @default_ping_req_fanout),
      suspicion_timeout: Keyword.get(opts, :suspicion_timeout, @default_suspicion_timeout),
      seed_retry_interval: Keyword.get(opts, :seed_retry_interval, @default_seed_retry_interval),
      dead_node_expiry: Keyword.get(opts, :dead_node_expiry, @default_dead_node_expiry),
      membership: Membership.new(),
      gossip_queue: gossip_queue,
      probe_list: [],
      pending: %{},
      suspicion_timers: %{},
      seq: 0,
      # NOTE: Subscribers are lost on restart. See USAGE.md "Restart caveat".
      subscribers: %{},
      seeds: normalize_seeds(Keyword.get(opts, :seeds, [])),
      ping_times: %{}
    }

    state = enqueue_gossip(state, {:alive, self_id, incarnation}, :suspect)
    transport_mod.set_receiver(transport, self())
    schedule_period(state)
    send(self(), :seed_retry)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:members, opts}, _from, state) do
    result = Membership.list(state.membership, opts)
    {:reply, result, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    subscribers = Map.put(state.subscribers, pid, ref)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    state = remove_subscriber(state, pid)
    {:reply, :ok, state}
  end

  def handle_call(:leave, _from, state) do
    # Use system time so the dead incarnation always exceeds any
    # locally-bumped incarnation at peers.
    dead_inc = System.system_time(:millisecond)
    state = %{state | incarnation: dead_inc}
    broadcast_dead_self(state)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_info(:protocol_period, state) do
    state =
      state
      |> gc_dead_members()
      |> run_protocol_period()

    schedule_period(state)
    {:noreply, state}
  end

  def handle_info(:seed_retry, state) do
    state = ping_seeds(state)
    schedule_seed_retry(state)
    {:noreply, state}
  end

  def handle_info({:swim_packet, from, data}, state) do
    state =
      case Codec.decode(data) do
        {:ok, msg} ->
          handle_message(msg, from, state)

        {:error, :invalid} ->
          :telemetry.execute([:swim, :message, :dropped], %{count: 1}, %{node: state.self_id, peer: from})
          Logger.warning("invalid packet from peer",
            swim_node: state.self_id,
            swim_peer: from,
            swim_event: :message_dropped
          )
          state
      end

    {:noreply, state}
  end

  def handle_info({:ping_timeout, seq}, state) do
    state =
      case Map.get(state.pending, seq) do
        {target, _ref, :direct} ->
          send_indirect_pings(seq, target, state)

        {_target, _ref, {:relay_to, _from, _orig_seq}} ->
          %{state | pending: Map.delete(state.pending, seq)}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:indirect_timeout, seq}, state) do
    state =
      case Map.pop(state.pending, seq) do
        {{target, _ref, :indirect}, pending} ->
          state = %{state | pending: pending, ping_times: Map.delete(state.ping_times, seq)}
          suspect_node(target, state)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:suspicion_timeout, node, timeout_inc}, state) do
    state =
      Map.update!(state, :suspicion_timers, fn timers ->
        case Map.get(timers, node) do
          {_ref, ^timeout_inc} -> Map.delete(timers, node)
          _ -> timers
        end
      end)

    state =
      case Membership.get(state.membership, node) do
        %{status: :suspect, incarnation: ^timeout_inc} ->
          dead_node(node, timeout_inc, state)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, remove_subscriber(state, pid)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Protocol period ---

  defp run_protocol_period(state) do
    n = member_count(state)
    :telemetry.execute([:swim, :cluster, :size], %{count: n}, %{node: state.self_id})

    {target, state} = next_probe_target(state)

    case target do
      nil -> state
      node -> send_ping(node, state)
    end
  end

  defp next_probe_target(state) do
    peers = probe_candidates(state)
    peers_set = MapSet.new(peers)
    probe_list = Enum.reject(state.probe_list, &(not MapSet.member?(peers_set, &1)))

    case probe_list do
      [] when peers == [] ->
        {nil, %{state | probe_list: []}}

      [] ->
        [next | rest] = Enum.shuffle(peers)
        {next, %{state | probe_list: rest}}

      [next | rest] ->
        {next, %{state | probe_list: rest}}
    end
  end

  defp probe_candidates(state) do
    state.membership.members
    |> Enum.filter(fn {_, m} -> m.status in [:alive, :suspect] end)
    |> Enum.map(fn {node, _} -> node end)
    |> Enum.reject(&(&1 == state.self_id))
  end

  # --- Sending messages ---

  defp send_ping(target, state) do
    seq = state.seq + 1
    {events, q} = GossipQueue.pack(state.gossip_queue, member_count(state), Codec.mtu() - @mtu_margin)
    msg = {:ping, state.self_id, seq, events}

    case Codec.encode(msg) do
      {:ok, data} ->
        transport_send(state, target, data)
        ref = Process.send_after(self(), {:ping_timeout, seq}, state.ping_timeout)
        pending = Map.put(state.pending, seq, {target, ref, :direct})
        ping_times = Map.put(state.ping_times, seq, System.monotonic_time(:millisecond))
        %{state | seq: seq, gossip_queue: q, pending: pending, ping_times: ping_times}

      {:error, :too_large} ->
        Logger.warning("ping too large", swim_node: state.self_id)
        state
    end
  end

  defp send_indirect_pings(seq, target, state) do
    relays =
      state.membership.members
      |> Enum.filter(fn {node, m} ->
        node != state.self_id and node != target and m.status == :alive
      end)
      |> Enum.map(fn {node, _} -> node end)
      |> Enum.take_random(state.ping_req_fanout)

    {events, q} = GossipQueue.pack(state.gossip_queue, member_count(state), Codec.mtu() - @mtu_margin)
    msg = {:ping_req, state.self_id, seq, target, events}

    case Codec.encode(msg) do
      {:ok, data} ->
        Enum.each(relays, &transport_send(state, &1, data))

      {:error, :too_large} ->
        Logger.warning("ping_req too large", swim_node: state.self_id)
    end

    ref = Process.send_after(self(), {:indirect_timeout, seq}, state.ping_timeout)
    {_old, pending} = Map.pop(state.pending, seq)
    pending = Map.put(pending, seq, {target, ref, :indirect})
    %{state | pending: pending, gossip_queue: q}
  end

  defp send_ack(to, seq, state) do
    {events, q} = GossipQueue.pack(state.gossip_queue, member_count(state), Codec.mtu() - @mtu_margin)
    msg = {:ack, state.self_id, seq, events}

    case Codec.encode(msg) do
      {:ok, data} ->
        transport_send(state, to, data)
        %{state | gossip_queue: q}

      {:error, :too_large} ->
        Logger.warning("ack too large", swim_node: state.self_id)
        state
    end
  end

  defp broadcast_dead_self(state) do
    event = {:dead, state.self_id, state.incarnation}
    peers =
      state.membership.members
      |> Enum.filter(fn {_, m} -> m.status in [:alive, :suspect] end)
      |> Enum.map(fn {node, _} -> node end)

    fanout = max(ceil(length(peers) * 0.25), 8)
    targets = Enum.take_random(peers, fanout)

    msg = {:ack, state.self_id, 0, [event]}

    case Codec.encode(msg) do
      {:ok, data} -> Enum.each(targets, &transport_send(state, &1, data))
      _ -> :ok
    end
  end

  # --- Message handlers ---

  defp handle_message({:ping, from, seq, events}, _source, state) do
    state = apply_gossip_events(events, state)
    state = update_node_alive(from, state)
    send_ack(from, seq, state)
  end

  defp handle_message({:ack, from, seq, events}, _source, state) do
    state = apply_gossip_events(events, state)
    # Don't mark sender alive if ack carries their own dead announcement
    state =
      if Enum.any?(events, &match?({:dead, ^from, _}, &1)) do
        state
      else
        update_node_alive(from, state)
      end
    cancel_pending(seq, state)
  end

  defp handle_message({:ping_req, from, seq, target, events}, _source, state) do
    state = apply_gossip_events(events, state)
    # Forward ping to target, asking it to ack back to us,
    # then we'll fwd_ack to original sender.
    # Simplified: just send a regular ping and relay the ack.
    relay_seq = state.seq + 1
    {relay_events, q} = GossipQueue.pack(state.gossip_queue, member_count(state), Codec.mtu() - @mtu_margin)
    relay_msg = {:ping, state.self_id, relay_seq, relay_events}

    state =
      case Codec.encode(relay_msg) do
        {:ok, data} ->
          transport_send(state, target, data)
          ref = Process.send_after(self(), {:ping_timeout, relay_seq}, state.ping_timeout)
          pending = Map.put(state.pending, relay_seq, {target, ref, {:relay_to, from, seq}})
          %{state | seq: relay_seq, pending: pending, gossip_queue: q}

        {:error, :too_large} ->
          state
      end

    state
  end

  defp handle_message({:fwd_ack, from, seq, source, events}, _source_addr, state) do
    state = apply_gossip_events(events, state)
    _ = from
    _ = source
    cancel_pending(seq, state)
  end

  defp handle_message(_unknown, _from, state), do: state

  # --- Ack/ping cancellation ---

  defp cancel_pending(seq, state) do
    case Map.pop(state.pending, seq) do
      {nil, _} ->
        state

      {{target, ref, :direct}, pending} ->
        Process.cancel_timer(ref)
        state = update_node_alive(target, state)
        emit_rtt(seq, target, state)
        ping_times = Map.delete(state.ping_times, seq)
        %{state | pending: pending, ping_times: ping_times}

      {{target, ref, :indirect}, pending} ->
        Process.cancel_timer(ref)
        state = update_node_alive(target, state)
        emit_rtt(seq, target, state)
        ping_times = Map.delete(state.ping_times, seq)
        %{state | pending: pending, ping_times: ping_times}

      {{target, ref, {:relay_to, original_sender, orig_seq}}, pending} ->
        Process.cancel_timer(ref)
        # Forward ack back to original ping-req sender
        {fwd_events, q} =
          GossipQueue.pack(state.gossip_queue, member_count(state), Codec.mtu() - @mtu_margin)

        fwd_msg = {:fwd_ack, state.self_id, orig_seq, target, fwd_events}

        state =
          case Codec.encode(fwd_msg) do
            {:ok, data} ->
              transport_send(state, original_sender, data)
              %{state | gossip_queue: q}

            _ ->
              state
          end

        %{state | pending: pending}
    end
  end

  # --- Membership updates ---

  defp update_node_alive(node, state) when node == state.self_id, do: state

  defp update_node_alive(node, state) do
    case Membership.get(state.membership, node) do
      nil ->
        inc = 0
        membership = Membership.add(state.membership, node, inc)
        gossip_queue = GossipQueue.enqueue(state.gossip_queue, {:alive, node, inc})
        state = %{state | membership: membership, gossip_queue: gossip_queue}
        notify_subscribers({:swim, :node_up, node}, state)

      %{status: :dead} ->
        state

      %{status: prev_status, incarnation: current_inc} ->
        membership = Membership.set_alive(state.membership, node, current_inc)
        state = %{state | membership: membership}
        state = cancel_suspicion_timer(node, state)

        if prev_status != :alive do
          # We only gossip if we transitioned from suspect to alive.
          # Note: we no longer revive dead nodes here; we wait for
          # higher-incarnation gossip from the node itself.
          state = enqueue_gossip(state, {:alive, node, current_inc}, prev_status)
          notify_subscribers({:swim, :node_up, node}, state)
        else
          state
        end
    end
  end

  defp suspect_node(node, state) do
    case Membership.get(state.membership, node) do
      nil -> state
      %{status: :dead} -> state
      %{incarnation: inc} ->
        membership = Membership.apply_event(state.membership, {:suspect, node, inc})
        state = %{state | membership: membership}
        state = enqueue_gossip(state, {:suspect, node, inc})
        state = notify_subscribers({:swim, :node_suspect, node}, state)
        start_suspicion_timer(node, state)
    end
  end

  defp dead_node(node, inc, state) do
    membership = Membership.apply_event(state.membership, {:dead, node, inc})

    case Membership.get(membership, node) do
      %{status: :dead} ->
        state = %{state | membership: membership}
        state = enqueue_gossip(state, {:dead, node, inc})
        notify_subscribers({:swim, :node_down, node}, state)

      _ ->
        state
    end
  end

  # --- Suspicion timers ---

  defp start_suspicion_timer(node, state) do
    %{incarnation: inc} = Membership.get(state.membership, node)

    case Map.get(state.suspicion_timers, node) do
      {_ref, ^inc} ->
        state

      existing ->
        if existing do
          {ref, _} = existing
          Process.cancel_timer(ref)
        end

        ref = Process.send_after(self(), {:suspicion_timeout, node, inc}, state.suspicion_timeout)
        %{state | suspicion_timers: Map.put(state.suspicion_timers, node, {ref, inc})}
    end
  end

  defp cancel_suspicion_timer(node, state) do
    case Map.pop(state.suspicion_timers, node) do
      {nil, _} -> state
      {{ref, _inc}, timers} ->
        Process.cancel_timer(ref)
        %{state | suspicion_timers: timers}
    end
  end

  # --- Gossip event application ---

  defp apply_gossip_events(events, state) do
    Enum.reduce(events, state, &apply_single_event(&2, &1))
  end

  defp apply_single_event(state, {kind, node, _inc} = event) when node != state.self_id do
    prev = Membership.get(state.membership, node)
    membership = Membership.apply_event(state.membership, event)
    curr = Membership.get(membership, node)
    state = %{state | membership: membership}

    state =
      if prev != curr do
        state = enqueue_gossip(state, event, if(prev, do: prev.status, else: nil))

        cond do
          kind == :dead ->
            state = cancel_suspicion_timer(node, state)
            notify_subscribers({:swim, :node_down, node}, state)

          kind == :suspect ->
            state = start_suspicion_timer(node, state)
            notify_subscribers({:swim, :node_suspect, node}, state)

          kind == :alive and (prev == nil or match?(%{status: s} when s != :alive, prev)) ->
            state = cancel_suspicion_timer(node, state)
            notify_subscribers({:swim, :node_up, node}, state)

          true ->
            state
        end
      else
        state
      end

    state
  end

  defp apply_single_event(state, {kind, node, inc}) when node == state.self_id do
    # Self-refutation: if we receive suspect or dead about ourselves, bump incarnation
    if kind in [:suspect, :dead] and inc >= state.incarnation do
      new_inc = inc + 1
      state = %{state | incarnation: new_inc}
      enqueue_gossip(state, {:alive, state.self_id, new_inc}, :suspect)
    else
      state
    end
  end

  # --- Seeds ---

  defp ping_seeds(state) do
    case state.seeds do
      [] ->
        state

      seeds ->
        # If alone, ping all seeds to find the cluster.
        # If already in a cluster, ping one random seed occasionally
        # to ensure we haven't partitioned from other parts of the network.
        seeds_to_ping =
          if Membership.member_count(state.membership) == 0 do
            seeds
          else
            [Enum.random(seeds)]
          end

        Enum.reduce(seeds_to_ping, state, fn seed, acc ->
          send_ping(seed, acc)
        end)
    end
  end

  # --- Subscribers ---

  defp notify_subscribers({:swim, event, node} = msg, state) do
    {telemetry_event, log_level} =
      case event do
        :node_up -> {[:swim, :node, :up], :info}
        :node_down -> {[:swim, :node, :down], :warning}
        :node_suspect -> {[:swim, :node, :suspect], :warning}
      end

    :telemetry.execute(telemetry_event, %{}, %{node: state.self_id, peer: node})

    Logger.log(log_level, "membership change: #{event}",
      swim_node: state.self_id,
      swim_peer: node,
      swim_event: event
    )

    Enum.each(state.subscribers, fn {pid, _ref} ->
      Kernel.send(pid, msg)
    end)

    state
  end

  defp remove_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  # --- GC ---

  defp gc_dead_members(state) do
    membership = Membership.gc(state.membership, state.dead_node_expiry)
    %{state | membership: membership}
  end

  # --- Helpers ---

  defp enqueue_gossip(state, {kind, _node, _inc} = event, prev_status \\ nil) do
    multiplier =
      if kind == :alive and (prev_status == nil or prev_status != :alive),
        do: @refutation_multiplier,
        else: 1

    queue = GossipQueue.enqueue(state.gossip_queue, event, multiplier)
    %{state | gossip_queue: queue}
  end

  defp transport_send(state, to, data) do
    to_addr = SwimEx.Transport.strip_cookie(to)
    state.transport_mod.send(state.transport, to_addr, data)
  end

  defp member_count(state) do
    Membership.member_count(state.membership)
  end

  defp schedule_period(state) do
    Process.send_after(self(), :protocol_period, state.protocol_period)
  end

  defp schedule_seed_retry(state) do
    Process.send_after(self(), :seed_retry, state.seed_retry_interval)
  end

  defp emit_rtt(seq, target, state) do
    case Map.get(state.ping_times, seq) do
      nil ->
        :ok

      sent_at ->
        duration = System.monotonic_time(:millisecond) - sent_at
        :telemetry.execute([:swim, :ping, :rtt], %{duration: duration}, %{node: state.self_id, peer: target})
    end
  end

  defp normalize_seeds(seeds) do
    Enum.map(seeds, fn
      {host, port} -> {host, port, ""}
      {host, port, cookie} -> {host, port, cookie}
    end)
  end
end

