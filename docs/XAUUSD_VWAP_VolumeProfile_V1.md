# XAUUSD_VWAP_VolumeProfile_V1 — definitions and usage

Source: [`Experts/XAUUSD_VWAP_VolumeProfile_V1.mq5`](../Experts/XAUUSD_VWAP_VolumeProfile_V1.mq5)

An **educational backtesting EA**. It trades rejections of daily volume-profile
levels (POC / VAH / VAL) in the direction of session VWAP, on M5, with M15 as
higher-timeframe context. It shares no logic with the other EAs in this repository,
and uses no RSI, FVG, liquidity, order blocks, martingale, grid or averaging.

Correctness and non-repainting behaviour were prioritised over trade frequency
throughout.

---

## Part 1 — Exact definitions

### Index convention

Series indexing: `0` = the currently forming bar, `1` = the most recently **closed**
bar, larger index = older. **No decision input is ever read from bar 0.** The only
shift-0 call in the file reads the forming bar's *open time* to detect a bar
rollover, never its prices or volume.

### 1. Session start

The **trading day** is the broker's **server calendar date** (`year/month/day` of a
bar's open time). It is not UTC and not your local date.

The **session start** for any bar `b` is the oldest closed M5 bar whose server date
equals the server date of bar `b`. Both VWAP and the volume profile are rebuilt from
that bar forward on every new candle, so the daily reset needs no state and no
counter: it happens automatically because the scan simply stops when the date
changes.

### 2. VWAP calculation

Over the closed M5 bars of the current trading day:

```
TypicalPrice[i] = (High[i] + Low[i] + Close[i]) / 3

        SUM( TypicalPrice[i] * TickVolume[i] )
VWAP =  --------------------------------------      i = 1 .. sessionStart
               SUM( TickVolume[i] )
```

- Bar `0` is excluded, so VWAP is final the moment it is read.
- The signal candle (bar 1) **is** included, so `Close[1] > VWAP` compares the candle
  against a VWAP that already contains it. This is the standard session-VWAP reading.
- The sum is rebuilt every bar rather than accumulated, so a restart, a history gap
  or a tester re-init cannot leave a stale or half-built VWAP behind.
- A bar reporting `TickVolume = 0` is floored to 1 so it cannot zero the denominator.
  If total volume is still 0 the VWAP is undefined and no trade is taken.

The same formula, on M15 bars, produces the M15 context VWAP (see *M15 context*).

### 3. Price-bin calculation

Let the profile window be the closed M5 bars covering the most recent `ProfileDays`
distinct server dates (`ProfileDays = 1` means today only).

```
RangeHigh = max( High[i] )   over the profile window
RangeLow  = min( Low[i]  )   over the profile window
BinSize   = (RangeHigh - RangeLow) / ProfileRows
```

Bin `b`, for `b = 0 .. ProfileRows-1`, covers the half-open price interval

```
BinLow(b)  = RangeLow + b * BinSize
BinHigh(b) = RangeLow + (b+1) * BinSize
BinMid(b)  = RangeLow + (b + 0.5) * BinSize
```

The bin index of a price `p` is `floor((p - RangeLow) / BinSize)`, clamped into
`[0, ProfileRows-1]` so that a price exactly at `RangeHigh` lands in the top bin.

If `BinSize <= 0` (a flat window, or too few bars) the profile is marked invalid and
no trade is taken.

### 4. Tick-volume allocation

For each M5 candle `i` in the profile window:

```
bLow  = BinIndex( Low[i]  )
bHigh = BinIndex( High[i] )
n     = bHigh - bLow + 1                    // bins the candle's range spans

each bin b in [bLow, bHigh] receives:  TickVolume[i] / n
```

**Uniform distribution of a candle's tick volume across every bin its high–low range
touches.** A candle contained in one bin contributes all of its volume to that bin;
partially-touched end bins count as fully touched. This is deterministic, order
independent, and checkable by hand — which is why it was chosen over
overlap-weighted allocation for an educational EA. A zero-volume bar is floored to 1
tick so it still registers where price traded.

`TotalVolume` = the sum over all bins, which equals the sum of the (floored) candle
volumes.

### 5. POC

```
POC bin = the bin with the highest accumulated volume
POC     = BinMid( POC bin )
```

Ties are broken by the **lowest bin index**, which is simply the first maximum found
scanning upward from bin 0. Deterministic, so two runs over the same data always
produce the same POC.

### 6. Value Area

Single-bin expansion outward from the POC, exactly as specified:

```
target = TotalVolume * ValueAreaPercent / 100
acc    = volume[POC bin]
up     = POC bin + 1 ,  down = POC bin - 1
vaHigh = vaLow = POC bin

while acc < target and (up or down is still in range):
    vUp   = volume[up]    if up   in range, else -1
    vDown = volume[down]  if down in range, else -1
    take whichever side has the greater available volume:
        acc += that bin's volume
        extend vaHigh (or vaLow) to that bin
        advance that pointer
```

A tie between the two sides resolves **upward**. The loop always advances one
pointer, so it terminates. The resulting value area is the contiguous bin range
`[vaLow, vaHigh]`.

### 7. VAH

```
VAH = BinHigh( vaHigh )     // upper edge of the highest value-area bin
```

### 8. VAL

```
VAL = BinLow( vaLow )       // lower edge of the lowest value-area bin
```

### 9. VP-level interaction

Let `Tol = LevelTolerancePoints * P` (price distance after digit scaling) and let `L`
be one of POC, VAH, VAL. Level `L` **interacts** with closed candle 1 iff:

```
Low[1] - Tol  <=  L  <=  High[1] + Tol
```

That is: the level lies inside the candle's trading range expanded by the tolerance
on both sides. Interaction alone never opens a trade — it only makes the level a
candidate for the rejection test.

When more than one level interacts, the EA evaluates the one **closest to
`Close[1]`**, so the choice is deterministic.

### 10. Bullish rejection

At an interacting level `L`, on closed candle 1:

```
(10a)  Low[1]   <= L + Tol      // traded down to or through the level
(10b)  Close[1] >  L            // closed back ABOVE the level
(10c)  Close[1] >  Open[1]      // the candle itself closed bullish
(10d)  Close[1] >  VWAP         // and closed on the bullish side of VWAP
```

All four are required. (10b)–(10d) are what separate a rejection from a touch: a
candle that merely tags the level and closes below it, or closes bearish, or closes
under VWAP, produces no trade.

### 11. Bearish rejection

```
(11a)  High[1]  >= L - Tol      // traded up to or through the level
(11b)  Close[1] <  L            // closed back BELOW the level
(11c)  Close[1] <  Open[1]      // closed bearish
(11d)  Close[1] <  VWAP
```

Because 3 (bias) uses strict `>` and `<`, a candle closing **exactly at VWAP**
satisfies neither direction and is never traded, as required.

### 12. Daily loss

Rebuilt from deal history whenever needed, never accumulated in a counter:

```
DayStart    = server midnight of the current server date
Realized    = SUM(profit + swap + commission) over deals of this symbol and this
              MagicNumber with time >= DayStart
Floating    = SUM(profit + swap) over open positions of this symbol and MagicNumber
DayStartBal = AccountBalance - Realized
DailyPL%    = (Realized + Floating) / DayStartBal * 100
```

New entries stop while `DailyPL% <= -MaxDailyLossPercent`. Deriving it from history
rather than counting means the limit is correct on the very first tick after a
terminal restart. `TradesToday` comes from the same scan, counting `DEAL_ENTRY_IN`
deals.

### 13. New M5 candle detection

```
IsNewBar():
    t = iTime(_Symbol, PERIOD_M5, 0)     // open time of the forming bar
    if t == 0 or t == lastSeen: return false
    lastSeen = t
    return true
```

`OnTick` returns immediately when this is false. The entire evaluation — VWAP,
profile, POC/VAH/VAL, rejection, entry — therefore runs **exactly once per closed M5
candle**. There is no tick-level entry path in the file.

### 14. Position sizing

```
SL        = Low[1]  - SLBufferPoints*P     (long)
          = High[1] + SLBufferPoints*P     (short)
Risk      = |Entry - SL|
RiskMoney = AccountEquity * RiskPercent / 100

              RiskMoney
Lots  =  ---------------------------
         (Risk / TickSize) * TickValue
```

`TickSize = SYMBOL_TRADE_TICK_SIZE`, `TickValue = SYMBOL_TRADE_TICK_VALUE_LOSS`
(falling back to `SYMBOL_TRADE_TICK_VALUE`). The result is floored — never rounded
up — to `SYMBOL_VOLUME_STEP`, then clamped to `SYMBOL_VOLUME_MIN`,
`SYMBOL_VOLUME_MAX` and `MaxLotSize`.

If the risk-correct size falls **below the broker minimum the trade is rejected**,
not rounded up: rounding up would silently exceed the risk budget that sizing exists
to enforce. Size reads only equity, `RiskPercent` and the stop distance — never
previous results — so there is no martingale, grid, averaging or revenge sizing, and
fixed lots are never the primary calculation.

---

## How the profile is updated during the day (look-ahead safety)

This is the part most likely to be got wrong, so it is worth stating plainly.

The profile is **progressive**. It is rebuilt from scratch on every new M5 candle
from the closed bars available at that moment, and it therefore *grows* through the
trading day:

- At 09:00 the profile contains the bars from session start to 09:00.
- At 15:00 it contains the bars from session start to 15:00.
- It never contains a bar that closes later than the signal being evaluated.

This is **not** the same as today's final profile. A backtest that computed the
day's completed profile and then traded signals from earlier in that day would be
using tomorrow's information today — the classic volume-profile look-ahead bug. This
EA cannot do that, because the only bars it can see are `1` and older.

`ExcludeSignalBarFromProfile` (default **true**) goes one step further: the levels
are built from bars `2` and older, so POC/VAH/VAL are fully determined *before* the
signal candle opened, and the candle is then tested for rejecting them. With the
input set to `false`, bar 1 is included in its own profile — still non-repainting,
but a large signal candle can drag the POC toward itself. The default avoids that
self-reference.

## M15 higher-timeframe context

The specification lists M15 as higher-timeframe context but defines no rule for it,
so this EA uses the narrowest objective interpretation that introduces no new
indicator:

```
M15 bias = BULLISH  if  M15 Close[1] > M15 session VWAP
           BEARISH  if  M15 Close[1] < M15 session VWAP
```

A long additionally requires M15 bias bullish, a short requires bearish. Controlled
by `UseM15Filter` (default **true**). Turn it off to trade the M5 rules alone — that
is a real change in behaviour and trade count, so decide deliberately rather than
leaving it at the default by accident.

## Inputs

| Group | Input | Default |
|---|---|---|
| Volume profile | `ProfileDays` | 1 |
| | `ProfileRows` | 100 |
| | `ValueAreaPercent` | 70.0 |
| | `ProfileMaxBars` | 600 |
| | `ExcludeSignalBarFromProfile` | true |
| Signal | `LevelTolerancePoints` | 30 pts |
| | `UseM15Filter` | true |
| Risk | `RiskPercent` / `RiskReward` | 0.25 / 2.0 |
| | `SLBufferPoints` / `MaxLotSize` | 50 pts / 1.0 |
| Protection | `MaxTradesPerDay` | 5 |
| | `MaxDailyLossPercent` | 1.5 |
| | `MaxOpenPositions` | 1 |
| | `MaxSpreadPoints` | 40 pts |
| Session | `TradingSessionStart` / `TradingSessionEnd` | 7 / 21 (**server time**) |
| Execution | `MagicNumber` / `MaxSlippagePoints` | 20250819 / 30 |
| | `AutoAdjustForDigits` | true |
| Diagnostics | `LogEveryBar` | false |

## Point scaling

Gold is quoted with 2 digits at some brokers and 3 at others, so one point is either
`0.01` or `0.001`, and `LevelTolerancePoints` would otherwise mean a ten-times
different distance between feeds. With `AutoAdjustForDigits = true` point inputs are
multiplied by 10 on a 3- or 5-digit feed. Initialisation logs what each resolved to:

```
Point scaling: digits=3 point=0.001 scale=10  => 1 input point = 0.010 price
  LevelTolerancePoints  30 pts = 0.300
  SLBufferPoints        50 pts = 0.500
```

Check these against the instrument before trusting a run — a tolerance that is 10x
too small produces almost no trades, and one 10x too large makes every candle
"interact" with every level.

## Session hours are server time

`TradingSessionStart` / `TradingSessionEnd` are broker server hours. Server time is
printed at init — compare it against the real session clock and shift the values.
Start equal to end means 24 hours; ranges wrapping past midnight work.

## Logging

Signals, trades and rejections (with the exact reason) always print. `LogEveryBar`
adds a VWAP / POC / VAH / VAL / price / bias line for every closed M5 candle — useful
for verifying behaviour over a few days, but it produces roughly 288 lines per day,
so leave it off for long backtests. There is no per-tick logging anywhere.

## Backtesting

Run on **M5** with **Every tick based on real ticks**. Because every input is read
from closed bars, results do not depend on the tick model; the real-tick mode
matters for realistic spread and fill behaviour on gold.

Expect a low trade count. Requiring a level interaction, a directional rejection
close, VWAP agreement and (by default) M15 agreement is a long filter chain. That is
the intended trade-off for V1. The levers, in rough order of impact, are
`UseM15Filter`, `LevelTolerancePoints`, `ValueAreaPercent` and `ProfileRows`.

Judge runs on profit factor, drawdown, expected payoff, trade count, win rate,
average win versus average loss and the longest losing streak — not net profit alone.

## Limitations

- Volume is **tick volume**, not real traded volume. On most retail gold feeds real
  volume is unavailable, so the profile measures activity, not size.
- Volume allocation counts partially-touched end bins as fully touched. With a small
  `ProfileRows` on a wide range this coarsens the profile; raise `ProfileRows` if the
  levels look blocky.
- Early in the session the profile has very few bars, so POC/VAH/VAL are unstable
  until some hours have accumulated. The default 07:00 session start mitigates this
  on most brokers, but it is inherent to intraday profiles.
- SL and TP are set at entry and never trailed or moved.
- Daily counters and duplicate protection consider only this EA's deals on this
  symbol, filtered by magic number.
