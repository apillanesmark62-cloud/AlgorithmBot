# XAUUSD_Scalper_V1 — strategy definitions and usage

Source: [`Experts/XAUUSD_Scalper_V1.mq5`](../Experts/XAUUSD_Scalper_V1.mq5)

```
M15 bias  ->  M5 liquidity sweep  ->  M5 MSS/BOS  ->  M5 FVG  ->  M1 retrace + M1 confirmation  ->  entry
```

This EA shares no strategy logic with `Aggressive_Algorithm_bot`. It is a separate,
self-contained scalper built for XAUUSD.

---

## Part 1 — Formal definitions

Everything below is stated before the code and is implemented literally.

### Notation

For a timeframe `TF`, bars are indexed **series-style**: index `0` is the currently
forming (unclosed) bar, index `1` is the most recently *closed* bar, index `2` the one
before it, and so on. **Larger index = older bar.**

| Symbol | Meaning |
|---|---|
| `O[i], H[i], L[i], C[i]` | open / high / low / close of bar `i` |
| `T[i]` | open time of bar `i` |
| `K15` | `M15_SwingStrength` (default 2) |
| `K5` | `M5_SwingStrength` (default 2) |
| `P` | price value of one input "point" after digit scaling (see *Point scaling*) |

**No definition below ever reads bar 0.** Every structural test uses closed bars only,
and a swing is only usable once the bars that confirm it have themselves closed.

---

### 1. M15 swing high

Bar `i` on M15 is a **confirmed swing high** if and only if all of the following hold:

```
(1a)  i >= K15 + 1                        // the K15 bars after it are closed bars
(1b)  H[i] > H[i+k]   for all k = 1..K15  // strictly higher than the K15 older bars
(1c)  H[i] > H[i-k]   for all k = 1..K15  // strictly higher than the K15 newer bars
```

Strict `>` on both sides, so a flat double-top plateau does not register as a swing.
Condition (1a) is what makes it *confirmed*: the swing is invisible to the EA until
`K15` fully closed bars exist to its right, which removes any possibility of using a
pivot that has not formed yet.

### 2. M15 swing low

Bar `i` on M15 is a **confirmed swing low** iff:

```
(2a)  i >= K15 + 1
(2b)  L[i] < L[i+k]   for all k = 1..K15
(2c)  L[i] < L[i-k]   for all k = 1..K15
```

### 3. M15 bullish bias

Let, scanning from newest to oldest over `M15_LookbackBars`:

- `SH1, SH2` = the two most recent confirmed M15 swing highs (`SH1` newer than `SH2`)
- `SL1, SL2` = the two most recent confirmed M15 swing lows (`SL1` newer than `SL2`)

If fewer than two of either exist, bias is **NONE**.

```
BULLISH  iff  H[SH1] > H[SH2]          // higher high
        and   L[SL1] > L[SL2]          // higher low
        and   C[1]   > L[SL1]          // structure not broken: last closed M15
                                       // close is still above the latest swing low
```

### 4. M15 bearish bias

```
BEARISH  iff  H[SH1] < H[SH2]          // lower high
        and   L[SL1] < L[SL2]          // lower low
        and   C[1]   < H[SH1]          // structure not broken
```

**Bias is NONE** whenever neither the bullish nor the bearish condition is fully
satisfied — including a higher-high/lower-low mix, an unbroken-but-conflicting
structure, or insufficient history. Bias NONE means **no new setups are started and
no trade is taken**. The three states are mutually exclusive by construction
(`H[SH1] > H[SH2]` and `H[SH1] < H[SH2]` cannot both hold).

Bias is re-evaluated on every closed M5 bar and is re-checked immediately before
order submission; if it no longer matches the setup direction, the setup is cancelled.

### 5. M5 swing high

Bar `i` on M5 is a **confirmed swing high** iff:

```
(5a)  i >= K5 + 1
(5b)  H[i] > H[i+k]   for all k = 1..K5
(5c)  H[i] > H[i-k]   for all k = 1..K5
```

### 6. M5 swing low

```
(6a)  i >= K5 + 1
(6b)  L[i] < L[i+k]   for all k = 1..K5
(6c)  L[i] < L[i-k]   for all k = 1..K5
```

### 7. M5 liquidity sweep

A **bullish liquidity sweep** occurs at closed M5 bar `j` iff there exists a confirmed
M5 swing low at index `s` such that:

```
(7a)  s >= j + K5 + 1                     // the swing was already confirmed before
                                          // bar j closed (all its confirming bars
                                          // are strictly older than j)
(7b)  L[j] <  L[s] - SweepMinPenetration*P   // genuine penetration, not a touch
(7c)  C[j] >  L[s]                        // closes back above the swept level
(7d)  1 <= j <= MaxSweepAgeBars           // recent enough to still be relevant
(7e)  bias == BULLISH
```

`s` is the **smallest** index satisfying (7a) and the swing-low test, i.e. the most
recent swing low that was available when bar `j` closed.

Condition (7b) is the answer to "do not treat a simple touch as a sweep": price must
close through the level by at least `SweepMinPenetration` points, so an exact tag of
the low, or a one-tick undercut, is rejected.

Recorded on success: `SweptLevel = L[s]`, `SweepExtreme = L[j]` (the sweep low used
for the stop), `SweepTime = T[j]`, and `SetupID = T[j]` (unique — one trade maximum
per sweep).

A **bearish liquidity sweep** is the mirror:

```
(7a')  s >= j + K5 + 1
(7b')  H[j] >  H[s] + SweepMinPenetration*P
(7c')  C[j] <  H[s]
(7d')  1 <= j <= MaxSweepAgeBars
(7e')  bias == BEARISH
```

with `SweptLevel = H[s]`, `SweepExtreme = H[j]`.

### 8. M5 MSS / BOS

Let `j` be the index of the sweep bar (recomputed from `SweepTime` on every new bar,
since indices shift as bars form).

**Bullish MSS/BOS** is confirmed at closed bar `b` iff:

```
(8a)  1 <= b < j                          // b is strictly after the sweep in time
(8b)  s = min{ i : IsSwingHigh5(i)  and  b + K5 + 1 <= i <= j + MSSSwingSearchBars }
                                          // most recent M5 swing high that was
                                          // confirmed at the time bar b closed
(8c)  C[b] > H[s]                         // CLOSE above it, not just a wick
```

The search window in (8b) extends `MSSSwingSearchBars` bars *older* than the sweep, so
the swing high being broken may be the one that formed before the sweep (the classic
market-structure shift) or one that formed after it. The **earliest** qualifying `b` is
taken, so the EA reacts to the first structural break rather than the latest one.

Recorded: `MSSLevel = H[s]`, `MSSTime = T[b]`, `MSSIndexTime` for ordering the FVG.

**Bearish MSS/BOS** is the mirror: `s` is the most recent confirmed M5 swing low in the
same window and `C[b] < L[s]`.

Per the specification, MSS/BOS alone never triggers an entry — it only unlocks the FVG
search.

### 9. M5 bullish FVG

Three consecutive M5 candles, with candle 3 the newest, at indices `c+2` (candle 1),
`c+1` (candle 2), `c` (candle 3). A **bullish FVG** exists at `c` iff:

```
(9a)  L[c] > H[c+2]                              // candle 3 low > candle 1 high
(9b)  L[c] - H[c+2] >= MinimumFVGSize * P        // minimum gap width
(9c)  c <= b                                     // candle 3 closed at or after the
                                                 // MSS break bar, i.e. the gap did
                                                 // not exist before the MSS
(9d)  H[c+2] > SweepExtreme                      // zone sits above the sweep low, so
                                                 // the stop stays behind the sweep
(9e)  C[1] > H[c+2]                              // gap not already filled through
```

Zone: `FVGLow = H[c+2]`, `FVGHigh = L[c]`. The **most recent** qualifying `c` (smallest
index) is used.

### 10. M5 bearish FVG

```
(10a)  H[c] < L[c+2]                             // candle 3 high < candle 1 low
(10b)  L[c+2] - H[c] >= MinimumFVGSize * P
(10c)  c <= b
(10d)  L[c+2] < SweepExtreme
(10e)  C[1] < L[c+2]
```

Zone: `FVGLow = H[c]`, `FVGHigh = L[c+2]`.

### 11. M1 bullish entry confirmation

Evaluated **only** on closed M1 bar index `1`, and only while a bullish setup is in
`WAIT_RETRACE` / `WAIT_CONFIRM`. Let `R = H[1] - L[1]`.

```
(11a)  R > 0
(11b)  L[1] <= FVGHigh  and  H[1] >= FVGLow      // the bar traded inside the zone
                                                 // (this is the retracement itself)
(11c)  C[1] > O[1]                               // bullish candle
(11d)  C[1] - O[1] >= M1_MinBodyPercent/100 * R  // body is not a doji
(11e)  C[1] - L[1] >= M1_MinClosePct/100  * R    // closes in the upper part of its
                                                 // range = rejection of lower prices
(11f)  C[1] > FVGLow                             // closed back above the gap floor
```

All six must hold on the *same* bar. Entry is a market BUY placed immediately after
that bar closes.

Note on (11b): the confirming bar must itself have traded in the zone. A touch alone
never triggers an entry — a bar can tag the zone and fail (11c)–(11f), in which case
the EA keeps waiting. This is the literal implementation of "do not enter simply
because price touches the FVG".

### 12. M1 bearish entry confirmation

```
(12a)  R > 0
(12b)  H[1] >= FVGLow  and  L[1] <= FVGHigh
(12c)  C[1] < O[1]
(12d)  O[1] - C[1] >= M1_MinBodyPercent/100 * R
(12e)  H[1] - C[1] >= M1_MinClosePct/100  * R
(12f)  C[1] < FVGHigh
```

---

### Setup lifecycle

```
WAIT_BIAS -> WAIT_SWEEP -> WAIT_MSS -> WAIT_FVG -> WAIT_RETRACE -> WAIT_CONFIRM -> TRADE_OPEN
```

A setup is cancelled and the EA returns to `WAIT_SWEEP` when any of these happens:

- more than `SetupExpirationBars` M5 bars have passed since the sweep bar;
- a closed M5 bar closes beyond the sweep extreme (below `SweepExtreme` for a bullish
  setup) — the sweep failed;
- a closed M5 bar closes through the FVG (below `FVGLow` bullish) — the gap failed;
- the M15 bias flips or goes to NONE;
- the setup has produced its one trade (`SetupID` is retired, so the same sweep can
  never be traded twice).

### Stops, targets and size

- `SL = SweepExtreme - SLBufferPoints*P` (buy) / `SweepExtreme + SLBufferPoints*P` (sell)
- `Risk = |Entry - SL|`, `TP = Entry + Risk*RiskReward` (buy) / `Entry - Risk*RiskReward` (sell)
- `Lots = (Equity * RiskPercent/100) / ((Risk / TickSize) * TickValueLoss)`, floored to
  `SYMBOL_VOLUME_STEP` and clamped to `SYMBOL_VOLUME_MIN/MAX` and `MaxLotSize`.

Size depends only on equity, `RiskPercent` and the stop distance. It is never a
function of previous results — no martingale, no post-loss increase. If the risk-correct
size is below the broker minimum, the trade is **rejected**, never rounded up.

---

## Part 2 — Using the EA

### Installation

1. Copy `Experts/XAUUSD_Scalper_V1.mq5` into `MQL5/Experts/` (MetaEditor → File →
   Open Data Folder), and press **F7** to compile.
2. Attach it to an **M1 chart of XAUUSD**. M1 is the intended chart because entry
   timing is driven by the M1 close; M5 and M15 data are pulled independently of the
   chart timeframe.
3. Allow algorithmic trading.

### Point scaling — read this first

Gold is quoted with 2 digits at some brokers and 3 at others, so "1 point" is either
`0.01` or `0.001`. Every point-based input (`MinimumFVGSize`, `SLBufferPoints`,
`MaxSpreadPoints`, `SweepMinPenetration`) would therefore mean a *ten times different*
price distance depending on the feed.

With `AutoAdjustForDigits = true` (default) the EA multiplies point inputs by 10 on a
3-digit or 5-digit feed, so the defaults keep the same real price meaning everywhere.
The initialisation log prints exactly what each input resolved to:

```
Point scaling: digits=3 point=0.001 scale=10  => 1 input point = 0.010 price
  MinimumFVGSize   30 pts = 0.300
  SLBufferPoints   50 pts = 0.500
  MaxSpreadPoints  40 pts = 0.400
```

Check those numbers against the instrument before running. Set
`AutoAdjustForDigits = false` if you prefer to specify raw broker points yourself.

### Inputs

| Group | Input | Default | Notes |
|---|---|---|---|
| Structure | `M15_SwingStrength` / `M15_LookbackBars` | 2 / 200 | bias pivots |
| | `M5_SwingStrength` / `M5_LookbackBars` | 2 / 200 | setup pivots |
| Liquidity | `SweepMinPenetration` | 10 pts | rejects a bare touch |
| | `MaxSweepAgeBars` | 20 M5 bars | |
| | `MSSSwingSearchBars` | 20 M5 bars | how far before the sweep an MSS swing may sit |
| FVG | `MinimumFVGSize` | 30 pts | |
| M1 entry | `M1_MinBodyPercent` | 25.0 | body as % of bar range |
| | `M1_MinClosePct` | 50.0 | close position within bar range |
| Risk | `RiskPercent` / `RiskReward` | 0.25 / 2.0 | |
| | `SLBufferPoints` / `MaxLotSize` | 50 pts / 1.0 | |
| Protection | `MaxTradesPerDay` | 5 | |
| | `MaxConsecutiveLosses` | 3 | counted within the current day |
| | `MaxDailyLossPercent` | 1.5 | realized + floating |
| | `MaxOpenPositions` | 1 | |
| | `MaxSpreadPoints` | 40 pts | |
| | `SetupExpirationBars` | 12 M5 bars | |
| Session | `TradingSessionStart` / `TradingSessionEnd` | 7 / 20 | **server time**, wrap-around supported |
| Execution | `MagicNumber` / `MaxSlippagePoints` | 20250817 / 30 | |
| Display | `ShowStatusComment` / `VerboseLogging` | true / true | |

`MaxConsecutiveLosses` counts the streak of losing trades **within the current server
day**, reset by any winner and by the day rollover. It is rebuilt from deal history, so
it survives a terminal restart.

### Trading halts

New entries stop — with the exact reason logged once — when the daily loss limit is
reached, the daily trade count is reached, the consecutive-loss limit is reached, the
spread exceeds `MaxSpreadPoints`, the clock is outside the session, a position is
already open, or the M15 bias no longer supports the setup. Existing positions are left
to their stop and target; the EA never closes early and never adds to a position.

### Session hours are server time

`TradingSessionStart` / `TradingSessionEnd` are broker server hours, not your local
time and not UTC. The server time is printed at initialisation:

```
Current server time: 2026.08.17 14:35  (session filter 7:00-20:00 server)
```

Compare that with the real London/New York clock and shift the values. A broker on
UTC+3 running the 7–20 default is trading roughly 04:00–17:00 UTC.

### Backtesting

Every structural decision is made on closed bars and the entry fires on an M1 close, so
results are not sensitive to the tick model. **Every tick based on real ticks** is still
the right choice for realistic spread and fill behaviour on gold.

The EA is deliberately low-frequency: bias + sweep with real penetration + MSS on a
close + a minimum-size FVG + an M1 rejection candle is a long chain of filters, and
most days will produce zero to two trades. That is the intended behaviour for V1 —
correctness first. If you want more trades, the levers in rough order of impact are
`M1_MinBodyPercent` / `M1_MinClosePct` (loosen the confirmation), `MinimumFVGSize`
(smaller gaps qualify), and `M15_SwingStrength` (a looser bias definition).

Judge a run on profit factor, maximum drawdown, expected payoff, trade count, win rate,
average win vs average loss, longest losing streak and recovery factor — not net profit
alone. Keep a hold-out period you never optimise on.

### Limitations

- Half-formed setups are not persisted across a terminal restart. An open position is
  recovered and managed to its stops; a pending setup is simply re-derived from history
  on the next M5 bar.
- Daily loss, trade count and the loss streak count only this EA's own deals on this
  symbol, identified by magic number.
- SL and TP are placed at entry and are never trailed or moved.
