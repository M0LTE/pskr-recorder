-- Adversarial checks on the 80m dose-response.
--
-- A monotonic gradient with 10 dB of range is exactly what the physics predicts,
-- which is precisely why it needs attacking rather than celebrating. Four ways
-- it could be an artefact, and a test for each:
--
--   1. Path length. Near-shadow paths might simply be shorter, and short paths
--      have better SNR. -> report median path length per bin.
--   2. A handful of loud stations. -> report distinct transmitters, receivers
--      and pairs per bin.
--   3. Geography, not the Moon. -> displaced-shadow placebo: same times, same
--      solar-elevation control, but the track moved 120 degrees east. If the
--      gradient follows the real umbra and not the fake one, geography alone
--      cannot explain it.
--   4. It is not actually time-locked to the eclipse. -> profile through the
--      event; a real effect should grow and decay, not sit there all evening.

.mode box

CREATE OR REPLACE TEMP TABLE ev80 AS
SELECT
  sp.*,
  (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat, t.lon)
   FROM eclipse_track t ORDER BY abs(t.epoch - sp.t_tx) LIMIT 1)          AS d_shadow_km,
  -- same track, same instants, wrong place
  (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat,
                       ((t.lon + 120 + 180) % 360) - 180)
   FROM eclipse_track t ORDER BY abs(t.epoch - sp.t_tx) LIMIT 1)          AS d_fake_km,
  solar_elev(sp.tx_time, sp.mid_lat, sp.mid_lon)                          AS sun_elev
FROM s sp
WHERE sp.tx_time BETWEEN '2026-08-12 17:02' AND '2026-08-12 18:32'
  AND sp.band = '80m' AND sp.mid_lat IS NOT NULL AND sp.dist_km < 2500;

SELECT '=== 1+2. confounder audit: path length and station diversity per bin ===' AS section;

SELECT
  CASE WHEN d_shadow_km < 1000 THEN 'a. <1000km'
       WHEN d_shadow_km < 2000 THEN 'b. 1-2k'
       WHEN d_shadow_km < 3000 THEN 'c. 2-3k'
       WHEN d_shadow_km < 4000 THEN 'd. 3-4k'
       ELSE 'e. >4k' END                       AS dose_bin,
  count(*)                                     AS n,
  round(median(snr), 1)                        AS med_snr,
  round(median(dist_km))                       AS med_path_km,
  count(DISTINCT tx_call)                      AS n_tx,
  count(DISTINCT rx_call)                      AS n_rx,
  count(DISTINCT (tx_call, rx_call))           AS n_pairs
FROM ev80
WHERE sun_elev BETWEEN 10 AND 20
GROUP BY 1 ORDER BY 1;

SELECT '=== 3. displaced-shadow placebo: real umbra vs the same track moved 120E ===' AS section;

SELECT 'REAL shadow'   AS which,
       round(median(snr) FILTER (WHERE d_shadow_km < 1000), 1) AS near,
       round(median(snr) FILTER (WHERE d_shadow_km BETWEEN 2000 AND 3000), 1) AS mid,
       round(median(snr) FILTER (WHERE d_shadow_km > 4000), 1) AS far,
       count(*) FILTER (WHERE d_shadow_km < 1000)              AS n_near
FROM ev80 WHERE sun_elev BETWEEN 10 AND 20
UNION ALL
SELECT 'FAKE shadow +120E',
       round(median(snr) FILTER (WHERE d_fake_km < 1000), 1),
       round(median(snr) FILTER (WHERE d_fake_km BETWEEN 2000 AND 3000), 1),
       round(median(snr) FILTER (WHERE d_fake_km > 4000), 1),
       count(*) FILTER (WHERE d_fake_km < 1000)
FROM ev80 WHERE sun_elev BETWEEN 10 AND 20;

SELECT '=== 4. is it time-locked? near-shadow 80m through the evening ===' AS section;
SELECT '    (paths whose midpoint is within 1000 km of the umbra at that instant)' AS section;

WITH allnight AS (
  SELECT sp.*,
         (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat, t.lon)
          FROM eclipse_track t
          -- clamp to the track ends outside the eclipse, so "near the shadow's
          -- path" stays a meaningful region before and after the event
          ORDER BY abs(t.epoch - least(greatest(sp.t_tx, 1786554120), 1786559520))
          LIMIT 1)                                                      AS d_track_now,
         solar_elev(sp.tx_time, sp.mid_lat, sp.mid_lon)                 AS sun_elev
  FROM s sp
  WHERE sp.tx_time BETWEEN '2026-08-12 15:30' AND '2026-08-12 18:40'
    AND sp.band = '80m' AND sp.mid_lat IS NOT NULL AND sp.dist_km < 2500
)
SELECT
  strftime(time_bucket(INTERVAL '20 minutes', tx_time), '%H:%M') AS t,
  count(*) FILTER (WHERE d_track_now < 1500)                     AS n_near,
  round(median(snr) FILTER (WHERE d_track_now < 1500), 1)        AS snr_near_shadow,
  round(median(snr) FILTER (WHERE d_track_now > 4000), 1)        AS snr_far,
  round(median(sun_elev) FILTER (WHERE d_track_now < 1500), 1)   AS sun_elev_near
FROM allnight
GROUP BY 1 ORDER BY 1;
