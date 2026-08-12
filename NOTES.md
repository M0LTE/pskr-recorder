# Eclipse observations: what is worth measuring, and what will fool you

Written for the partial eclipse over the UK on 2026-08-12. Short answer to "interesting observations, or KISS and just retain the data?": **KISS during the event.** The capture is the only irreplaceable part, and every analysis below can be done afterwards from exactly the same bytes. Run `pskr-watch` if you want something to look at, but do not touch the collectors.

There is exactly one thing that cannot be recovered after the fact, and it is not the eclipse data: it is the **control days**. See "The trap" below.

## Timings

| Event | UTC |
|---|---|
| Umbra first touches Earth (Siberia) | 17:02 |
| Greatest eclipse (65.2N 25.2W, N Atlantic) | 17:46 |
| Totality over Iceland | ~17:48 |
| Umbral centre line closest to Reading, 911 km | 18:24 |
| Totality over northern Spain | ~18:27 |
| Umbra leaves Earth | 18:32 |

Partial phase over the UK runs roughly 17:15 to 19:00 UTC, with maximum obscuration around 18:10 to 18:30 depending on where you are. Reading sees roughly 90% obscuration. The UK maximum is *after* greatest eclipse, because the shadow is running southeast toward Spain.

Note the feed runs about 100 seconds behind real time (measured, and it is in `ingest_lag_s`). Anything you watch live lags by that much. For analysis use `t_tx`, the normalised transmission start, not `_rx`.

## What the data actually is, measured

Two properties of the feed materially change how you analyse it, and neither is obvious from the schema. Both measured over a 55-minute sample of real capture.

**A spot is not a decode.** PSK Reporter reports a given transmitter/receiver/band combination roughly **once every 5 to 6 minutes** (median gap between consecutive reports for the same pair: 345 s; range 0 to 32 minutes). It does not report every FT8 cycle. Over 55 minutes, 444435 of 447390 pairs appeared exactly once and no pair appeared more than three times.

The consequence: **per-pair time series are far too sparse to resolve anything on their own.** Any per-pair metric has to be aggregated across thousands of pairs before it means anything. Aggregate volume is not the problem: even the `corridor` zone yields about 4100 spots per 5-minute bin, and `near` about 17800, so 5-minute resolution is comfortable in aggregate. It is the individual pair that is sparse, not the dataset.

This is also why query 3's persistence threshold is 6 of 10 half-hours rather than something stricter. A pair active for an entire half-hour contributes only about five spots.

**Reports arrive late, with a long tail.** Ingest lag from `t_tx` to arrival: median 69 s, p90 277 s, p99 459 s, and a maximum of 2696 s, roughly 45 minutes. Some reporters batch up and upload well after the fact.

Two consequences. Live watching is always looking at an incomplete picture of the last few minutes, which is fine for eyeballing but not for measurement. And more importantly, **do not run the final analysis immediately after the event**: a bin is not complete until roughly an hour after the fact. Wait until at least 20:00 UTC before treating the 18:30 numbers as final.

## The physics, and what each band should do

The three layers have wildly different recombination time constants, and that difference is the single most robust thing to look for.

**D layer (60-90 km).** Ionised by solar Lyman-alpha and X-rays, recombines in seconds to a couple of minutes. It is the absorbing layer, and absorption scales roughly as 1/f^2. Cut the sunlight and absorption collapses almost immediately. **160m, 80m and 40m should improve, promptly, roughly in lockstep with obscuration.** This is the strongest and fastest effect and the one most likely to be visible.

**E layer (~110 km).** Recombines in minutes. Contributes absorption on 40m/30m and some refraction.

**F2 layer (250-350 km).** Recombines over 30 minutes to hours, and is dominated by transport as much as by production. foF2 sags modestly and *late*. **20m/15m/10m may show a MUF droop lagging the eclipse by 20 to 60 minutes**, much subtler and easily swamped by ordinary evening MUF decline.

So the headline result to aim for is not "the eclipse changed propagation". It is **the differential timing between bands**: low bands responding promptly and near-symmetrically about local maximum, high bands responding late and asymmetrically. That signature is hard to produce by accident, which is exactly what makes it worth having.

## The trap

**The eclipse sits right on top of European sunset.** 17:15 to 19:00 UTC in August is precisely when the low bands improve anyway, every single day, for reasons that have nothing to do with the Moon. If you plot 80m spot counts against time on eclipse day and see them rise, you have measured dusk, not an eclipse. This is the mistake that ruins most amateur eclipse write-ups.

There are three defences, in increasing order of strength:

1. **Spatial control.** The `far` zone in the tooling (path midpoint more than 4000 km from the centre line) gives a same-instant comparison. Weak on its own, because those paths are at different local times.
2. **Temporal control.** The same UTC window on 13 and 14 August. This is why the collectors are still running and should stay running for a few more days. **This is the part you cannot go back and get.**
3. **Difference in differences.** `(eclipse day corridor - eclipse day far) - (control day corridor - control day far)`. This cancels both the diurnal trend and any day-to-day propagation shift. If the effect survives this, it is real.

Query 5 in `analysis/queries.sql` sets up the control-day comparison.

## Other things that will mislead you

**Operator behaviour swamps spot counts.** People get on air for an eclipse; there will very likely be coordinated operating activity. Spot counts on eclipse day will be inflated for reasons that are entirely sociological. Never report a bare count change as a propagation result.

**Receiver population is not constant.** One large skimmer going on or offline moves the counts more than the ionosphere does. Normalise by `count(DISTINCT rx_call)`, or better, restrict to receivers present throughout the window.

**FT8 SNR saturates.** WSJT-X reports SNR clipped at roughly +20 dB at the top and truncated at the decode threshold at the bottom. If a path improves a lot, the reports do not get proportionally better; instead, *new* spots start appearing that previously did not decode. So SNR systematically under-reads large improvements while counts over-read them. **Use both, and expect them to disagree.** That disagreement is itself informative.

**Path midpoint is a poor proxy on long paths.** The great-circle midpoint stands in for the ionospheric reflection point, which is only defensible for one or two hops. On a 6000 km path the real control points are nowhere near the midpoint. For the cleanest analysis restrict to `dist_km < 2000`.

## The queries, ranked by how much I would trust them

1. **Query 3, persistent pairs.** Median SNR over transmitter/receiver pairs active throughout the window. Removes almost all population and behaviour effects, because the same pairs are being compared with themselves. This is the one to trust.
2. **Query 4, dose-response.** Change in SNR binned by distance from the centre line. If the effect is real it should vary monotonically with proximity. A flat line across distance bins means you are looking at dusk. This is a good falsification test and cheap to run.
3. **Query 5, control day.** Slower to get, since it needs 13 August, but it is what turns "suggestive" into "demonstrated".
4. **Query 2, raw counts by zone.** Useful for a first look and for a plot, but confounded six ways. Treat as exploratory only.

## Stretch goals

**Doppler.** Ionospheric vertical motion during an eclipse produces small Doppler shifts, fractions of a hertz to a few hertz on HF. The feed carries `f`, the receiver's measured frequency. Transmitter oscillator offset and drift are far larger than the signal, often tens of hertz, so absolute frequency is useless. But for a *single* tx/rx pair the constant offset cancels if you difference against that pair's own pre-eclipse baseline, leaving drift plus Doppler. Aggregate over thousands of pairs in the corridor and a coherent bulk shift might emerge around totality.

The reporting cadence makes this worse than it first looks: at roughly one report per pair per 5 to 6 minutes you cannot see the shape of a Doppler excursion within a pair at all, only a handful of scattered samples, so everything rests on the aggregate. I rate this genuinely unlikely to work with PSKR data, which is why HamSCI runs it with disciplined reference receivers instead. It costs nothing to try on data you already have, and a null result is honest.

**Sporadic E on 6m.** August is Es season and there is a lot of Es running right now, roughly 550 spots/min in the `near` zone as I write this. Whether eclipses perturb Es is genuinely unsettled. Be honest that this is a fishing expedition rather than a hypothesis test; with that much natural variability you are unlikely to attribute anything confidently.

**Terminator geometry.** Paths crossing the eclipse corridor perpendicular versus running along it should be affected differently, since the shadow is a moving 294 km wide band. Enough spots to slice this way, probably.

## What the first evening's analysis actually found

Preliminary, from data captured 13:50 to 21:15 UTC on eclipse day, before any control day existed.

**No eclipse effect detected.** Not "no effect exists" -- no effect detected at the sensitivity available, which is a weaker claim and the only honest one.

The route there is worth recording, because the interesting part was a false positive.

Controlling for solar elevation at the path midpoint, and using distance from where the umbra actually was at each instant, 80m produced a textbook dose-response: median SNR of -3 dB under 1000 km from the shadow, -8 at 1-2000 km, -11 at 2-3000 km, -13 beyond 4000 km. Monotonic, 10 dB of range, right direction, on exactly the band the physics nominates. It was wrong.

What killed it:

- The near-shadow bin drew on **44 receivers** against 114 to 155 in the far bins. "Near the shadow" and "a different set of stations" were the same variable.
- Near-shadow paths were **559 km** median against **1068 km** far. Shorter paths have better SNR regardless of the Moon.
- Comparing **each receiver against itself**, same 20 minutes, near-shadow versus far paths, collapsed the gradient to -1.5 dB and then -6 dB. It vanished and changed sign.
- Swept across all bands, within-receiver deltas scattered around zero with **no ordering by frequency**: 80m -6.5, 40m 0.0, 30m +2.0, 20m -2.0, 17m +1.5, 15m +1.5. Absorption proportional to 1/f^2 demands a strong positive on 80m decaying upward. It is not there.
- The displaced-shadow placebo returned **no data at all** (moving the track 120 degrees east lands it where nobody was on 80m). That test failed to run rather than passing, and should be reported as uninformative, not as support.

**Why a null is the expected result for this eclipse, not a disappointing one.** Under the shadow with the Sun above 20 degrees there were over 20000 spots, of which **three** were on 80m or 160m. Nobody is on the low bands in daylight; they arrive at dusk, by which time the eclipse was ending and the D layer was thin anyway. The bands that did have data under the shadow at 30 degrees elevation are the ones where absorption matters least. The frequency coverage and the physics do not overlap, from this longitude, for this event.

That is a real finding about the measurement, and it would apply to anyone attempting this from Europe with this geometry.

## Two tooling traps found the hard way

**`tail` on a build log hides the error.** A rebuild reported a plausible row count and a healthy runtime while silently serving three-hour-old data, because the result table plus timing filled exactly the last ten lines and the error above them was cut off. Log builds in full, or not at all.

**`CREATE OR REPLACE TABLE` fails on a table a view depends on.** So step 0 worked the first time and, on every rerun, kept the old `spots` while rebuilding everything downstream from it -- reporting success throughout. It now drops the view and dependants first, and prints `max(tx_time)` so a stale build is obvious. This would have quietly corrupted the control-day comparison, which is the one analysis that matters.

## What to actually do

- Now until the event: nothing. It is running.
- During: `pskr-watch` if you want a live view. Watch 80m and 40m `corridor` and `near` columns from about 17:30. Remember it lags real time by a minute or two and the most recent bins are always incomplete.
- After: leave the collectors running until at least 15 August so you get control days. This is the only part that expires.
- Then, not before about 20:00 UTC so the late reports have landed:

```sh
pskr-prepare
cat /opt/pskr/analysis/macros.sql /opt/pskr/analysis/step0_materialise.sql \
  | duckdb /var/lib/pskr/eclipse.duckdb
duckdb -c ".read /opt/pskr/analysis/integrity.sql"   # confirm nothing was lost
duckdb /var/lib/pskr/eclipse.duckdb                  # then query 3, then query 4
```
