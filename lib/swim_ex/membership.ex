defmodule SwimEx.Membership do
  @moduledoc """
  Pure functional membership state machine.

  Tracks cluster members and their states. All functions
  return a new state; no side effects.

  ## Incarnation rules (SWIM+Susp)

  - `alive(node, inc)`:  accepted if inc > current_inc,
    OR if node is unknown (new join).
    Dead nodes revived only if inc > dead_inc (restart
    with time-based incarnation ensures this).
  - `suspect(node, inc)`: accepted if inc >= current_inc
    and node is alive or suspect.
  - `dead(node, inc)`:  accepted if inc >= current_inc
    and node is not already dead.
  """

  @type node_id :: {String.t(), :inet.port_number()}
  @type status :: :alive | :suspect | :dead
  @type member :: %{
          status: status(),
          incarnation: non_neg_integer(),
          dead_at: integer() | nil
        }

  @type t :: %__MODULE__{members: %{node_id() => member()}}
  defstruct members: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec add(t(), node_id(), non_neg_integer()) :: t()
  def add(%__MODULE__{} = state, node, incarnation) do
    put_member(state, node, :alive, incarnation)
  end

  @spec apply_event(t(), SwimEx.Codec.event()) :: t()
  def apply_event(%__MODULE__{} = state, {:alive, node, inc}) do
    case Map.get(state.members, node) do
      nil ->
        put_member(state, node, :alive, inc)

      %{status: :dead, incarnation: current_inc} when inc > current_inc ->
        put_member(state, node, :alive, inc)

      %{status: :dead} ->
        state

      %{incarnation: current_inc} when inc > current_inc ->
        put_member(state, node, :alive, inc)

      _ ->
        state
    end
  end

  def apply_event(%__MODULE__{} = state, {:suspect, node, inc}) do
    case Map.get(state.members, node) do
      nil ->
        state

      %{status: :dead} ->
        state

      %{incarnation: current_inc} when inc >= current_inc ->
        put_member(state, node, :suspect, inc)

      _ ->
        state
    end
  end

  def apply_event(%__MODULE__{} = state, {:dead, node, inc}) do
    case Map.get(state.members, node) do
      nil ->
        state

      %{status: :dead} ->
        state

      %{incarnation: current_inc} when inc >= current_inc ->
        now = System.monotonic_time(:millisecond)
        entry = %{status: :dead, incarnation: inc, dead_at: now}
        %{state | members: Map.put(state.members, node, entry)}

      _ ->
        state
    end
  end

  @spec gc(t(), non_neg_integer()) :: t()
  def gc(%__MODULE__{} = state, expiry_ms) do
    now = System.monotonic_time(:millisecond)

    members =
      Map.reject(state.members, fn
        {_, %{status: :dead, dead_at: dead_at}} -> now - dead_at >= expiry_ms
        _ -> false
      end)

    %{state | members: members}
  end

  @spec set_alive(t(), node_id(), non_neg_integer()) :: t()
  def set_alive(%__MODULE__{} = state, node, incarnation) do
    put_member(state, node, :alive, incarnation)
  end

  @spec get(t(), node_id()) :: member() | nil
  def get(%__MODULE__{} = state, node), do: Map.get(state.members, node)

  @spec member_count(t()) :: non_neg_integer()
  def member_count(%__MODULE__{} = state) do
    Enum.count(state.members, fn {_, m} -> m.status in [:alive, :suspect] end)
  end

  @spec list(t(), keyword()) :: [{String.t(), :inet.port_number(), status()}]
  def list(%__MODULE__{} = state, opts \\ []) do
    include_dead = Keyword.get(opts, :include_dead, true)

    state.members
    |> Enum.reject(fn {_, m} -> not include_dead and m.status == :dead end)
    |> Enum.map(fn {{host, port}, m} -> {host, port, m.status} end)
  end

  defp put_member(state, node, status, inc) do
    entry = %{status: status, incarnation: inc, dead_at: nil}
    %{state | members: Map.put(state.members, node, entry)}
  end
end
