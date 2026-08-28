# XAUUSD_VWAP_RSI_Scalper_V1 — definitions and usage

Source: [`Experts/XAUUSD_VWAP_RSI_Scalper_V1.mq5`](../Experts/XAUUSD_VWAP_RSI_Scalper_V1.mq5)

A simple, objective M5 scalper: trade the RSI midline cross in the direction the
session VWAP says price is already leaning. It shares no logic with the other two
EAs in this repository.

The symbol is never hard-coded — everything uses `_Symbol`, so the EA runs on
whatever chart it is attached to. The defaults are tuned for XAUUSD.

---

## Part 1 — Exact definitions

### Index convention

Bars are series-indexed: `0` is the currently forming bar, `1` is the most recently
**closed** bar, larger index = older. **No signal input ever reads bar 0**, which is
what makes the EA non-repainting: every value it acts on is final at the moment it
is read.

### 1. Session VWAP

Volume-weighted average price over the closed M5 bars of the current trading day.

For each closed M5 bar `i` in the current day:

```
TypicalPrice[i] = (High[i] + Low[i] + Close[i]) / 3

                 SUM( TypicalPrice[i] * TickVolume[i] )
VWAP           = --------------------------------------      for i = 1 .. dayStart
                        SUM( TickVolume[i] )
```

- The sum runs from bar `1` (the newest closed bar) back to the **first bar whose
  server calendar date differs from the date of bar 1** — that bar is excluded. This
  is the daily reset: the calculation always starts fresh at the first bar of the
  current server day.
- Bar `0` is excluded, so VWAP never moves after the fact.
- The signal candle (bar 1) **is** included in the sum, so `Close[1] > VWAP` compares
  the candle against a VWAP that includes it.
- The EA recomputes the whole day-to-date sum on each new bar rather than keeping a
  running accumulator. Recomputation is stateless, so a terminal restart, a history
  gap or a tester re-init can never leave a stale or half-built VWAP behind.
- A bar reporting `TickVolume = 0` is floored to 1 so a dead bar cannot zero out the
  denominator. If total volume is still 0, VWAP is undefined and no trade is taken.

**Trading day** = the broker's server calendar date (`year/month/day` of the bar's
open time). It is not UTC and not your local date.

### 2. RSI cross

`RSI(RSIPeriod)` on M5, applied to close, read via `CopyBuffer` from position 0 with
3 values, so `rsi[1]` is the last closed bar and `rsi[2]` the one before it.

```
BullishCross  ==  rsi[2] <= RSIMidline  AND  rsi[1] >  RSIMidline
BearishCross  ==  rsi[2] >= RSIMidline  AND  rsi[1] <  RSIMidline
```

Both values are final when read. The `<=` / `>=` on the older bar means a bar sitting
exactly on the midline counts as "not yet crossed", so the cross is registered once,
on the bar that actually breaks through.

### 3. Confirmed swing high

Bar `i` on M5 is a confirmed swing high iff:

```
(3a)  i >= SwingStrength + 1
(3b)  High[i] > High[i+k]   for all k = 1..SwingStrength      (older bars)
(3c)  High[i] > High[i-k]   for all k = 1..SwingStrength      (newer bars)
```

Condition (3a) is the no-future-data rule: it forces the `SwingStrength` bars that
sit to the right of the pivot to be closed bars (index >= 1) at the moment the swing
is evaluated. The pivot simply does not exist for the EA until its confirming bars
have printed, so no decision is ever made using a bar that had not closed.

The **most recent** confirmed swing high is the smallest `i` satisfying the above,
searched over `SwingLookbackBars`.

### 4. Confirmed swing low

```
(4a)  i >= SwingStrength + 1
(4b)  Low[i] < Low[i+k]   for all k = 1..SwingStrength
(4c)  Low[i] < Low[i-k]   for all k = 1..SwingStrength
```

Strict inequalities on both sides in (3) and (4), so a flat double bottom does not
register as a pivot.

### 5. Position sizing

```
SL        = SwingLow  - SLBufferPoints*P        (buy)
          = SwingHigh + SLBufferPoints*P        (sell)
Risk      = |Entry - SL|
RiskMoney = AccountEquity * RiskPercent / 100

              RiskMoney
Lots  =  ---------------------------
         (Risk / TickSize) * TickValue
```

`TickSize = SYMBOL_TRADE_TICK_SIZE`, `TickValue = SYMBOL_TRADE_TICK_VALUE_LOSS`
(falling back to `SYMBOL_TRADE_TICK_VALUE`). The result is floored — never rounded up
— to `SYMBOL_VOLUME_STEP`, then clamped to `SYMBOL_VOLUME_MIN`, `SYMBOL_VOLUME_MAX`
and `MaxLotSize`.

If the risk-correct size comes out **below the broker minimum**, the trade is
**rejected**, not rounded up to the minimum. Rounding up would silently exceed the
configured risk, which is the one thing position sizing exists to prevent.

Size is a function of equity, `RiskPercent` and the stop distance only. It never
reads previous results, so there is no martingale, no averaging and no revenge
sizing. Fixed lots are never used as the primary calculation.

### 6. Daily loss

Rebuilt from deal history each time it is needed, never accumulated in a variable:

```
DayStart      = server midnight of the current server date
Realized      = SUM( profit + swap + commission )  over all deals of this symbol
                and this MagicNumber with time >= DayStart
Floating      = SUM( profit + swap )  over currently open positions of this symbol
                and this MagicNumber
DayStartBal   = AccountBalance - Realized
DailyPL%      = (Realized + Floating) / DayStartBal * 100
```

Trading halts while `DailyPL% <= -MaxDailyLossPercent`. Because it is derived from
history rather than a counter, the limit survives a terminal restart and is correct
on the first tick after one. `TradesToday` is counted the same way, from deals with
`DEAL_ENTRY_IN`.

Only this EA's own deals on this symbol count, identified by magic number.

### 7. New-candle detection

```
IsNewBar():
    t = iTime(_Symbol, PERIOD_M5, 0)      // open time of the forming bar
    if t == 0 or t == lastSeen: return false
    lastSeen = t
    return true
```

`OnTick` calls this first and does nothing else when it returns false. A change in
the forming bar's open time means the previous bar has just closed, so the whole
entry evaluation runs **exactly once per closed M5 candle**, never per tick. There
is no tick-level entry path at all.

---

## Part 2 — Strategy

**BUY**, all on the newly closed M5 bar: `Close[1] > VWAP`; `rsi[2] <= RSIMidline`
and `rsi[1] > RSIMidline`; no open position with this magic; spread below
`MaxSpreadPoints`; daily trade limit not reached; daily loss limit not reached;
inside the session. SL below the most recent confirmed M5 swing low minus the
buffer; `TP = Entry + (Entry - SL) * RiskReward`.

**SELL** is the mirror: `Close[1] < VWAP`, `rsi[2] >= RSIMidline` and
`rsi[1] < RSIMidline`, SL above the most recent confirmed swing high plus the
buffer, `TP = Entry - (SL - Entry) * RiskReward`.

Maximum open positions is **1**, enforced as a hard constant.

### Inputs

| Group | Input | Default |
|---|---|---|
| Strategy | `RSIPeriod` / `RSIMidline` | 14 / 50.0 |
| | `SwingStrength` / `SwingLookbackBars` | 2 / 100 |
| | `VWAPMaxLookbackBars` | 400 |
| Risk | `RiskPercent` / `RiskReward` | 0.25 / 2.0 |
| | `SLBufferPoints` / `MaxLotSize` | 50 pts / 1.0 |
| Limits | `MaxTradesPerDay` / `MaxDailyLossPercent` | 5 / 1.5 |
| | `MaxSpreadPoints` | 40 pts |
| Session | `TradingSessionStart` / `TradingSessionEnd` | 7 / 21 (**server time**) |
| Execution | `MagicNumber` / `MaxSlippagePoints` | 20250818 / 30 |
| | `AutoAdjustForDigits` | true |
| Diagnostics | `LogEveryBar` | false |

### Point scaling

Gold is quoted with 2 digits at some brokers and 3 at others, so one point is either
`0.01` or `0.001` and every point input would otherwise mean a ten-times different
distance. With `AutoAdjustForDigits = true` point inputs are multiplied by 10 on a
3- or 5-digit feed. Initialisation logs what each one resolved to:

```
Point scaling: digits=3 point=0.001 scale=10  => 1 input point = 0.010 price
  SLBufferPoints   50 pts = 0.500
  MaxSpreadPoints  40 pts = 0.400
```

Check those against the instrument before trusting a run.

### Session hours are server time

`TradingSessionStart` / `TradingSessionEnd` are broker server hours. The server time
is printed at init — compare it against the real session clock and shift the values.
Setting start equal to end means 24 hours. Ranges that wrap past midnight work.

### Logging

Signals, trades and rejections (with the exact reason) always print. `LogEveryBar`
additionally prints VWAP and both RSI values for every closed M5 bar — useful when
verifying behaviour on a short range, but it produces roughly 288 lines per day, so
leave it off for long backtests and optimisation.

### Backtesting

All signals come from closed bars, so results do not depend on the tick model;
**Every tick based on real ticks** is still best for realistic spread and fills.
Judge runs on profit factor, drawdown, expected payoff, win rate, average win versus
average loss and the longest losing streak — not net profit alone.

### Limitations

- SL and TP are set at entry and never trailed or moved.
- Daily loss, trade count and duplicate protection consider only this EA's deals on
  this symbol, filtered by magic number.
- VWAP resets on the server calendar date. On a broker whose day rolls at an
  awkward hour, the first bars of a new day have very few samples, which is normal
  for session VWAP but makes early-session signals noisier.
