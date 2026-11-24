defmodule ExCable.CLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias ExCable.TestWire, as: Wire

  test "the terminal command explains its options and reports unavailable statistics" do
    assert capture_io(fn -> :ok = Mix.Tasks.Cli.run(["--help"]) end) =~ "--follow"
    assert {:error, "Set EX_CABLE_STATS_KEY"} = ExCable.CLI.run([], "")
    assert {:error, "Invalid arguments." <> _} = ExCable.CLI.run(["--unknown"], "stats")

    assert {:error, "Expected an HTTP(S) base URL" <> _} =
             ExCable.CLI.run(["--url", "/"], "stats")

    port = Wire.listen({ExCable.HTTP, ExCable.Config.defaults()})

    assert {:error, "Statistics endpoint not found (HTTP 404)"} =
             ExCable.CLI.run(["--url", url(port)], "stats")
  end

  test "statistics require the configured key" do
    disabled = Wire.listen({ExCable.HTTP, ExCable.Config.defaults()})
    enabled = Wire.listen({ExCable.HTTP, %{ExCable.Config.defaults() | stats_key: "stats"}})

    assert stats(disabled, "stats").status == 404
    assert stats(enabled, "wrong").status == 401
    assert stats(enabled, "stats").status == 200
  end

  test "the CLI reads the running server and includes anonymous sockets and accepted broadcasts" do
    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn
           "/rpc/connect", _, _ -> {200, %{status: 1}}
           "/rpc/command", _, _ -> {200, %{status: 1, streams: ["stats-room"]}}
           "/rpc/disconnect", _, _ -> {200, %{status: 1}}
         end}
      )

    config = %{
      ExCable.Config.defaults()
      | rpc_url: "http://127.0.0.1:#{backend}/rpc",
        stats_key: "stats",
        broadcast_secret: "broadcast"
    }

    port = Wire.listen({ExCable.HTTP, config})
    before = snapshot(port)
    client = Wire.connect(port)
    assert {%{"type" => "welcome"}, client} = Wire.event(client)
    client = Wire.command(client, "subscribe", ~s({"channel":"StatsChannel"}))
    assert {%{"type" => "confirm_subscription"}, client} = Wire.event(client)

    body = JSON.encode!(%{stream: "stats-room", data: "42"})
    assert request(port, :post, "/_broadcast", "broadcast", body).status == 201
    assert request(port, :post, "/_broadcast", "broadcast", "{}").status == 422
    assert {%{"message" => 42}, client} = Wire.event(client)

    after_broadcast = snapshot(port)
    assert after_broadcast["connections"] == before["connections"] + 1
    assert after_broadcast["stream_memberships"] == before["stream_memberships"] + 1
    assert after_broadcast["http_broadcasts"] == before["http_broadcasts"] + 1
    assert after_broadcast["publications"] == before["publications"] + 1

    output = capture_io(fn -> assert ExCable.CLI.run(["--url", url(port)], "stats") == :ok end)
    assert output =~ "ExCable statistics"
    assert output =~ ~r/Active WebSockets\s*\|\s*1\b/
    assert output =~ "BEAM memory"

    assert {:error, "Statistics key rejected (HTTP 401)"} =
             ExCable.CLI.run(["--url", url(port)], "wrong")

    Wire.close(client)
  end

  test "follow frames replace the table and calculate rates from consecutive server samples" do
    sample = %{
      "started_at" => 1,
      "uptime_ms" => 10_000,
      "connections" => 2,
      "stream_memberships" => 3,
      "http_broadcasts" => 50,
      "publications" => 100,
      "slow_consumers" => 0,
      "beam_memory_bytes" => 1_048_576,
      "beam_processes" => 100,
      "redis" => "disabled"
    }

    next = %{sample | "uptime_ms" => 12_000, "http_broadcasts" => 90, "connections" => 3}
    first = ExCable.CLI.table(sample, nil)
    second = ExCable.CLI.table(next, sample)
    assert first =~ "50 (5.00/s)"
    assert second =~ "90 (20.00/s)"
    assert second =~ ~r/Active WebSockets\s*\|\s*3\b/
    assert ExCable.CLI.frame(second, first, true) =~ ~r/^\e\[\d+F\e\[JExCable statistics/
    assert ExCable.CLI.frame(second, first, false) == second

    restarted = %{next | "started_at" => 2, "uptime_ms" => 1000, "http_broadcasts" => 1}
    assert ExCable.CLI.table(restarted, next) =~ "1 (1.00/s)"
  end

  defp url(port), do: "http://127.0.0.1:#{port}"

  defp stats(port, key), do: request(port, :get, "/_stats", key, nil)

  defp snapshot(port), do: port |> stats("stats") |> Map.fetch!(:body) |> JSON.decode!()

  defp request(port, method, path, key, body) do
    method
    |> Finch.build(url(port) <> path, [{"authorization", "Bearer " <> key}], body)
    |> Finch.request!(ExCable.Finch)
  end
end
