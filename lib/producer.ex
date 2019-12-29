defmodule OffBroadwayRedisStream.Producer do
  @moduledoc """
  A GenStage Producer for Redis Stream.
  Acts as a unique consumer in specified Consumer Group. see https://redis.io/topics/streams-intro.

  Note: Successfully handled messaged are acknowledged automatically. Failure needs to be handled by the consumer
  by explicitly.

  ## Options for `OffBroadwayRedisStream.RedixClient`

    * `:redis_instance` - Required. Redix instance must started separately and name of that instance needs to be passed. For more infromation see [Redix Documentation](https://hexdocs.pm/redix/Redix.html#start_link/1)

    * `:stream` - Required. Redis stream name

    * `:consumer_group` - Required. Redis consumer group

    * `:consumer_name` - Required. Redis Consumer name for the producer

    * `:on_failure` - Optional. Behaviour when consumer fails to proccess message. See Acknowledgments section below. Default is `:ack`

  ## Producer Options

  These options applies to all producers, regardless of client implementation:

    * `:client` - Optional. A module that implements the `OffBroadwayRedisStream.RedisClient`
      behaviour. This module is responsible for fetching and acknowledging the
      messages. Pay attention that all options passed to the producer will be forwarded
      to the client. It's up to the client to normalize the options it needs. Default
      is `OffBroadwayRedisStream.RedixClient`.

    * `:receive_interval` - Optional. The duration (in milliseconds) for which the producer
      waits before making a request for more messages. Default is 5000.

  ## Acknowledgments

  In case of successful processing, the message is properly acknowledge to Redis Consumer Group.
  In case of failures, no message is acknowledged, which means Message will wont be removed from pending entries list (PEL). As of now consumer have to handle failure scenario to clean up pending entries. For more information, see: [Recovering from permanent failures](https://redis.io/topics/streams-intro#recovering-from-permanent-failures)

  You can use the and `:on_failure` option to control how messages are acked on consumer group.
  By default successful messages are acked and failed messages are not acked and messages are reenqueued to main stream after .
  You can set `:on_failure` when starting the producer,
  or change them for each message through `Broadway.Message.configure_ack/2`
  Here is the list of all possible values supported by `:on_failure`:
  * `:ack` - Acknowledge the message. RedixClient will mark the message as acked.
  * `:ignore` - Don't do anything. It won't notify to Redis consumer group, and it will stay in pending entries list of consumer group.

  ## Message Data

  Message data is a 2 element list. First item is id of the message, second is the data
  """

  use GenStage
  alias Broadway.Producer
  @behaviour Producer

  @default_receive_interval 5000

  @impl GenStage
  def init(opts) do
    client = opts[:client] || OffBroadwayRedisStream.RedixClient
    receive_interval = opts[:receive_interval] || @default_receive_interval

    case client.init(opts) do
      {:error, message} ->
        raise ArgumentError, "invalid options given to #{inspect(client)}.init/1, " <> message

      {:ok, opts} ->
        {:producer,
         %{
           demand: 0,
           redis_client: {client, opts},
           receive_timer: nil,
           receive_interval: receive_interval
         }}
    end
  end

  @impl GenStage
  def handle_demand(demand, state) do
    receive_messages(%{state | demand: state.demand + demand})
  end

  @impl GenStage
  def handle_info(:receive_messages, %{receive_timer: nil} = state) do
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info(:receive_messages, state) do
    receive_messages(%{state | receive_timer: nil})
  end

  @impl GenStage
  def handle_info(_, state) do
    {:noreply, [], state}
  end

  @impl Producer
  def prepare_for_draining(%{receive_timer: receive_timer} = state) do
    receive_timer && Process.cancel_timer(receive_timer)
    {:noreply, [], %{state | receive_timer: nil}}
  end

  defp receive_messages(%{receive_timer: nil, demand: demand} = state) when demand > 0 do
    {client, opts} = state.redis_client
    messages = client.receive_messages(state.demand, opts)
    new_demand = demand - length(messages)

    receive_timer =
      case {messages, new_demand} do
        {[], _} -> schedule_receive_messages(state.receive_interval)
        {_, 0} -> nil
        _ -> schedule_receive_messages(0)
      end

    {:noreply, messages, %{state | demand: new_demand, receive_timer: receive_timer}}
  end

  defp receive_messages(state) do
    {:noreply, [], state}
  end

  defp schedule_receive_messages(interval) do
    Process.send_after(self(), :receive_messages, interval)
  end
end
