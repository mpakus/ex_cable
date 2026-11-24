defmodule ExCable.CLI do
  @default_url "http://127.0.0.1:8080"
  @help """
  Usage: cli [-f | --follow] [--url BASE_URL]

  Print ExCable statistics. Use -f to refresh every second until Ctrl+C.
  Set EX_CABLE_STATS_KEY to the key configured on the server.
  BASE_URL defaults to #{@default_url}.
  """
  @numeric_fields ~w(started_at uptime_ms connections stream_memberships http_broadcasts
                     publications slow_consumers beam_memory_bytes beam_processes)

  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "cli: #{message}")
        System.halt(1)
    end
  end

  def run(args, key \\ System.get_env("EX_CABLE_STATS_KEY")) do
    case OptionParser.parse(args,
           strict: [follow: :boolean, url: :string, help: :boolean],
           aliases: [f: :follow, h: :help]
         ) do
      {opts, [], []} ->
        if opts[:help], do: IO.write(@help), else: execute(opts, key)

      _ ->
        {:error, "Invalid arguments. Run cli --help for usage."}
    end
  end

  defp execute(_opts, key) when key in [nil, ""], do: {:error, "Set EX_CABLE_STATS_KEY"}

  defp execute(opts, key) do
    with {:ok, url} <- endpoint(Keyword.get(opts, :url, @default_url)),
         {:ok, _} <- Application.ensure_all_started(:finch),
         {:ok, client} <-
           Finch.start_link(
             name: __MODULE__,
             pools: %{
               default: [conn_opts: [transport_opts: [timeout: 2_000]]]
             }
           ) do
      request = Finch.build(:get, url, [{"authorization", "Bearer " <> key}])

      try do
        with {:ok, sample} <- fetch(request) do
          output = table(sample, nil)
          IO.write(output)
          if opts[:follow], do: follow(request, sample, output), else: :ok
        end
      after
        Supervisor.stop(client)
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _} -> {:error, "Could not start the HTTP client"}
    end
  end

  defp endpoint(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok,
         URI.to_string(%{uri | path: String.trim_trailing(uri.path || "", "/") <> "/_stats"})}

      _ ->
        {:error, "Expected an HTTP(S) base URL without credentials, a query or a fragment"}
    end
  end

  defp fetch(request) do
    case Finch.request(request, __MODULE__, receive_timeout: 2_000) do
      {:ok, %{status: 200, body: body}} -> decode(body)
      {:ok, %{status: 401}} -> {:error, "Statistics key rejected (HTTP 401)"}
      {:ok, %{status: 404}} -> {:error, "Statistics endpoint not found (HTTP 404)"}
      {:ok, %{status: status}} -> {:error, "Statistics request returned HTTP #{status}"}
      {:error, _} -> {:error, "Could not reach the statistics endpoint"}
    end
  end

  defp decode(body) do
    with {:ok, %{"redis" => redis} = sample} when redis in ["disabled", "ready", "unavailable"] <-
           JSON.decode(body),
         true <- Enum.all?(@numeric_fields, &(is_integer(sample[&1]) and sample[&1] >= 0)) do
      {:ok, sample}
    else
      _ -> {:error, "Invalid statistics response"}
    end
  end

  defp follow(request, sample, output) do
    terminal? = match?({:ok, _}, :io.columns()) and System.get_env("TERM") != "dumb"
    follow(request, sample, output, terminal?, output)
  end

  defp follow(request, previous, table, terminal?, displayed) do
    Process.sleep(1_000)

    case fetch(request) do
      {:ok, sample} ->
        output = table(sample, previous)
        IO.write(frame(output, displayed, terminal?))
        follow(request, sample, output, terminal?, output)

      {:error, message} ->
        output = table <> "Refresh failed. #{message}. Retrying.\n"
        IO.write(frame(output, displayed, terminal?))
        follow(request, previous, table, terminal?, output)
    end
  end

  def frame(output, previous, true) do
    lines = length(:binary.matches(previous, "\n"))
    "\e[#{lines}F\e[J" <> output
  end

  def frame(output, _previous, false), do: output

  def table(sample, previous) do
    recent? =
      previous != nil and previous["started_at"] == sample["started_at"] and
        previous["uptime_ms"] < sample["uptime_ms"]

    baseline = if recent?, do: previous, else: %{"uptime_ms" => 0}
    period = if recent?, do: "last successful sample", else: "startup"

    rows = [
      {"Uptime", "#{div(sample["uptime_ms"], 1000)} s"},
      {"Active WebSockets", sample["connections"]},
      {"Stream memberships", sample["stream_memberships"]},
      {"Accepted broadcast POSTs", total_and_rate(sample, baseline, "http_broadcasts")},
      {"Stream publications", total_and_rate(sample, baseline, "publications")},
      {"Slow consumers flagged", sample["slow_consumers"]},
      {"BEAM memory", decimal(sample["beam_memory_bytes"] / 1_048_576) <> " MiB"},
      {"BEAM processes", sample["beam_processes"]},
      {"Redis subscription", sample["redis"]}
    ]

    body =
      Enum.map_join(rows, "\n", fn {label, value} ->
        String.pad_trailing(label, 24) <> " | #{value}"
      end)

    "ExCable statistics · rates since #{period}\n" <>
      "Metric                   | Value\n" <>
      "-------------------------+----------------\n" <> body <> "\n"
  end

  defp total_and_rate(sample, baseline, key) do
    elapsed = max(sample["uptime_ms"] - baseline["uptime_ms"], 1)
    rate = max(sample[key] - Map.get(baseline, key, 0), 0) * 1000 / elapsed
    "#{sample[key]} (#{decimal(rate)}/s)"
  end

  defp decimal(value), do: :erlang.float_to_binary(value, decimals: 2)
end
