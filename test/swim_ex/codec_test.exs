defmodule SwimEx.CodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwimEx.Codec

  # Generators

  defp node_id do
    gen all host <- string(:alphanumeric, min_length: 1, max_length: 20),
            port <- integer(1..65535) do
      {host, port}
    end
  end

  defp incarnation, do: integer(0..1_000_000)

  defp event do
    gen all kind <- member_of([:alive, :suspect, :dead]),
            node <- node_id(),
            inc <- incarnation() do
      {kind, node, inc}
    end
  end

  defp events, do: list_of(event(), max_length: 8)

  defp seq, do: integer(0..1_000_000)

  defp message do
    one_of([
      gen(all(s <- node_id(), q <- seq(), evs <- events(), do: {:ping, s, q, evs})),
      gen(all(s <- node_id(), q <- seq(), evs <- events(), do: {:ack, s, q, evs})),
      gen(
        all(
          s <- node_id(),
          q <- seq(),
          t <- node_id(),
          evs <- events(),
          do: {:ping_req, s, q, t, evs}
        )
      ),
      gen(
        all(
          s <- node_id(),
          q <- seq(),
          src <- node_id(),
          evs <- events(),
          do: {:fwd_ack, s, q, src, evs}
        )
      )
    ])
  end

  property "encode/decode roundtrip" do
    check all msg <- message() do
      case Codec.encode(msg) do
        {:ok, bin} ->
          assert {:ok, ^msg} = Codec.decode(bin)

        {:error, :too_large} ->
          # oversized — acceptable, just skip decode check
          :ok
      end
    end
  end

  property "decode rejects non-ETF binaries" do
    check all bin <- binary(min_length: 1) do
      # may decode to garbage or error — must never raise
      result = Codec.decode(bin)
      assert match?({:ok, _}, result) or result == {:error, :invalid}
    end
  end

  test "encode returns :too_large when payload exceeds MTU" do
    huge_host = String.duplicate("x", 2000)
    events = for i <- 1..50, do: {:alive, {huge_host, i}, i}
    msg = {:ping, {"sender", 7771}, 1, events}
    assert {:error, :too_large} = Codec.encode(msg)
  end

  test "small message encodes and decodes" do
    msg = {:ping, {"10.0.0.1", 7771}, 42, [{:alive, {"10.0.0.2", 7771}, 100}]}
    assert {:ok, bin} = Codec.encode(msg)
    assert {:ok, ^msg} = Codec.decode(bin)
    assert byte_size(bin) <= Codec.mtu()
  end
end
