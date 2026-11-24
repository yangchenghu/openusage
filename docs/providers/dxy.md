# US Dollar Index

Shows the ICE US Dollar Index (DXY, Yahoo symbol `DX-Y.NYB`) from
[Yahoo Finance](https://finance.yahoo.com/quote/DX-Y.NYB)'s public chart data. No account, key, or
sign-in is needed.

## What it tracks

| Metric | Meaning |
|---|---|
| DXY | The latest index value, followed by the change against the previous session's close — green when up, red when down |
| DXY Day Range | The current session's low and high, shown as a span (`103.7490 – 104.4030`) |

Both are on by default. DXY is Always Visible and the day range is On Demand; neither is starred in the
menu bar on a fresh install.

## Refresh

The index refreshes about every minute, on its own cadence — the other providers keep their usual
5-minute schedule. Outside trading hours the values simply stay at the last session's close. Requests
honor the app's proxy setting.

## Errors

- **Couldn't reach Yahoo Finance** — check your network or proxy.
- **Yahoo Finance is rate limiting requests** — Yahoo occasionally throttles; the next refresh usually
  succeeds.
