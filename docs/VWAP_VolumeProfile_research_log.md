# VWAP + Volume Profile — research log

A record of what was tested on `XAUUSD_VWAP_VolumeProfile_V1`, what was found, and
which findings survived contact with new data. Written so the dead ends stay dead.

**Headline: no edge was found. Pooled over 613 trades the strategy runs at
PF 0.945, a win-rate deficit of 1.42 points, 0.70 standard errors from zero.**

## The measurement bugs, and why they mattered

Four defects had to be fixed before any number meant anything. Each one had
already produced a result that looked like a finding.

| Bug | Effect on the numbers |
|---|---|
| Attribution counters reset inside `BuildProfile()` instead of `OnInit()` | `BuildProfile()` runs every bar, so every per-level bucket printed zero in every run since V1.10 |
| `g_posLevel` armed at signal time, not on fill | A signal blocked while an earlier position was open overwrote the bucket, so closed trades were credited to the wrong level |
| Nearest-level search | The POC sits mid-value-area where price spends most of its time, so it won nearly every contest and the VAH/VAL rule was barely exercised |
| Min-lot guard on a small deposit | Silently removed every wide-stop setup, leaving a biased tight-stop sample that looked profitable |

The last one is the instructive one. At a 3,000 deposit the guard rejected any
setup whose stop exceeded 7,500 points and 23 trades survived at PF 1.33. At
30,000 nothing was rejected, 257 trades came in at PF 0.98, and the edge was gone.
**The apparent edge was the filter, not the strategy.**

## What was tested, and what happened to it

| Hypothesis | Where it came from | Outcome |
|---|---|---|
| Tight stops carry the edge | 23-trade run at PF 1.33 | **Dead.** Bands <5k and 5-10k lose in both windows (PF 0.67/0.92, 0.69) |
| The 10-15k stop band is real | 2026: +14.4 pts, 2.28 SE, PF 1.80 | **Dead.** 2025: PF 0.82, net -478. Sign flip |
| VAH rejection (the core rule) works | 2026: 58.3% win, PF 1.74 | Best bucket in the run, but 24 trades at 1.35 SE. Unproven |
| Shorts beat longs | 2026: +6.77 pts | **Dead.** 2025 longs led by 5.59. Pooled difference +1.10 pts |

Nothing survived. Every effect that looked real in one window reversed in the other.

## The two windows

| | n | PF | Win | Break-even | Edge |
|---|---|---|---|---|---|
| 2026.01-08, real ticks, 100% quality | 324 | 1.053 | 50.62% | 49.32% | +1.30 pts (+0.47 SE) |
| 2025 full year, M1-modelled, 0% quality | 289 | 0.835 | 45.67% | 50.16% | -4.48 pts (-1.52 SE) |
| **Pooled** | **613** | **0.945** | 48.29% | 49.71% | **-1.42 pts (-0.70 SE)** |

The 2025 window is lower fidelity, so it is evidence of *failure to replicate*
rather than proof of a negative. Modelling error adds noise; it does not
systematically reverse one band and promote its neighbour.

## Method notes worth keeping

- **Judge a bucket against its own break-even.** Win rate alone is meaningless
  without the R:R that bucket actually realised. Break-even = 1/(1+RR).
- **Standard error before profit factor.** At n=23 the SE on a win rate is ~10
  points; PF 1.33 was 0.67 SE from nothing. A band under ~30 closed trades cannot
  clear 2 SE at all.
- **Count the comparisons.** Five bands were tested. P(at least one clears 2 SE by
  chance) = 10.9%. One did. The Bonferroni threshold was 2.33 SE; it scored 2.28.
- **Merging categories after seeing the data inflates the result.** Combining
  10-15k and 15-20k because each was positive in one window still gave only
  1.30 SE, and that number is optimistic by construction.
- **Account size is a selection filter, not just a risk setting.** Any run where
  the min-lot guard fires is measuring a biased subset. Size the deposit so the
  guard stays silent, then measure.
- **Print the configuration into the journal.** Two runs that cannot state their
  own inputs cannot be compared. Realised R:R moved 1.96 -> 1.03 between runs
  purely from input drift, and that was invisible until the config echo existed.

## Where the strategy and the trader diverge

The EA generated 853 signals in 2025 and 925 in 2026 - three to four a day. A
discretionary trader using the same levels does not take 900 trades a year. The
selection is being done by context the code does not have: how the level was
approached, the session, the news backdrop, what the previous day did.

That gap, not the parameters, is where any remaining edge would live. The
productive next step is to articulate what makes a VAH rejection worth declining,
because that is a testable hypothesis. Another band boundary is not.

## Do not repeat

- Tuning parameters against a single window. Six runs drifted between PF 0.82 and
  1.33 on input changes alone, all of it inside the noise band.
- Treating a profit factor above 1 as a result without the trade count and the
  standard error next to it.
- Funding a small account to "test it live". A 30 USD cent account equals a 3,000
  USD standard account in every ratio that matters, and is confined to the tightest
  stop bands - which lose in both windows.
