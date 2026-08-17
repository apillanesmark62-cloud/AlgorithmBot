# AlgorithmBot — MetaTrader 5 Expert Advisors

Two independent MQL5 Expert Advisors. They share no strategy code: each is a
self-contained `.mq5` file with its own logic, inputs and documentation.

Both use **fixed fractional risk** on every trade — position size is a function of
account equity, the configured risk percentage and the stop distance, and nothing
else. Neither EA contains martingale, grid, averaging down, post-loss size
increases or recovery trades.

| EA | Market | Timeframes | Documentation |
|---|---|---|---|
| [`Aggressive_Algorithm_bot`](Experts/Aggressive_Algorithm_bot.mq5) | any | H1 bias/liquidity, M15 execution | [docs](docs/Aggressive_Algorithm_bot.md) |
| [`XAUUSD_Scalper_V1`](Experts/XAUUSD_Scalper_V1.mq5) | XAUUSD | M15 bias, M5 setup, M1 entry | [docs](docs/XAUUSD_Scalper_V1.md) |

## Aggressive_Algorithm_bot

```
H1 liquidity  ->  liquidity grab  ->  M15 MSS/BOS  ->  FVG  ->  retracement  ->  entry
```

Sweeps H1 liquidity, waits for a market-structure shift on M15, then enters
aggressively the moment price returns into the resulting fair value gap — by default
without waiting for a confirmation candle. Attach to an **M15 chart**.

## XAUUSD_Scalper_V1

```
M15 bias  ->  M5 liquidity sweep  ->  M5 MSS/BOS  ->  M5 FVG  ->  M1 retrace + confirmation  ->  entry
```

A deliberately selective gold scalper. An objective M15 swing-structure bias gates
everything; the M5 sweep must penetrate the swept level by a configurable minimum
(a bare touch is rejected); and entry requires a closed M1 rejection candle inside
the gap rather than a simple touch. Attach to an **M1 chart of XAUUSD**.

Its [documentation](docs/XAUUSD_Scalper_V1.md) opens with the formal mathematical
definition of every term the strategy uses — swing high/low, bias, sweep, MSS/BOS,
FVG and the M1 confirmation — which is what the code implements literally.

## Installation

Copy the `.mq5` file you want from `Experts/` into your terminal's `MQL5/Experts/`
folder (MetaEditor → File → Open Data Folder), open it in MetaEditor and press
**F7** to compile. Each EA's documentation page covers its inputs, chart timeframe
and backtesting notes.

## Before running either EA live

- **Session hours are broker server time**, not local time and not UTC. Both EAs
  print the current server time to the Experts log at initialisation — compare that
  line against the real session clock and adjust the hour inputs accordingly.
- **Check the point scaling.** `XAUUSD_Scalper_V1` prints the price distance that
  each point-based input resolves to; gold feeds vary between 2 and 3 digits, which
  changes what "one point" means by a factor of ten.
- **Test on a demo account first**, over several distinct historical periods, and
  judge results on profit factor, drawdown, expected payoff, win rate, average win
  versus average loss and the longest losing streak — not net profit alone.
