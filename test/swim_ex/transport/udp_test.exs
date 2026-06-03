defmodule SwimEx.Transport.UDPTest do
  use ExUnit.Case, async: true
  alias SwimEx.Transport.UDP

  test "starts and stops UDP transport" do
    port = 59999
    {:ok, pid} = UDP.start_link(port: port, transport_name: :test_udp)

    # Check that it's alive
    assert Process.alive?(pid)

    # Stop it
    GenServer.stop(pid)

    # Give it a moment to terminate
    refute Process.alive?(pid)
  end

  test "close/1 explicitly closes the socket" do
    port = 59998
    {:ok, pid} = UDP.start_link(port: port, transport_name: :test_udp_close)

    assert :ok = UDP.close(pid)

    # Stop it
    GenServer.stop(pid)
  end
end
