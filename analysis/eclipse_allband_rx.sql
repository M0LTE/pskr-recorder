-- Within-receiver contrast across every band with enough data.
--
-- Same idea as eclipse_samerx.sql but swept over all bands, and with path
-- length constrained to 300-2000 km on both sides so the near/far comparison
-- cannot be won on geometry alone. Every row is "the same receiver, in the same
-- 20 minutes, hearing near-shadow paths versus far-from-shadow paths".
--
-- A real absorption effect should show a positive delta that grows toward the
-- low bands. Noise shows a delta scattered around zero with no ordering.

.mode box

CREATE OR REPLACE TEMP TABLE allb AS
SELECT sp.rx_call, sp.band, sp.snr, sp.dist_km,
       time_bucket(INTERVAL '20 minutes', sp.tx_time) AS t20,
       (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat, t.lon)
        FROM eclipse_track t ORDER BY abs(t.epoch - sp.t_tx) LIMIT 1) AS d_shadow_km
FROM s sp
WHERE sp.tx_time BETWEEN '2026-08-12 17:02' AND '2026-08-12 18:32'
  AND sp.mid_lat IS NOT NULL
  AND sp.dist_km BETWEEN 300 AND 2000;

WITH per_rx AS (
  SELECT t20, rx_call, band,
         median(snr) FILTER (WHERE d_shadow_km < 1500)      AS s_near,
         median(snr) FILTER (WHERE d_shadow_km > 3000)      AS s_far,
         median(dist_km) FILTER (WHERE d_shadow_km < 1500)  AS k_near,
         median(dist_km) FILTER (WHERE d_shadow_km > 3000)  AS k_far
  FROM allb GROUP BY 1, 2, 3
)
SELECT band,
       count(*)                                       AS rx_windows,
       round(median(s_near - s_far), 2)               AS within_rx_delta_db,
       round(quantile_cont(s_near - s_far, 0.25), 2)  AS q25,
       round(quantile_cont(s_near - s_far, 0.75), 2)  AS q75,
       round(median(k_near))                          AS km_near,
       round(median(k_far))                           AS km_far
FROM per_rx
WHERE s_near IS NOT NULL AND s_far IS NOT NULL
GROUP BY 1
HAVING count(*) >= 15
ORDER BY CASE band WHEN '160m' THEN 1 WHEN '80m' THEN 2 WHEN '40m' THEN 3
                   WHEN '30m' THEN 4 WHEN '20m' THEN 5 WHEN '17m' THEN 6
                   WHEN '15m' THEN 7 WHEN '12m' THEN 8 WHEN '10m' THEN 9
                   ELSE 10 END;
