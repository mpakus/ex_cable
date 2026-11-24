defmodule ExCable.Redis do
  use GenServer
  require Logger

  def children(%{redis_url: nil}), do: []

  def children(config) do
    [
      %{
        id: ExCable.RedisConnection,
        start: {Redix.PubSub, :start_link, [config.redis_url, [name: ExCable.RedisConnection]]}
      },
      {__MODULE__, config.redis_channel}
    ]
  end

  def start_link(channel), do: GenServer.start_link(__MODULE__, channel, name: __MODULE__)

  def ready? do
    GenServer.call(__MODULE__, :ready?, 500)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(channel), do: {:ok, nil, {:continue, {:subscribe, channel}}}

  @impl true
  def handle_continue({:subscribe, channel}, _) do
    {:ok, ref} = Redix.PubSub.subscribe(ExCable.RedisConnection, channel)
    {:noreply, {ref, false}}
  end

  @impl true
  def handle_call(:ready?, _from, {_, ready?} = state), do: {:reply, ready?, state}

  @impl true
  def handle_info({:redix_pubsub, _, ref, :subscribed, _}, {ref, _}), do: {:noreply, {ref, true}}

  def handle_info({:redix_pubsub, _, ref, :disconnected, _}, {ref, _}),
    do: {:noreply, {ref, false}}

  def handle_info({:redix_pubsub, _, ref, :message, %{payload: payload}}, {ref, _} = state) do
    if ExCable.Broadcast.ingest(payload) == :error, do: Logger.warning("Invalid Redis broadcast")
    {:noreply, state}
  end
end
