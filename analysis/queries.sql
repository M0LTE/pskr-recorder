-- PSK Reporter eclipse analysis, 2026-08-12.
--
-- Run step 0 once, after capture:
--   cat /opt/pskr/analysis/macros.sql /opt/pskr/analysis/step0_materialise.sql \
--     | duckdb /var/lib/pskr/eclipse.duckdb
--
-- then open the database and run anything below:
--   duckdb /var/lib/pskr/eclipse.duckdb
--
-- Step 0 builds the `s` view (deduped, locators decoded, zones assigned). The
-- raw .jsonl.gz files remain the ground truth; everything here is derived and
-- can be thrown away and rebuilt.

-- ============================================================ 1. sanity

-- Capture completeness lives in its own file, because it has to read the clean
-- set rather than the tables and must match the .rN files a restart produces:
--
--   duckdb -c ".read /opt/pskr/analysis/integrity.sql"
--
-- Any sq in one instance and not the other is a real loss in that instance.

-- Pipeline latency: how far behind real time the feed runs. Matters if you are
-- watching live, and tells you which timestamp to trust.
SELECT band,
       count(*)                                   AS n,
       round(median(ingest_lag_s), 1)             AS median_lag_s,
       round(quantile_cont(ingest_lag_s, 0.9), 1) AS p90_lag_s
FROM s GROUP BY band ORDER BY n DESC;

-- ============================================================ 2. the main event
-- Spot count and median SNR per band per 5 minutes, split by how close the
-- path midpoint is to the eclipse track. 'far' is the built-in control: it
-- carries the same diurnal and operator-population trend without the eclipse.

SELECT
  time_bucket(INTERVAL '5 minutes', tx_time) AS t5,
  band, zone,
  count(*)                    AS spots,
  round(median(snr), 1)       AS med_snr,
  round(median(dist_km))      AS med_path_km,
  count(DISTINCT rx_call)     AS rx_stations
FROM s
WHERE tx_time BETWEEN '2026-08-12 15:00:00' AND '2026-08-12 21:00:00'
  AND band IN ('160m','80m','40m','30m','20m')
  AND zone <> 'far'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ============================================================ 3. the robust one
-- Counts are badly confounded: people switch bands, spin up receivers, and
-- generally behave differently during an eclipse. Median SNR over a FIXED set
-- of transmitter/receiver pairs that were active throughout removes almost all
-- of that. This is the query to trust.
--
-- Calibrated against the real reporting cadence: a given tx/rx/band pair is
-- reported roughly every 5-6 minutes (measured median gap 345 s), NOT once per
-- decode. So a pair active for a whole half-hour yields only about 5 spots, and
-- demanding presence in 8 of 10 half-hours throws away most of the sample.
-- 6 of 10 keeps a usable N while still requiring genuine persistence. Raise it
-- if you have the volume; check `pairs` in the output before trusting a row.

WITH win AS (
  SELECT * FROM s
  WHERE tx_time BETWEEN '2026-08-12 15:30:00' AND '2026-08-12 20:30:00'
    AND zone IN ('corridor','near','penumbral')
),
persistent AS (          -- pairs seen in at least 6 of the 10 half-hours
  SELECT tx_call, rx_call, band
  FROM win
  GROUP BY 1, 2, 3
  HAVING count(DISTINCT time_bucket(INTERVAL '30 minutes', tx_time)) >= 6
)
SELECT
  time_bucket(INTERVAL '10 minutes', w.tx_time) AS t10,
  w.band,
  count(*)                  AS spots,
  count(DISTINCT (w.tx_call, w.rx_call)) AS pairs,
  round(median(w.snr), 2)   AS med_snr
FROM win w JOIN persistent p USING (tx_call, rx_call, band)
GROUP BY 1, 2 ORDER BY 1, 2;

-- ============================================================ 4. dose-response
-- Instead of a before/after split, treat distance-from-track as a dose. If the
-- effect is real, SNR change should vary monotonically with proximity.

WITH base AS (   -- pre-eclipse reference per pair
  SELECT tx_call, rx_call, band, median(snr) AS snr_base
  FROM s WHERE tx_time BETWEEN '2026-08-12 15:30:00' AND '2026-08-12 16:30:00'
  GROUP BY 1, 2, 3 HAVING count(*) >= 5
),
during AS (
  SELECT tx_call, rx_call, band, d_track_km, median(snr) AS snr_ecl
  FROM s WHERE tx_time BETWEEN '2026-08-12 17:30:00' AND '2026-08-12 18:30:00'
  GROUP BY 1, 2, 3, 4 HAVING count(*) >= 5
)
SELECT
  d.band,
  width_bucket(d.d_track_km, 0, 5000, 10) * 500 AS d_bin_km,
  count(*)                                      AS pairs,
  round(median(d.snr_ecl - b.snr_base), 2)      AS d_snr_db
FROM during d JOIN base b USING (tx_call, rx_call, band)
GROUP BY 1, 2 ORDER BY 1, 2;

-- ============================================================ 5. control day
-- Same clock window, a different day. Run this once you have 13 Aug captured.

SELECT
  date_trunc('day', tx_time)                          AS day,
  time_bucket(INTERVAL '15 minutes', tx_time)::TIME   AS clock,
  band,
  count(*)              AS spots,
  round(median(snr), 2) AS med_snr
FROM s
WHERE zone IN ('corridor','near')
  AND tx_time::TIME BETWEEN '15:00:00' AND '21:00:00'
  AND band IN ('160m','80m','40m')
GROUP BY 1, 2, 3 ORDER BY 3, 2, 1;
