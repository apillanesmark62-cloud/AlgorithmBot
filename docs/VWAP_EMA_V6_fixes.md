# VWAP_EMA_EA_V6 — defects found in build 6.00 and what 6.01 changes

Build 6.01 keeps the strategy semantics of 6.00. Everything below is either a
correctness fix, a performance fix, or an opt-in filter that defaults to OFF.

## F1 — CRITICAL: `ArraySetAsSeries()` on statically-sized arrays

```cpp
MqlRates r[3];                    // fixed size = STATIC
ArraySetAsSeries(r, true);        // the AS_SERIES flag cannot be set here
CopyRates(_Symbol, EntryTF, 0, 3, r);
```

The same pattern appears in `GetIndicators()` (`double fast[3], slow[3], atr[3]`).

The AS_SERIES flag cannot be applied to an array whose size is fixed at compile
time. **This is the most likely source of your compile error.** If your build
accepts it instead, the flag silently fails and the array stays in chronological
order, which is worse, because the code still compiles and quietly does the wrong
thing:

| index | AS_SERIES honoured (intended) | AS_SERIES silently ignored (actual) |
|---|---|---|
| `r[0]` | shift 0 — forming bar | shift 2 — oldest |
| `r[1]` | shift 1 — last closed | shift 1 — last closed *(correct by coincidence)* |
| `r[2]` | shift 2 — one before last | **shift 0 — the FORMING bar** |

`LongSignal()` / `ShortSignal()` read `r2.close`. In the silent-failure case that is
the **live, still-moving close of the incomplete candle**, compared against `vwap2`
(the VWAP of shift 2). The reclaim test therefore repaints: it can be true mid-bar
and false by the bar's close, so backtest and live results diverge for reasons the
log will never show.

`r[1]` surviving intact is what makes this so easy to miss — the EA looks like it
works.

**Fix:** every array passed to `ArraySetAsSeries` is now declared dynamic
(`MqlRates r[];`, `double fast[];`). `CopyRates`/`CopyBuffer` resize them.

## F2 — CRITICAL: `NormalizeVolume()` rounded the size UP to the broker minimum

```cpp
volume = MathMax(vmin, MathMin(vmax, volume));   // clamps UP to vmin
volume = MathFloor(volume / vstep) * vstep;
```

When the risk-correct size fell below the broker minimum, the EA traded the minimum
anyway and silently exceeded `RiskPercent`. This is the same defect that was fixed in
the V4 line and it had been reintroduced. On a small balance with a wide ATR stop the
overrun can be several multiples of the configured risk.

Also note the ordering bug: clamping to `vmin` *before* flooring to `vstep` can floor
the result back below `vmin` when `vmin` is not an exact multiple of `vstep`.

**Fix:** cap at `vmax` (capping can only reduce risk), floor to `vstep`, then return
**0.0** if the result is below `vmin` so the caller skips the trade. `CalculateLots()`
logs the risk the minimum lot would have carried versus the configured percentage.

## F3 — HIGH: market orders sent with a captured price

```cpp
trade.Buy(lots, _Symbol, entry, sl, tp, "V6 VWAP EMA LONG");
```

`entry` was sampled inside `PrepareTrade()`. Passing a specific price on a market
request invites `10015 Invalid price` / requote rejections on some servers, and the
price is stale by construction.

**Fix:** send at market with `0.0` and let `CTrade` take the current price; deviation
is already bounded by `SlippagePoints`. The log now prints both the reference price
and the actual fill so slippage is visible.

## F4 — HIGH: the reclaim lookback rebuilt the whole day's VWAP repeatedly

`GetDailyVWAP()` performs a day-range `CopyRates` and re-sums from midnight on every
call. Per closed bar it was called for `vwap1`, `vwap2`, and once per lookback step:

| | |
|---|---|
| calls per bar (`ReclaimLookbackBars = 3`) | 5 |
| full-day scans per day (288 M5 bars) | 1,440 |
| over a 6-month test | ~187,000 |

Each scan is O(bars-so-far), so the cost is quadratic in the day.

**Fix:** `BuildVWAPCache()` runs **once per closed bar** and stores the cumulative
VWAP as it stood at the close of every bar in the day. `VWAPForShift(shift)` is then a
lookup. Same numbers, one scan instead of five, and the lookback is no longer
quadratic. Bar 0 is never included, so the cached values cannot repaint.

## F5 — `SYMBOL_TRADE_TICK_VALUE` → `SYMBOL_TRADE_TICK_VALUE_LOSS`

The loss-side tick value is the correct one for sizing against a stop; they differ on
some instruments. Falls back to the plain tick value when the broker reports zero.

## F6 — freeze level ignored in `StopsAreValid()`

Only `SYMBOL_TRADE_STOPS_LEVEL` was checked. Brokers that report 0 there may still
enforce `SYMBOL_TRADE_FREEZE_LEVEL`. Now uses the larger of the two.

## F7 — `MaxTradesPerDay <= 0` blocked all trading

`tradesToday >= MaxTradesPerDay` is `0 >= 0` on the first bar, so a value of 0 meant
"never trade" rather than "no limit". Now `<= 0` means unlimited, and `OnInit` prints
a note saying so. **This is a behaviour change for that input value only**; the
default of 3 is unaffected.

## F8 — `#property strict` removed

An MQL4 leftover with no meaning in MQL5.

---

## Two optional filters, both default OFF

`GetIndicators()` returned `fast2`/`slow2` in 6.00 but nothing used them, so the EMA
slope filter that existed in the V4/V5 line had quietly disappeared. 6.00's trend test
is only `fast1 > slow1` — it does not require the fast EMA to be rising, nor the close
to be beyond it.

Rather than change the strategy silently, 6.01 exposes both as inputs, defaulting to
the 6.00 behaviour:

| Input | Default | Effect when true |
|---|---|---|
| `RequireEMASlope` | false | fast EMA must be rising (long) / falling (short) |
| `RequireCloseVsFastEMA` | false | close must be above (long) / below (short) the fast EMA |

Turn them on one at a time and compare — do not enable both and assume the result.

## One thing left deliberately alone: the structure stop only widens

```cpp
if(structureDistance > stopDistance)
   stopDistance = structureDistance;
```

The structure stop can only ever make the stop **wider** than `1.5 * ATR`, capped at
`MaxStructureATR` (2.0 * ATR). It can never tighten it, so `StructureLookback` and
`StructureBufferATR` only ever increase the risk distance — and, at fixed
`RiskPercent`, decrease the lot size.

That is not automatically wrong: a wider stop reduces the spread as a fraction of the
stop, which is the dominant cost drag on M5 gold. But it is the opposite of what the
V5 line did, and the input name `MaxStructureATR` suggests a cap rather than a floor,
so it is worth being deliberate about it. 6.01 adds `StructureWidenOnly`, default
**true** (= 6.00 behaviour). Set it to false to make the structure stop *replace* the
ATR stop, floored at `0.25 * ATR`.

## Diagnostics

`PrintDiagnostics` now defaults to **false** (it was true, producing ~288 lines per
day). A funnel summary always prints at the end of the run:

```
============ VWAP_EMA_V6.01 FUNNEL SUMMARY ============
Closed bars evaluated / daily limit / outside session / existing position
price data / indicators / VWAP immature / EMAs flat / no signal
LONG + SHORT signals, rejected by spread, spread% of stop, stop distance,
position size, send failures, POSITIONS OPENED
signals by server hour
```

The by-hour row is worth reading first: signals clustering in the first hour or two of
the server day indicate the VWAP sample is still small enough that the reclaim test is
not selective. `MinVWAPBars = 12` is what holds that back.
