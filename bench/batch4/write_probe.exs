defmodule ExCable.Batch4.WriteProbe do
  @send_event [:thousand_island, :connection, :send]
  @stop_event [:thousand_island, :connection, :stop]

  def start do
    :ok =
      :telemetry.attach_many(__MODULE__, [@send_event, @stop_event], &__MODULE__.observe/4, nil)

    Process.sleep(:infinity)
  end

  # Each transport send runs in the socket owner. Only count broadcast payloads.
  def observe(@send_event, %{data: [[<<0x81>>, _, [~s({"identifier":) | _]]]}, _, _),
    do: count(1)

  def observe(
        @send_event,
        %{data: [[[<<0x81>>, _, [~s({"identifier":) | _]]] | _] = batch},
        _,
        _
      ),
      do: count(length(batch))

  def observe(@stop_event, _, _, _) do
    writes = for size <- 1..4, do: Process.get({__MODULE__, size}, 0)

    if Enum.sum(writes) > 0 do
      IO.puts("batch4_writes " <> Enum.join(writes, ","))
    end
  end

  def observe(_, _, _, _), do: :ok

  defp count(size) do
    key = {__MODULE__, size}
    Process.put(key, Process.get(key, 0) + 1)
  end
end

ExCable.Batch4.WriteProbe.start()
