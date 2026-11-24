defmodule ExCable.BenchMemory do
  @sample_ms 5_000

  def start(directory) do
    if instrument = System.get_env("BENCH_INSTRUMENT") do
      {:module, :instrument} = :code.load_abs(String.to_charlist(instrument))
    end

    spawn(fn ->
      write_settings(directory)

      File.open!(Path.join(directory, "beam.jsonl"), [:write, :raw], fn file ->
        sample_loop(file, directory)
      end)
    end)
  end

  defp write_settings(directory) do
    [{:instance, _, allocator} | _] = :erlang.system_info({:allocator, :binary_alloc})

    settings = %{
      otp: System.otp_release(),
      erts: to_string(:erlang.system_info(:version)),
      schedulers: System.schedulers_online(),
      binary_singleblock_threshold_bytes: allocator[:options][:sbct]
    }

    File.write!(Path.join(directory, "beam-settings.json"), JSON.encode!(settings) <> "\n")
  end

  defp sample_loop(file, directory) do
    snapshot(file, "sample")

    if File.exists?(Path.join(directory, "collect")) do
      Enum.each(Process.list(), &:erlang.garbage_collect(&1, type: :major))
      snapshot(file, "post_major_gc")
      File.touch!(Path.join(directory, "collected"))
    else
      Process.sleep(@sample_ms)
      sample_loop(file, directory)
    end
  end

  defp snapshot(file, phase) do
    memory = Map.new(:erlang.memory())

    allocators =
      Map.new(:erlang.system_info(:alloc_util_allocators), &{&1, allocator_sizes(&1)})

    mseg =
      for {:instance, index, data} <- :erlang.system_info({:allocator, :mseg_alloc}) do
        status = get_in(data, [:memkind, :status])

        %{
          instance: index,
          active_bytes: current(status, :segments_size),
          active_segments: current(status, :segments),
          cached_segments: current(status, :cached_segments),
          cache_hits: current(status, :cache_hits)
        }
      end

    fields = [:memory, :message_queue_len, :garbage_collection_info]

    groups =
      Enum.reduce(Process.list(), %{}, fn pid, groups ->
        case Process.info(pid, fields) do
          nil ->
            groups

          [memory: bytes, message_queue_len: messages, garbage_collection_info: gc] ->
            group = inspect(:proc_lib.translate_initial_call(pid))

            counters = %{
              processes: 1,
              bytes: bytes,
              heap_capacity_words: gc[:heap_block_size] + gc[:old_heap_block_size],
              heap_occupied_words: gc[:heap_size] + gc[:old_heap_size],
              queued_messages: messages
            }

            Map.update(groups, group, counters, fn total ->
              Map.merge(total, counters, fn _, a, b -> a + b end)
            end)
        end
      end)

    data = %{
      utc: DateTime.utc_now() |> DateTime.to_iso8601(),
      phase: phase,
      bytes_per_word: :erlang.system_info(:wordsize),
      vm_memory: memory,
      allocators: allocators,
      mseg: mseg,
      registry_entries:
        if(Process.whereis(ExCable.Registry), do: Registry.count(ExCable.Registry)),
      processes: groups
    }

    data =
      if Process.whereis(ExCable.Registry) && :code.is_loaded(:instrument),
        do: Map.put(data, :detail, binary_detail()),
        else: data

    :ok = :file.write(file, [JSON.encode_to_iodata!(data), "\n"])
  end

  defp binary_detail do
    {:ok, {start, skipped, allocations}} =
      :instrument.allocations(%{allocator_types: [:binary_alloc]})

    listener_port = System.fetch_env!("PORT") |> String.to_integer()

    buffers =
      for port <- Port.list(),
          Port.info(port, :name) == {:name, ~c"tcp_inet"},
          {:ok, {_, local_port}} <- [:inet.sockname(port)],
          {:ok, opts} <- [:inet.getopts(port, [:buffer, :sndbuf, :recbuf])] do
        role = if local_port == listener_port, do: :listener_or_inbound, else: :outbound
        {role, Map.new(opts)}
      end
      |> Enum.frequencies()
      |> Enum.map(fn {{role, opts}, count} -> %{role: role, sockets: count, options: opts} end)

    references =
      for pid <- Process.list(), {:binary, binaries} <- [Process.info(pid, :binary)] do
        {:proc_lib.translate_initial_call(pid), Enum.map(binaries, fn {_, bytes, _} -> bytes end)}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {mfa, sets} ->
        {inspect(mfa),
         sets
         |> List.flatten()
         |> Enum.frequencies()
         |> Map.new(fn {n, count} -> {Integer.to_string(n), count} end)}
      end)

    %{
      histogram_start: start,
      unscanned_bytes: skipped,
      allocation_histograms:
        Map.new(allocations, fn {origin, categories} ->
          {inspect(origin),
           Map.new(categories, fn {kind, bins} -> {kind, Tuple.to_list(bins)} end)}
        end),
      tcp_buffers: buffers,
      referenced_binary_sizes: references
    }
  end

  defp allocator_sizes(allocator) do
    for {:instance, index, sections} <- :erlang.system_info({:allocator_sizes, allocator}) do
      sizes =
        Map.new([:mbcs, :mbcs_pool, :sbcs], fn section ->
          stats = Keyword.get(sections, section, [])

          blocks =
            stats
            |> Keyword.get(:blocks, [])
            |> Enum.sum_by(fn {_, entries} -> current(entries, :size) end)

          {section, %{carrier_bytes: current(stats, :carriers_size), block_bytes: blocks}}
        end)

      Map.put(sizes, :instance, index)
    end
  end

  defp current(values, key) do
    case List.keyfind(values, key, 0) do
      nil -> 0
      entry -> elem(entry, 1)
    end
  end
end
