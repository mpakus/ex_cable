defmodule ExCable.Stats do
  @counters %{http_broadcasts: 1, publications: 2, slow_consumers: 3}

  def init do
    :persistent_term.put(__MODULE__, {
      :counters.new(map_size(@counters), [:write_concurrency]),
      System.monotonic_time(:millisecond),
      System.system_time(:microsecond)
    })
  end

  def increment(metric) do
    {ref, _, _} = :persistent_term.get(__MODULE__)
    :counters.add(ref, Map.fetch!(@counters, metric), 1)
  end

  def snapshot(config) do
    {ref, started, started_at} = :persistent_term.get(__MODULE__)

    %{
      started_at: started_at,
      uptime_ms: System.monotonic_time(:millisecond) - started,
      connections: count(:connection),
      stream_memberships: count(:stream),
      http_broadcasts: :counters.get(ref, @counters.http_broadcasts),
      publications: :counters.get(ref, @counters.publications),
      slow_consumers: :counters.get(ref, @counters.slow_consumers),
      beam_memory_bytes: :erlang.memory(:total),
      beam_processes: :erlang.system_info(:process_count),
      redis: redis_status(config)
    }
  end

  defp count(kind),
    do: Registry.count_select(ExCable.Registry, [{{{kind, :_}, :_, :_}, [], [true]}])

  defp redis_status(%{redis_url: nil}), do: "disabled"
  defp redis_status(_), do: if(ExCable.Redis.ready?(), do: "ready", else: "unavailable")
end
