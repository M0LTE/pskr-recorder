# pskr-recorder

Capture of the full PSK Reporter MQTT feed across the 2026-08-12 partial solar eclipse.

See [NOTES.md](NOTES.md) for what is worth measuring during the event and what will mislead you.

## Where it runs

Proxmox container **139 / `pskr-eclipse`** on `10.45.0.10`, reachable at **`10.45.0.210`**.
Debian 12, unprivileged, 2 cores, 8 GB RAM, 64 GB thin-provisioned on `local-zfs`, `onboot=1`.
Root SSH uses the same keys as the Proxmox host.

The collectors themselves need almost nothing; the 8 GB is for DuckDB, which met the OOM killer at
2 GB while deduplicating. Step 0 also sets a 6 GB limit and a spill directory so it degrades to disk
rather than dying as the dataset grows.

## What it captures

Topic `pskr/filter/v2/#` on `mqtt.pskreporter.info:1883` -- the full feed, not the 1% sample.

`v2` rather than `v2raw` on Tom's advice: `v2raw` is a strict superset by about 1.7%, and the
extra spots are exactly those whose stations lack a valid grid, which are useless for anything
geographic. Measured and confirmed before deploying: over a 45 s window, 27069 spots in `v2`,
27546 in `v2raw`, zero present in `v2` but absent from `v2raw`.

Sustained rate is roughly 600-830 spots/s, about 130 KiB/s on the wire, compressing to about
27 bytes per spot on disk. That is around 1.9 GB per day per instance, so 3.7 GB/day for the pair,
against 64 GB of disk. Capturing the eclipse plus several control days is nowhere near the limit,
but the collectors have no disk-space guard: if the volume ever did fill they would crash-loop on
write, so keep an eye on `df` if you leave this running for weeks.

## Redundancy

Two independent collectors, `pskr-collect@a` and `pskr-collect@b`, run side by side with separate
broker connections and separate output files. A once-only event does not get a second try, so the
cost of a duplicate process is trivial against the cost of losing the window to a crash or a
reconnect gap.

The broker's `sq` field is a contiguous global sequence, so any spot present in one instance and
absent from the other is a real loss in that instance. `analysis/integrity.sql` measures this
exactly.

It has already earned its keep. During pre-flight testing instance `a` was SIGKILLed twice and
stopped once; it ended up missing 50793 spots, 7.5% of the total. Instance `b` had 100%, and
`a_only` was 0, so the union was complete. That is a normal afternoon of deliberate abuse standing
in for whatever actually goes wrong during the event.

Note that the 14:00 UTC hour therefore has a genuine gap in instance `a` only. It is covered by `b`.

## On-disk format

Hourly-rotated gzipped NDJSON at `/var/lib/pskr/data/spots-YYYYMMDD-HH-{a,b}.jsonl.gz`.

Each line is the broker's payload byte-for-byte with one key spliced in before the closing brace:

```json
{"sq":71648822779,"f":18101342,"md":"FT8","rp":-2,"t":1786544894,"t_tx":1786544894,
 "sc":"G6EES","sl":"IO91FM","rc":"KB3Z","rl":"FN20GE","sa":223,"ra":291,"b":"17m",
 "_rx":1786545015.473}
```

`_rx` is local receive time. The vendor's bytes are otherwise untouched, so the file stays a
faithful record of what arrived; the line is still valid JSON.

The collector deliberately does no parsing, filtering or database work. Its only job is to not lose
spots. The deflate stream is `Z_SYNC_FLUSH`ed and `fsync`ed every 5 seconds, so a hard kill loses at
most 5 seconds and the partial file still reads with plain `zcat` -- verified, not assumed.

## Operating

```sh
pskr-status                                  # everything at a glance
journalctl -u pskr-collect@a -f              # stats line every 60 s
jq . /var/lib/pskr/data/status-a.json        # heartbeat: counts, queue depth, reconnects
```

`Restart=always`, `RestartSec=2`, `StartLimitIntervalSec=0` -- it will never rate-limit itself into
staying dead. Restarting mid-hour appends rather than truncating.

## Live view

```sh
pskr-watch                       # all bands, 20 min rolling window
pskr-watch --bands 80m,40m,30m --window-min 10
```

Opens its own MQTT subscription and holds everything in memory. It never reads or writes the capture
files and cannot affect the collectors. Buckets spots by great-circle path midpoint distance from the
umbral centre line: `corridor` under 800 km, `near` 800-2000, `penumbral` 2000-4000, `far` beyond,
which acts as the control.

## Analysis

DuckDB refuses any file that is not a complete gzip stream, with `Input is not a GZIP stream`. Two
kinds of file in the capture directory are not: whichever file is being written right now, and any
file whose writer was hard-killed. `zcat` recovers both perfectly well, so a prepare step
normalises them into a clean set first. Good files are hardlinked and cost nothing; only the live
and damaged ones are rewritten. Originals are never touched.

```sh
pskr-prepare                                            # -> /var/lib/pskr/clean
cat /opt/pskr/analysis/macros.sql \
    /opt/pskr/analysis/step0_materialise.sql | duckdb /var/lib/pskr/eclipse.duckdb
duckdb -c ".read /opt/pskr/analysis/integrity.sql"      # cross-instance loss check
duckdb /var/lib/pskr/eclipse.duckdb                     # then work through queries.sql
```

Step 0 dedupes both instances on `sq`, decodes locators, computes path midpoints and
distance-to-track, and writes Parquet. Do it once; the JSON scan is the slow part. It runs in a few
seconds over an hour of capture.

Re-run `pskr-prepare` before each analysis pass to pick up newly closed hours.

`analysis/eclipse_track.csv` is the umbral centre line at 2-minute intervals, converted from NASA's
published path table. Distance to the *nearest point on the whole track* is fixed in space, which is
what makes before/during/after comparison of the same corridor possible.

## Layout

| Path | Purpose |
|---|---|
| `collector/pskr_collect.py` | the collector; `/opt/pskr/` on the container |
| `collector/pskr_watch.py` | live watcher; `pskr-watch` on PATH |
| `collector/pskr-status` | one-glance health check; `pskr-status` on PATH |
| `systemd/pskr-collect@.service` | template unit, instantiated as `@a` and `@b` |
| `analysis/pskr-prepare` | normalises live/damaged gzip into a clean set; `pskr-prepare` on PATH |
| `analysis/macros.sql` | Maidenhead decode, haversine, great-circle midpoint |
| `analysis/step0_materialise.sql` | dedupe, decode, zone assignment, Parquet export |
| `analysis/integrity.sql` | cross-instance loss check on `sq` |
| `analysis/queries.sql` | the five analyses |
| `analysis/eclipse_track.csv` | umbral centre line, 17:02-18:32 UTC |
