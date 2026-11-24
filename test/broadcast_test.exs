defmodule ExCable.BroadcastTest do
  use ExUnit.Case, async: true
  alias ExCable.Broadcast

  test "caps pending messages and signals the slow consumer once" do
    budget = Broadcast.budget()
    stream = unique_stream()
    id = "room"
    membership = Broadcast.join_stream(stream, id, "sid", budget)
    payload = JSON.encode!(%{stream: stream, data: "1"})

    for _ <- 1..200, do: assert(Broadcast.ingest(payload) == :ok)

    for _ <- 1..128 do
      assert_received {:broadcast, ^stream, ^id, ^membership, "1"}
      Broadcast.received(budget)
    end

    assert_received :slow_consumer
    refute_received :slow_consumer
    refute_received {:broadcast, _, _, _, _}
    assert :ok == Broadcast.ingest(payload)
    refute_received {:broadcast, _, _, _, _}
  end

  test "invalid batches deliver nothing and excluded sockets receive nothing" do
    budget = Broadcast.budget()
    stream = unique_stream()
    id = "room"
    membership = Broadcast.join_stream(stream, id, "sid", budget)
    event = %{stream: stream, data: "1"}
    assert :error == Broadcast.ingest(JSON.encode!([event, %{stream: stream, data: "1 2"}]))
    refute_received {:broadcast, _, _, _, _}

    assert :ok == Broadcast.ingest(JSON.encode!(Map.put(event, :meta, %{exclude_socket: "sid"})))
    refute_received {:broadcast, _, _, _, _}
    assert :ok == Broadcast.ingest(JSON.encode!(event))
    assert_received {:broadcast, ^stream, ^id, ^membership, "1"}
  end

  test "rejects malformed JSON, empty batches and oversized Redis publications" do
    for invalid <- ["{", "[]", "true", :binary.copy("x", 65_537)] do
      assert :error == Broadcast.ingest(invalid)
    end
  end

  defp unique_stream, do: "stream:" <> Integer.to_string(System.unique_integer([:positive]))
end
