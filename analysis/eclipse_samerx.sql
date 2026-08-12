-- Same-receiver test: the one comparison that removes the population confound.
--
-- The dose-response gradient came from comparing paths near the shadow against
-- paths far from it. But those are different places, heard by different
-- receivers with different noise floors and antennas. The confounder audit
-- showed the near-shadow bin drew on only 44 receivers against 114-155
-- elsewhere, so "near the shadow" and "a different set of stations" are the
-- same variable in that comparison.
--
-- Here every receiver is compared against ITSELF: only receivers that logged
-- both near-shadow and far-from-shadow paths inside the same 20-minute window
-- count, and the statistic is the difference within that receiver. Antenna,
-- noise floor, location and operator all cancel.

.mode box

CREATE OR REPLACE TEMP TABLE rx80 AS
SELECT
  sp.rx_call, sp.snr, sp.dist_km, sp.tx_call,
  time_bucket(INTERVAL '20 minutes', sp.tx_time) AS t20,
  (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat, t.lon)
   FROM eclipse_track t ORDER BY abs(t.epoch - sp.t_tx) LIMIT 1) AS d_shadow_km
FROM s sp
WHERE sp.tx_time BETWEEN '2026-08-12 17:02' AND '2026-08-12 18:32'
  AND sp.band = '80m' AND sp.mid_lat IS NOT NULL AND sp.dist_km < 2500;

SELECT '=== within-receiver contrast: near-shadow minus far, same rx, same 20 min ===' AS section;

WITH per_rx AS (
  SELECT t20, rx_call,
         median(snr) FILTER (WHERE d_shadow_km < 1500)  AS snr_near,
         median(snr) FILTER (WHERE d_shadow_km > 3000)  AS snr_far,
         median(dist_km) FILTER (WHERE d_shadow_km < 1500) AS km_near,
         median(dist_km) FILTER (WHERE d_shadow_km > 3000) AS km_far,
         count(*) FILTER (WHERE d_shadow_km < 1500)     AS n_near,
         count(*) FILTER (WHERE d_shadow_km > 3000)     AS n_far
  FROM rx80 GROUP BY 1, 2
)
SELECT
  strftime(t20, '%H:%M')                       AS t,
  count(*)                                     AS receivers_seeing_both,
  round(median(snr_near - snr_far), 2)         AS within_rx_delta_db,
  round(median(snr_near), 1)                   AS med_snr_near,
  round(median(snr_far), 1)                    AS med_snr_far,
  round(median(km_near))                       AS med_km_near,
  round(median(km_far))                        AS med_km_far
FROM per_rx
WHERE snr_near IS NOT NULL AND snr_far IS NOT NULL AND n_near >= 3 AND n_far >= 3
GROUP BY 1 ORDER BY 1;

SELECT '=== how much of the "gradient" is just which receivers are in each bin? ===' AS section;

SELECT
  CASE WHEN d_shadow_km < 1500 THEN 'near (<1500km)' ELSE 'far (>3000km)' END AS bin,
  count(DISTINCT rx_call)                        AS receivers,
  round(median(snr), 1)                          AS med_snr,
  round(median(dist_km))                         AS med_path_km,
  -- the same receivers, restricted to those present in BOTH bins
  round(median(snr) FILTER (
        WHERE rx_call IN (SELECT rx_call FROM rx80 WHERE d_shadow_km < 1500
                          INTERSECT
                          SELECT rx_call FROM rx80 WHERE d_shadow_km > 3000)), 1)
                                                 AS med_snr_shared_rx_only
FROM rx80
WHERE d_shadow_km < 1500 OR d_shadow_km > 3000
GROUP BY 1 ORDER BY 1;
