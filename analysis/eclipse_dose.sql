-- Dose-response, controlled for solar elevation.
--
-- Two problems with a naive before/during comparison, both fixed here:
--
--   1. The static zones are fixed in space, so a path near Iceland counts as
--      "corridor" all evening even though it was only under the shadow at
--      17:48. That smears any real timing. Here the dose is the distance from
--      where the umbra ACTUALLY WAS at the moment of transmission.
--
--   2. The eclipse coincides with dusk. So everything below is grouped by solar
--      elevation at the path midpoint: within one elevation band the Sun is
--      equally high for every path, and the only thing that differs is how
--      close the shadow was. A trend across dose bins inside a fixed elevation
--      band cannot be the diurnal cycle.
--
-- Requires: macros.sql, solar.sql, and step0.

.mode box

CREATE OR REPLACE TEMP TABLE ev AS
SELECT
  sp.*,
  -- nearest track sample; the track is 2-minutely and the umbra moves ~120 km
  -- in that time, so this is good to about 60 km, well inside the bin width
  (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat, t.lon)
   FROM eclipse_track t
   ORDER BY abs(t.epoch - sp.t_tx) LIMIT 1)                     AS d_shadow_km,
  solar_elev(sp.tx_time, sp.mid_lat, sp.mid_lon)                AS sun_elev
FROM s sp
WHERE sp.tx_time BETWEEN '2026-08-12 17:02' AND '2026-08-12 18:32'
  AND sp.mid_lat IS NOT NULL
  AND sp.dist_km < 2500;

SELECT '=== A. dose-response DURING the eclipse, within solar-elevation bands ===' AS section;
SELECT '    (read across each row: does SNR change with distance from the shadow?)' AS section;

SELECT
  CAST(floor(sun_elev / 10) * 10 AS INT) AS sun_elev_band,
  band,
  round(median(snr) FILTER (WHERE d_shadow_km < 1000), 1)                        AS d_0_1000,
  round(median(snr) FILTER (WHERE d_shadow_km BETWEEN 1000 AND 2000), 1)         AS d_1_2k,
  round(median(snr) FILTER (WHERE d_shadow_km BETWEEN 2000 AND 3000), 1)         AS d_2_3k,
  round(median(snr) FILTER (WHERE d_shadow_km > 4000), 1)                        AS d_over_4k,
  count(*) FILTER (WHERE d_shadow_km < 1000)                                     AS n_near_shadow,
  count(*)                                                                       AS n_total
FROM ev
WHERE band IN ('80m', '40m', '30m', '20m')
  AND sun_elev BETWEEN 0 AND 60
GROUP BY 1, 2
HAVING count(*) FILTER (WHERE d_shadow_km < 1000) >= 30
ORDER BY 2, 1;

SELECT '=== B. PLACEBO: same computation two hours earlier, no eclipse ===' AS section;
SELECT '    (any pattern here is an artefact of geography, not the Moon)' AS section;

CREATE OR REPLACE TEMP TABLE placebo AS
SELECT
  sp.*,
  -- distance to where the shadow WOULD have been, had the eclipse run 2h early
  (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat, t.lon)
   FROM eclipse_track t
   ORDER BY abs((t.epoch - 7200) - sp.t_tx) LIMIT 1)            AS d_shadow_km,
  solar_elev(sp.tx_time, sp.mid_lat, sp.mid_lon)                AS sun_elev
FROM s sp
WHERE sp.tx_time BETWEEN '2026-08-12 15:02' AND '2026-08-12 16:32'
  AND sp.mid_lat IS NOT NULL
  AND sp.dist_km < 2500;

SELECT
  CAST(floor(sun_elev / 10) * 10 AS INT) AS sun_elev_band,
  band,
  round(median(snr) FILTER (WHERE d_shadow_km < 1000), 1)                        AS d_0_1000,
  round(median(snr) FILTER (WHERE d_shadow_km BETWEEN 1000 AND 2000), 1)         AS d_1_2k,
  round(median(snr) FILTER (WHERE d_shadow_km BETWEEN 2000 AND 3000), 1)         AS d_2_3k,
  round(median(snr) FILTER (WHERE d_shadow_km > 4000), 1)                        AS d_over_4k,
  count(*) FILTER (WHERE d_shadow_km < 1000)                                     AS n_near_shadow
FROM placebo
WHERE band IN ('80m', '40m', '30m', '20m')
  AND sun_elev BETWEEN 0 AND 60
GROUP BY 1, 2
HAVING count(*) FILTER (WHERE d_shadow_km < 1000) >= 30
ORDER BY 2, 1;
