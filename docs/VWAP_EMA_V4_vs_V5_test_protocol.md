# VWAP+EMA V4 vs V5 — diagnosis and test protocol

**No backtest has been run to produce this document.** MetaTrader does not run in the
environment where V5 was written, so every number below is either derived from the
code by construction or from an explicit model that is stated as such. The results
tables are **empty templates for you to fill from your own Strategy Tester runs**.

---

## Part 1 — Why V4 has PF < 1

### Finding A — the reclaim filter is degenerate at the start of every session

```cpp
bool bullishReclaim = r[1].low <= vwap1 && r[1].close > vwap1;
```

On the **first bar of a server day**, `GetDailyVWAP(1)` sums exactly one bar, so
`VWAP = (H+L+C)/3`. Then:

- `VWAP >= L` always (since `(H+L+C)/3 >= (L+L+L)/3`), so **`low <= VWAP` is
  unconditionally true**.
- `close > (H+L+C)/3` reduces to `2C > H+L`, i.e. **"the candle closed above its own
  midpoint"** — roughly half of all candles.

So the filter that is supposed to be the strategy's selectivity does nothing at the
session open and becomes progressively meaningful as bars accumulate. Modelled over
400 synthetic M5 sessions:

| bar # in session | P(bullish reclaim) |
|---|---|
| 1 | 47.0% |
| 2 | 46.0% |
| 3 | 40.8% |
| 5 | 34.8% |
| 10 | 25.2% |
| 20 | 15.8% |
| 40 | 10.2% |
| 150 | 5.8% |
| 250 | 5.5% |

**~9x more permissive at the open than late in the day.** Combined with
`MaxTradesPerDay = 3`, the day's trade budget is disproportionately spent on
early-session signals that passed a filter which was not actually filtering — and on
gold those hours carry rollover spreads. This is the most likely single source of the
negative expectancy.

### Finding B — the stop/target geometry cannot absorb the spread

`SL = 1.5 * ATR`, `TP = SL * 1.5`. For a **zero-edge** entry the probability of
reaching TP before SL is `SL/(SL+TP) = 1/(1+1.5) = 40.0%`, which is exactly
break-even. Entering at ask and exiting at bid shifts both barriers, so
`P(win) ≈ (SL - spread/2)/(SL + TP)`:

| ATR(M5) | stop = 1.5·ATR | spread | spread/stop | P(win) | PF | expectancy (R) |
|---|---|---|---|---|---|---|
| 0.40 | 0.60 | 0.25 | 41.7% | 31.7% | **0.70** | −0.208 |
| 0.80 | 1.20 | 0.25 | 20.8% | 35.8% | **0.84** | −0.104 |
| 1.20 | 1.80 | 0.25 | 13.9% | 37.2% | **0.89** | −0.069 |
| 2.00 | 3.00 | 0.25 | 8.3% | 38.3% | **0.93** | −0.042 |

A structureless entry on this geometry lands at **PF 0.70–0.93**. The entry must
supply **+2.8 to +8.3 percentage points of win rate** purely to reach break-even,
with the burden worst in quiet (low-ATR) conditions. A PF slightly below 1 is the
expected outcome of this configuration, not an anomaly.

### Finding C — `VWAPPullbackATR` is inert under the default settings

`bullishReclaim` (`low <= VWAP`) logically implies `bullishPullback`
(`low <= VWAP + pullbackDistance`) for any non-negative `pullbackDistance`. With
`RequireVWAPReclaim = true` (the default), the pullback test can never be the binding
constraint, so **tuning `VWAPPullbackATR` changes nothing**. Anyone optimising that
input on the default configuration is optimising a no-op.

### Finding D — dead computation

`vwap2`, `slowEma2` and `atr2` are computed and null-checked but never used in any
condition. `GetDailyVWAP(2)` costs a full day-range `CopyRates` on **every bar** for a
value that is discarded.

### Finding E — no session filter

V4 trades all 24 hours, including the rollover window where gold spreads widen well
past normal. `MaxSpreadPoints = 80` is 0.80 on a 2-digit feed (permissive) but 0.08 on
a 3-digit feed (blocks almost everything) — check which feed you are on before reading
anything into the trade count.

---

## Part 2 — V5's controlled changes

Each change has its own input. **`RunAsV4 = true` forces all four off**, so one binary
runs both arms of the test.

| # | Input | V4 value | V5 default | Targets |
|---|---|---|---|---|
| 1 | `MinVWAPBars` | 0 | 12 | Finding A |
| 2 | `UseSessionFilter` (+ `SessionStartHour/EndHour`) | false | true, 7–20 | Finding E |
| 3 | `MaxSpreadPctOfStop` | 0 (off) | 12.0 | Finding B |
| 4 | `UseStructureStop` (+ `StructureStopBufferATR`) | false | true, 0.15 | Finding B |

**Unchanged:** `RiskPercent`, `RewardRisk`, `CalculateLots()`, `StopsAreValid()`,
`MaxTradesPerDay`, `OnePositionOnly`, all EMA/ATR periods, the trend test, the
pullback test, the reclaim test and the candle-confirmation test. Risk management is
untouched.

Change 4 caps the structure stop at V4's `1.5*ATR` (it can never be wider) and floors
it at `0.25*ATR` so a doji cannot produce an absurd stop. **This is the least certain
of the four** — a tighter stop raises the R multiple but lowers the win rate, and the
two effects can cancel. Test it on its own before keeping it.

V5 also drops the dead `vwap2`/`slowEma2`/`atr2` computations. Their null-checks went
with them, so in `RunAsV4` mode V5 can in principle accept a bar V4 rejected; this
requires `vwap2` to be unavailable while `vwap1` is, which is vanishingly rare. If you
want a bit-exact baseline, run `VWAP_EMA_EA_V4.mq5` rather than V5 in `RunAsV4` mode.

### The funnel report

Both arms print a summary at the end of every run naming where bars were lost:

```
========== VWAP+EMA FUNNEL SUMMARY (V5) ==========
New bars evaluated / rejected by each gate / VWAP immature
trend classification: bullish / bearish / none
of trending bars, FIRST failing filter: pullback / reclaim / confirmation
signals, rejections by spread%, stops, sizing, send failures, positions opened
signals by server hour
```

The "first failing filter" block answers *which entry condition is filtering out
trades* empirically instead of by argument. The "signals by server hour" block tests
Finding A directly: if V4's signals cluster in the first hour or two of the server day
and V5's do not, that is the mechanism confirmed.

---

## Part 3 — Test protocol

Same symbol, same timeframe (M5), same modelling mode, same spread setting, same
deposit and leverage for every run. Vary only the EA/config.

**Modelling:** *Every tick based on real ticks*. **Spread:** use the broker's real
recorded spread, not a fixed value — a fixed tight spread invalidates Findings B and E.

### Arms

| Arm | EA | Config |
|---|---|---|
| A | `VWAP_EMA_EA_V4.mq5` | defaults |
| B | `VWAP_EMA_EA_V5.mq5` | `RunAsV4 = true` (sanity check: should ≈ A) |
| C | `VWAP_EMA_EA_V5.mq5` | change 1 only |
| D | `VWAP_EMA_EA_V5.mq5` | changes 1+2 |
| E | `VWAP_EMA_EA_V5.mq5` | changes 1+2+3 |
| F | `VWAP_EMA_EA_V5.mq5` | all four (V5 defaults) |

Running C→F cumulatively shows which change earns its place. If C already captures
most of the gain, keep C and discard the rest.

### Periods — run every arm on all of them

| Period | Purpose |
|---|---|
| P1 | 6 months, trending |
| P2 | 6 months, ranging |
| P3 | 6 months, high volatility |
| P4 | 6 months, most recent (out-of-sample, chosen last) |

**Do not tune anything on P4.** Fix the configuration on P1–P3, then run P4 once. If
the edge only exists in the period you tuned on, there is no edge.

### Results template

| Arm | Period | Trades | Win % | PF | Net profit | Max DD % | Avg trade | Expectancy (R) |
|---|---|---|---|---|---|---|---|---|
| A | P1 | | | | | | | |
| B | P1 | | | | | | | |
| C | P1 | | | | | | | |
| D | P1 | | | | | | | |
| E | P1 | | | | | | | |
| F | P1 | | | | | | | |
| … | P2–P4 | | | | | | | |

### How to read it

- **Trade count near zero in every arm** → the blocker is upstream; read the funnel
  summary before touching parameters.
- **PF improves on one period only** → curve fit, discard.
- **PF improves on P1–P3 and holds on P4** → real, but check trade count: an arm with
  20 trades and PF 1.4 is not evidence.
- **Arm B differs materially from A** → the harness differs, not the strategy; fix
  that before comparing anything else.
- A change that raises PF while cutting trades by 80% has mostly removed trades, not
  found an edge. Compare **expectancy per trade** as well as PF.

### The honest possibility

Findings A–C explain a PF slightly below 1 without any of them being a coding error.
It is entirely possible that after fixing all four, V5 lands at PF ≈ 1.0 rather than
comfortably above it — because a VWAP reclaim in the direction of two EMAs may simply
not carry 3–8 points of win-rate edge on M5 gold after costs. If that is what the
tests show, the answer is a different entry premise or a higher timeframe where the
spread is a smaller fraction of the stop, not further tuning of these inputs.
