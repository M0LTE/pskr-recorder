-- How much of this eclipse was actually measurable from where the operators are?
--
-- The D layer only absorbs where the Sun is shining on it, so the size of any
-- eclipse effect scales with how high the Sun was over the affected paths. This
-- eclipse crossed the Arctic and Greenland Sea first, where there is nobody, and
-- only reached populated ground late, near sunset. That is a physical limit on
-- what any measurement could have found, quite separate from statistics.

.mode box

CREATE OR REPLACE TEMP TABLE g AS
SELECT sp.band, sp.snr, sp.t_tx, sp.tx_time,
       (SELECT haversine_km(sp.mid_lat, sp.mid_lon, t.lat, t.lon)
        FROM eclipse_track t ORDER BY abs(t.epoch - sp.t_tx) LIMIT 1) AS d_shadow_km,
       solar_elev(sp.tx_time, sp.mid_lat, sp.mid_lon)                 AS sun_elev
FROM s sp
WHERE sp.tx_time BETWEEN '2026-08-12 17:02' AND '2026-08-12 18:32'
  AND sp.mid_lat IS NOT NULL;

SELECT '=== spots under the shadow, by how high the Sun was there ===' AS section;

SELECT
  CAST(floor(sun_elev / 10) * 10 AS INT)                        AS sun_elev_band,
  count(*) FILTER (WHERE d_shadow_km < 1000)                    AS under_shadow,
  count(*) FILTER (WHERE d_shadow_km < 1000
                     AND band IN ('80m', '160m'))               AS low_band_under_shadow
FROM g
GROUP BY 1 ORDER BY 1;

SELECT '=== when did the shadow reach anywhere with operators? ===' AS section;

SELECT
  strftime(time_bucket(INTERVAL '10 minutes', tx_time), '%H:%M') AS t,
  count(*) FILTER (WHERE d_shadow_km < 1000)                     AS n_under_shadow,
  round(median(sun_elev) FILTER (WHERE d_shadow_km < 1000), 1)   AS sun_elev_there
FROM g GROUP BY 1 ORDER BY 1;
