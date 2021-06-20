defmodule State do
  @enforce_keys [:symbol, :profit_interval, :tick_size]
  defstruct [
    :symbol,
    :buy_order,
    :sell_order,
    :profit_interval,
    :tick_size
  ]
end

defmodule Naive.Trader do
  use GenServer
  require Logger
  require Binance
  alias Streamer.Binance.TradeEvent
  alias Decimal, as: D

  def start_link(%{} = args) do
    GenServer.start_link(__MODULE__, args, name: :trader)
  end

  def init(%{symbol: symbol, profit_interval: profit_interval}) do
    # Binance REST API expects uppercase symbols
    symbol = String.upcase(symbol)
    Logger.info("Initializing new trader for #{symbol}")
    tick_size = fetch_tick_size(symbol)

    state = %State{
      symbol: symbol,
      profit_interval: profit_interval,
      tick_size: tick_size
    }

    {:ok, state}
  end

  # Handle an incoming trade event when we have no buy order
  def handle_cast(
        %TradeEvent{price: price},
        %State{symbol: symbol, buy_order: nil} = state
      ) do
    # <= Hardcoded until chapter 7
    quantity = "100"

    Logger.info("Placing BUY order for #{symbol} @ #{price}, quantity: #{quantity}")

    # Place a buy order
    {:ok, %Binance.OrderResponse{} = order} =
      Binance.order_limit_buy(symbol, quantity, price, "GTC")

    # Store that as our buy order
    {:noreply, %{state | buy_order: order}}
  end

  # Handle an incoming trade event that fills our buy order
  def handle_case(
    %TradeEvent{
      buyer_order_id: order_id,
      quantity: quantity
    },
    %State{
      symbol: symbol,
      buy_order: %Binance.OrderResponse{
        price: buy_price,
        order_id: order_id,
        orig_qty: quantity
      },
      profit_interval: profit_interval,
      tick_size: tick_size
    } = state
  ) do
    # Note: this is a simplification that assumes our buy order gets filled in a single transaction - not guaranteed

    sell_price = calculate_sell_price(buy_price, profit_interval, tick_size)

    Logger.info(
      "Buy order filled, placing SELL order for " <>
        "#{symbol} @ #{sell_price}), quantity: #{quantity}"
    )

    # Place a sell order
    {:ok, %Binance.OrderResponse{} = order} =
      Binance.order_limit_sell(symbol, quantity, sell_price, "GTC")

    # Set the sell order in state
    {:noreply, %{state | sell_order: order}}
  end

  # Handle an incoming trade event that fills our sell order
  def handle_cast(
    %TradeEvent{
      seller_order_id: order_id,
      quantity: quantity
    },
    %State{
      sell_order: %Binance.OrderResponse{
        order_id: order_id,
        orig_qty: quantity
      }
    } = state
  ) do
    Logger.info("Trade finished, trader will now exit")
    {:stop, :normal, state}
  end

  # Ignore any other trade events
  def handle_cast(%TradeEvent{}, state) do
    {:noreply, state}
  end

  defp fetch_tick_size(symbol) do
    {:ok, exchange_info} = Binance.get_exchange_info()

    exchange_info
    |> Map.get(:symbols)
    |> Enum.find(&(&1["symbol"] == symbol))
    |> Map.get("filters")
    |> Enum.find(&(&1["filterType"] == "PRICE_FILTER"))
    |> Map.get("tickSize")
  end

  defp calculate_sell_price(buy_price, profit_interval, tick_size) do
    fee = "1.001"

    original_price = D.mult(buy_price, fee)

    net_target_price =
      D.mult(
        original_price,
        D.add("1.0", profit_interval)
      )

    gross_target_price = D.mult(net_target_price, fee)

    D.to_string(
      D.mult(
        D.div_int(gross_target_price, tick_size),
        tick_size
      ),
      :normal
    )
  end
end
