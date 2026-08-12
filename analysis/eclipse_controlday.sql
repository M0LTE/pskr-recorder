-- THE definitive test: eclipse day against an ordinary day, same clock hours.
--
-- Everything before this could only ever be suggestive, because the eclipse
-- coincided with European dusk and dusk improves the low bands every single day.
-- The only way to separate them is to look at the same hours on a day with no
-- eclipse. Run this once 13 August is captured through about 20:30 UTC.
--
-- The statistic is a difference in differences:
--
--   (eclipse day: eclipsed zone - far zone) - (control day: eclipsed zone - far zone)
--
-- The inner difference removes anything global to each day (solar flux, storms,
-- overall activity). The outer difference removes the diurnal cycle, because it
-- is present identically on both days. What survives is attributable to the
-- eclipse, and nothing else in this dataset can produce it.
--
-- Restricted throughout to transmitter/receiver/band triples active on BOTH
-- days, so the comparison is never contaminated by who happened to be on air.

.mode box

CREATE OR REPLACE TEMP TABLE both_days AS
SELECT *,
       date_trunc('day', tx_time)::DATE  AS day,
       tx_time::TIME                     AS clock
FROM s
WHERE tx_time::TIME BETWEEN '15:00:00' AND '20:30:00'
  AND date_trunc('day', tx_time)::DATE IN (DATE '2026-08-12', DATE '2026-08-13')
  AND dist_km BETWEEN 300 AND 2500
  AND mid_lat IS NOT NULL;

-- pairs that appear on both days, so the population is identical on each side
CREATE OR REPLACE TEMP TABLE common AS
SELECT tx_call, rx_call, band, any_value(zone) AS zone
FROM both_days
GROUP BY 1, 2, 3
HAVING count(DISTINCT day) = 2
   AND count(*) >= 10;

SELECT '=== 0. how much survives the both-days restriction? ===' AS section;
SELECT c.zone, count(*) AS pairs, count(DISTINCT c.band) AS bands
FROM common c GROUP BY 1 ORDER BY 2 DESC;

SELECT '=== 1. median SNR by day and clock time, eclipsed zones vs control ===' AS section;

SELECT
  strftime(time_bucket(INTERVAL '30 minutes', b.tx_time), '%H:%M') AS clock,
  b.band,
  round(median(b.snr) FILTER (WHERE b.day = DATE '2026-08-12'
                                AND c.zone IN ('corridor','near')), 1) AS ecl_day_ecl_zone,
  round(median(b.snr) FILTER (WHERE b.day = DATE '2026-08-13'
                                AND c.zone IN ('corridor','near')), 1) AS ctl_day_ecl_zone,
  round(median(b.snr) FILTER (WHERE b.day = DATE '2026-08-12'
                                AND c.zone = 'far'), 1)                AS ecl_day_far,
  round(median(b.snr) FILTER (WHERE b.day = DATE '2026-08-13'
                                AND c.zone = 'far'), 1)                AS ctl_day_far,
  -- the difference in differences
  round(
    (median(b.snr) FILTER (WHERE b.day = DATE '2026-08-12' AND c.zone IN ('corridor','near'))
   - median(b.snr) FILTER (WHERE b.day = DATE '2026-08-12' AND c.zone = 'far'))
  - (median(b.snr) FILTER (WHERE b.day = DATE '2026-08-13' AND c.zone IN ('corridor','near'))
   - median(b.snr) FILTER (WHERE b.day = DATE '2026-08-13' AND c.zone = 'far')), 2)  AS did_db
FROM both_days b JOIN common c USING (tx_call, rx_call, band)
WHERE b.band IN ('80m', '40m', '30m', '20m')
GROUP BY 1, 2
ORDER BY 2, 1;

SELECT '=== 2. per-pair paired test: same pair, same clock slot, eclipse day vs control ===' AS section;
SELECT '    (the tightest form: every comparison is one pair against itself)' AS section;

WITH paired AS (
  SELECT b.tx_call, b.rx_call, b.band, c.zone,
         time_bucket(INTERVAL '30 minutes', b.tx_time)::TIME AS slot,
         median(b.snr) FILTER (WHERE b.day = DATE '2026-08-12') AS snr_ecl,
         median(b.snr) FILTER (WHERE b.day = DATE '2026-08-13') AS snr_ctl
  FROM both_days b JOIN common c USING (tx_call, rx_call, band)
  GROUP BY 1, 2, 3, 4, 5
)
SELECT
  band,
  strftime(slot, '%H:%M')                       AS clock,
  count(*) FILTER (WHERE zone IN ('corridor','near')
                     AND snr_ecl IS NOT NULL AND snr_ctl IS NOT NULL) AS n_pairs_ecl,
  round(median(snr_ecl - snr_ctl) FILTER (WHERE zone IN ('corridor','near')), 2) AS ecl_zone_db,
  round(median(snr_ecl - snr_ctl) FILTER (WHERE zone = 'far'), 2)                AS far_zone_db,
  round(median(snr_ecl - snr_ctl) FILTER (WHERE zone IN ('corridor','near'))
      - median(snr_ecl - snr_ctl) FILTER (WHERE zone = 'far'), 2)                AS did_db
FROM paired
WHERE band IN ('80m', '40m', '30m', '20m')
GROUP BY 1, 2
HAVING count(*) FILTER (WHERE zone IN ('corridor','near')
                          AND snr_ecl IS NOT NULL AND snr_ctl IS NOT NULL) >= 20
ORDER BY 1, 2;
