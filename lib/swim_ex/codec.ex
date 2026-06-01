defmodule SwimEx.Codec do
  @mtu 1400

  @type node_id :: {String.t(), :inet.port_number()}
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

  @spec encode(message()) :: {:ok, binary()} | {:error, :too_large}
  def encode(msg) do
    bin = :erlang.term_to_binary(msg)

    if byte_size(bin) > @mtu do
      {:error, :too_large}
    else
      {:ok, bin}
    end
  end

  @spec decode(binary()) :: {:ok, message()} | {:error, :invalid}
  def decode(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> {:error, :invalid}
  end

  @spec mtu() :: non_neg_integer()
  def mtu, do: @mtu
end
