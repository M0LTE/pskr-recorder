-- First look at the 2026-08-12 eclipse window.
-- Assumes step0 has been run and macros.sql + solar.sql are loaded.

.mode box

SELECT '=== 1. coverage: is there enough data in the corridor to say anything? ===' AS section;

SELECT zone,
       count(*)                                        AS spots,
       count(*) FILTER (WHERE tx_time BETWEEN '2026-08-12 17:00' AND '2026-08-12 18:35') AS during,
       count(DISTINCT rx_call)                         AS rx_stations,
       round(median(dist_km))                          AS med_path_km
FROM s
WHERE tx_time BETWEEN '2026-08-12 14:00' AND '2026-08-12 19:00'
GROUP BY 1 ORDER BY 2 DESC;

SELECT '=== 2. time profile: median SNR by zone, 15 min bins, low bands ===' AS section;

-- The eclipse-sensitive bands. 'far' is the spatial control in the same instant.
SELECT
  strftime(time_bucket(INTERVAL '15 minutes', tx_time), '%H:%M') AS t,
  band,
  count(*) FILTER (WHERE zone = 'corridor')                       AS n_cor,
  round(median(snr) FILTER (WHERE zone = 'corridor'), 1)          AS snr_cor,
  round(median(snr) FILTER (WHERE zone = 'near'), 1)              AS snr_near,
  round(median(snr) FILTER (WHERE zone = 'far'), 1)               AS snr_far,
  round(median(snr) FILTER (WHERE zone = 'corridor')
      - median(snr) FILTER (WHERE zone = 'far'), 1)               AS cor_minus_far
FROM s
WHERE tx_time BETWEEN '2026-08-12 15:00' AND '2026-08-12 19:00'
  AND band IN ('80m', '40m', '30m')
  AND dist_km < 2500          -- midpoint only means something on short paths
GROUP BY 1, 2
ORDER BY 2, 1;

SELECT '=== 3. same, for the high bands (expected: late, weak, or nothing) ===' AS section;

SELECT
  strftime(time_bucket(INTERVAL '15 minutes', tx_time), '%H:%M') AS t,
  band,
  round(median(snr) FILTER (WHERE zone = 'corridor'), 1)          AS snr_cor,
  round(median(snr) FILTER (WHERE zone = 'far'), 1)               AS snr_far,
  round(median(snr) FILTER (WHERE zone = 'corridor')
      - median(snr) FILTER (WHERE zone = 'far'), 1)               AS cor_minus_far
FROM s
WHERE tx_time BETWEEN '2026-08-12 15:00' AND '2026-08-12 19:00'
  AND band IN ('20m', '15m')
  AND dist_km < 2500
GROUP BY 1, 2
ORDER BY 2, 1;
