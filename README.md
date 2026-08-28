# AlgorithmBot — MetaTrader 5 Expert Advisors

Three independent MQL5 Expert Advisors. They share no strategy code: each is a
self-contained `.mq5` file with its own logic, inputs and documentation.

All three use **fixed fractional risk** on every trade — position size is a function
of account equity, the configured risk percentage and the stop distance, and nothing
else. None contains martingale, grid, averaging down, post-loss size increases or
revenge trades.

| EA | Market | Timeframes | Chart | Documentation |
|---|---|---|---|---|
| [`Aggressive_Algorithm_bot`](Experts/Aggressive_Algorithm_bot.mq5) | any | H1 liquidity, M15 execution | M15 | [docs](docs/Aggressive_Algorithm_bot.md) |
| [`XAUUSD_Scalper_V1`](Experts/XAUUSD_Scalper_V1.mq5) | XAUUSD | M15 bias, M5 setup, M1 entry | M1 | [docs](docs/XAUUSD_Scalper_V1.md) |
| [`XAUUSD_VWAP_RSI_Scalper_V1`](Experts/XAUUSD_VWAP_RSI_Scalper_V1.mq5) | any (tuned for XAUUSD) | M5 | M5 | [docs](docs/XAUUSD_VWAP_RSI_Scalper_V1.md) |

## Aggressive_Algorithm_bot

```
H1 liquidity  ->  liquidity grab  ->  M15 MSS/BOS  ->  FVG  ->  retracement  ->  entry
```

Sweeps H1 liquidity, waits for a market-structure shift on M15, then enters
aggressively the moment price returns into the resulting fair value gap — by default
without waiting for a confirmation candle.

## XAUUSD_Scalper_V1

```
M15 bias  ->  M5 liquidity sweep  ->  M5 MSS/BOS  ->  M5 FVG  ->  M1 retrace + confirmation  ->  entry
```

A deliberately selective gold scalper. An objective M15 swing-structure bias gates
everything; the M5 sweep must penetrate the swept level by a configurable minimum
(a bare touch is rejected); and entry requires a closed M1 rejection candle inside
the gap rather than a simple touch.

## XAUUSD_VWAP_RSI_Scalper_V1

```
Close vs session VWAP  +  RSI(14) midline cross  ->  entry
```

The simplest of the three, and the only one built on indicators rather than price
structure. Session VWAP is computed internally from the closed M5 bars of the
current server day and resets each day; a BUY needs the candle to close above VWAP
while RSI crosses up through the midline, a SELL the mirror. Stops go beyond the
most recent confirmed M5 swing. Entry conditions are evaluated exactly once per
closed M5 candle — there is no tick-level entry path at all.

The symbol is never hard-coded; only the defaults are gold-specific.

## Definitions first

`XAUUSD_Scalper_V1` and `XAUUSD_VWAP_RSI_Scalper_V1` both open their documentation
with the exact mathematical definition of every term the strategy uses — swing
high/low, bias, sweep, MSS/BOS, FVG, VWAP, RSI cross, position sizing, daily loss
and new-candle detection — which is what the code implements literally.

## Installation

Copy the `.mq5` file you want from `Experts/` into your terminal's `MQL5/Experts/`
folder (MetaEditor → File → Open Data Folder), open it in MetaEditor and press
**F7** to compile. Each EA's documentation page covers its inputs, chart timeframe
and backtesting notes.

## Before running any of these live

- **Session hours are broker server time**, not local time and not UTC. Every EA
  prints the current server time to the Experts log at initialisation — compare that
  line against the real session clock and adjust the hour inputs accordingly.
- **Check the point scaling.** Both gold EAs print the price distance each
  point-based input resolves to; gold feeds vary between 2 and 3 digits, which
  changes what "one point" means by a factor of ten.
- **Test on a demo account first**, over several distinct historical periods, and
  judge results on profit factor, drawdown, expected payoff, win rate, average win
  versus average loss and the longest losing streak — not net profit alone.
