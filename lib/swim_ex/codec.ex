defmodule SwimEx.Codec do
  @moduledoc """
  Codec for SWIM protocol messages.

  Handles serialization and deserialization of messages and gossip events.
  Uses Erlang External Term Format for simplicity.
  """

  @mtu 1400

  @type node_id :: {String.t(), :inet.port_number(), String.t()}
  @type incarnation :: non_neg_integer()

  @type event ::
          {:alive, node_id, incarnation}
          | {:suspect, node_id, incarnation}
          | {:dead, node_id, incarnation}

  @type message ::
          {:ping, node_id, seq :: non_neg_integer(), [event]}
          | {:ack, node_id, seq :: non_neg_integer(), [event]}
          | {:ping_req, node_id, seq :: non_neg_integer(), target :: node_id, [event]}
          | {:fwd_ack, node_id, seq :: non_neg_integer(), source :: node_id, [event]}

  @doc """
  Encodes a message into a binary payload.

  Returns `{:error, :too_large}` if the resulting binary exceeds the MTU.
  """
  @spec encode(message()) :: {:ok, binary()} | {:error, :too_large}
  def encode(msg) do
    bin = :erlang.term_to_binary(msg)

    if byte_size(bin) > @mtu do
      {:error, :too_large}
    else
      {:ok, bin}
    end
  end

  @doc """
  Decodes a binary payload into a message.

  Returns `{:ok, message}` or `{:error, :invalid}`.
  """
  @spec decode(binary()) :: {:ok, message()} | {:error, :invalid}
  def decode(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> {:error, :invalid}
  end

  @doc """
  Returns the maximum transmission unit (MTU) for SWIM packets.
  """
  @spec mtu() :: non_neg_integer()
  def mtu, do: @mtu
end
