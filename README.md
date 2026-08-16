# Aggressive Algorithm Bot (MQL5)

MetaTrader 5 Expert Advisor implementing the sequence:

```
H1 liquidity  ->  liquidity grab  ->  M15 MSS/BOS  ->  FVG  ->  retracement  ->  entry
```

Source: [`Experts/Aggressive_Algorithm_bot.mq5`](Experts/Aggressive_Algorithm_bot.mq5)

The EA uses **fixed fractional risk on every trade**. It contains no martingale, no
grid, no averaging down, no lot increase after a loss and no recovery/revenge logic.
Position size is derived only from account equity, `RiskPercent` and the stop
distance, so a losing trade never enlarges the next one.

## Installation

1. Copy `Experts/Aggressive_Algorithm_bot.mq5` into your terminal's
   `MQL5/Experts/` folder (MetaEditor → File → Open Data Folder).
2. Open it in MetaEditor and press **F7** to compile.
3. Attach it to an **M15 chart** of the symbol you want to trade and allow
   algorithmic trading.

The EA reads H1 and M15 data from the chart symbol regardless of the chart's own
timeframe, but M15 is the intended chart because the bar clock drives the state
machine.

## How it works

| Stage | Timeframe | Rule |
|---|---|---|
| Swing structure | H1 | A swing high/low needs `H1_SwingStrength` higher-high/lower-low bars on both sides, and is only used once those bars have closed. |
| Liquidity grab | H1 | A closed candle wicks beyond a confirmed swing and closes back on the original side. The sweep may be at most `MaxSweepAgeBars` H1 bars old. |
| MSS / BOS | M15 | After the sweep, a closed M15 candle must close beyond the most recent confirmed M15 swing formed after the sweep. |
| FVG | M15 | Three-candle gap (`A.high < C.low` bullish, `A.low > C.high` bearish), at least `MinFVGPoints` wide. Gaps formed after the MSS are preferred; gaps formed after the sweep are the fallback. |
| Entry | tick | Price trading back into the zone triggers a market order. With `UseFVG50Entry` the trigger is the midpoint instead of the near edge. |

All structure detection runs on **closed candles only**, once per new M15 bar
(`IsNewBar()`). Tick-level processing is limited to detecting price entering an
already-confirmed FVG, exactly as specified.

A setup is discarded when it does not complete within `SetupExpirationBars`
M15 bars, when price closes back beyond the sweep extreme, or once it has
produced a trade (each sweep timestamp is a unique setup ID and can trade only
once).

## Risk and stops

- **Stop loss** — `SweepLow - SL_BufferPoints` (buy) or `SweepHigh + SL_BufferPoints`
  (sell), validated against the broker's stops level, freeze level and the
  current spread. An invalid distance rejects the trade; SL/TP are never
  shrunk to make a trade fit.
- **Take profit** — `entry ± risk × RiskReward`.
- **Lot size** — `equity × RiskPercent%` divided by the money value of the stop
  distance, computed from `SYMBOL_TRADE_TICK_VALUE_LOSS` and
  `SYMBOL_TRADE_TICK_SIZE`, then floored to `SYMBOL_VOLUME_STEP` and clamped to
  `SYMBOL_VOLUME_MIN/MAX` and `MaxLotSize`. If honouring the risk would require
  less than the broker's minimum lot, the trade is **rejected** rather than
  rounded up.
- **Daily limits** — trade count and realized+floating P/L for the day are
  rebuilt from deal history filtered by magic number and symbol, so the limits
  survive a terminal restart.

## Sessions — read this before going live

`LondonStartHour`, `NewYorkStartHour`, `AsianStartHour` and their end hours are
**broker/server time, not your local time and not UTC**. Server time is printed
to the Experts log on every initialisation:

```
Current server time: 2026.08.16 14:35
```

Compare that line with the real London/New York clock and shift the hours
accordingly. A broker on UTC+3 with default settings is trading roughly
05:00–14:00 and 10:00–19:00 UTC, which is probably not what you intended.
Ranges that wrap past midnight (e.g. 22 → 6) are handled. Disabling all three
sessions removes the time filter entirely.

## Inputs

| Group | Input | Default |
|---|---|---|
| Structure | `H1_SwingStrength` / `H1_LookbackBars` | 3 / 100 |
| | `M15_SwingStrength` / `M15_LookbackBars` | 2 / 100 |
| Liquidity | `MaxSweepAgeBars` (H1 bars) | 30 |
| | `SetupExpirationBars` (M15 bars) | 16 |
| FVG | `MinFVGPoints` | 20 |
| | `UseFVG50Entry` | false |
| | `RequireEntryConfirmation` | false |
| Risk | `RiskPercent` / `RiskReward` | 1.0 / 2.0 |
| | `SL_BufferPoints` / `MaxLotSize` | 20 / 1.00 |
| Limits | `MaxTradesPerDay` / `MaxOpenPositions` | 5 / 1 |
| | `MaxDailyLossPercent` / `MaxSpreadPoints` | 3.0 / 50 |
| Sessions | `UseLondonSession` / `UseNewYorkSession` / `UseAsianSession` | true / true / false |
| Display | `ShowDebugObjects` / `ShowDashboard` | true / true |
| Execution | `MagicNumber` / `MaxSlippagePoints` / `TradeComment` | 20250816 / 20 / AggAlgoBot |

`RequireEntryConfirmation = false` is what makes the EA aggressive: it enters the
moment price touches the zone, without waiting for a confirming candle. Setting
it to `true` requires a closed M15 candle that tags the zone and closes in the
trade's direction.

## Chart output

With `ShowDebugObjects` the EA draws confirmed H1 swings, the swept level, the
sweep point, the MSS/BOS level, the FVG rectangle and — while a trade is live —
entry, stop and target. Objects are named per setup (`AAB_<sweep timestamp>_…`)
and removed when the setup closes. `ShowDashboard` adds a status panel with the
state, setup direction, liquidity/MSS/FVG status, spread, session, trades today,
daily P/L and risk per trade.

Turn both off for optimisation runs — chart objects slow the tester down
considerably.

## Backtesting

Use **Every tick based on real ticks** where your broker provides them, on the
M15 chart of the symbol.

Points to check, rather than net profit alone: profit factor, maximum drawdown,
expected payoff, number of trades, win rate, average win vs average loss,
longest run of consecutive losses, and recovery factor. Run several distinct
historical periods (trending, ranging, high and low volatility), and keep a
hold-out window that you never optimise on for the final out-of-sample check.

Two caveats specific to this strategy:

- Spread matters. `MaxSpreadPoints` rejects entries during wide-spread periods,
  so a tester run with an unrealistically tight fixed spread will overstate the
  number of trades.
- Small `MinFVGPoints` values on a low-volatility symbol produce many marginal
  gaps; raise it until the zones it finds are ones you would trade by hand.

## Limitations

- Setup state is not persisted across a terminal restart. If a position is open
  the EA recovers to `TRADE_OPENED` and manages it to its stops; a half-formed
  setup (sweep found, no entry yet) is rebuilt from history on the next bar
  instead of being restored verbatim.
- Daily P/L is computed from this EA's own deals on this symbol. Trades placed
  manually or by another EA on the same account are not counted toward
  `MaxDailyLossPercent`.
- SL and TP are set at entry and are not trailed or moved afterwards.
