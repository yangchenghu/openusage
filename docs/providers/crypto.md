# Crypto Prices

Shows live spot prices for the coins you choose, quoted against USDT, from
[OKX](https://www.okx.com)'s public market data. No account, key, or sign-in is needed.

## What it tracks

For each coin in your list:

| Metric | Meaning |
|---|---|
| BTC (one per coin) | The last traded price, followed by the 24-hour change — green when up, red when down |
| BTC 24h Range (one per coin) | The 24-hour low and high, shown as a span (`65,813.00 – 69,132.90`) |

The price rows are Always Visible and the range rows are On Demand by default; the first coin's price
is starred in the menu bar on a fresh install. Prices of 1,000 and up show 2 decimals, prices from 1
show 4, and smaller prices show 8. The menu bar drops the cents on four-figure prices to stay short.

## Choosing coins

Open **Customize → Crypto Prices**. In the **Coins** card, type the coins separated by spaces or commas
(`BTC ETH SOL`, `btc/usdt`, and `BTC-USDT` all work), then click **Apply & Restart**. The coin list
decides which rows exist, so OpenUsage restarts itself to apply it. **Use Defaults** restores the
starting list: BTC, ETH, SOL, GRAM, HYPE, PEPE, OKB, XAUT.

A coin OKX doesn't trade against USDT shows **Not Listed** instead of a price. The **API Address**
field changes the OKX host (default `https://www.okx.com`), for example to a regional mirror. Requests
honor the app's proxy setting.

## Refresh

Prices refresh about every 15 seconds, on their own cadence — the other providers keep their usual
5-minute schedule. Each coin is one small request, made in parallel. If some coins fail to load, the
rest still update and a warning names the ones that didn't; if every coin fails, the card shows the
error.
