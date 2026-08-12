-- The two analyses that need complete data, now that the late-report tail has landed.
--
-- Both work on a FIXED set of transmitter/receiver/band triples, each compared
-- against its own earlier self. That removes everything the earlier rounds
-- tripped over: differing receiver populations, differing path lengths,
-- differing antennas and noise floors. A pair is compared only with itself.

.mode box

-- ============================================================ A. superposed epoch
-- Different places went under the shadow at different times: Iceland at 17:48,
-- Iberia at 18:27. Binning by clock time therefore smears the effect across an
-- hour. Here each path is aligned to ITS OWN moment of closest approach, so the
-- x axis is "minutes from local maximum eclipse" and every path's event lines up
-- at zero. If there is an absorption effect this is where it shows.

-- Closest approach of the umbra to each 1-degree cell, computed once. Doing this
-- as a per-row correlated subquery is ~46 haversines per spot over millions of
-- spots; there are only a few thousand distinct cells, so precompute and join.
CREATE OR REPLACE TEMP TABLE cell_ecl AS
WITH cells AS (
  SELECT DISTINCT round(mid_lat) AS clat, round(mid_lon) AS clon
  FROM s WHERE mid_lat IS NOT NULL
),
d AS (
  SELECT c.clat, c.clon, t.epoch,
         haversine_km(c.clat, c.clon, t.lat, t.lon) AS km,
         row_number() OVER (PARTITION BY c.clat, c.clon
                            ORDER BY haversine_km(c.clat, c.clon, t.lat, t.lon)) AS rn
  FROM cells c CROSS JOIN eclipse_track t
)
SELECT clat, clon, epoch AS t_ecl, km AS d_min_km FROM d WHERE rn = 1;

CREATE OR REPLACE TEMP TABLE ep AS
SELECT sp.*, ce.t_ecl, ce.d_min_km,
       (sp.t_tx - ce.t_ecl) / 60.0 AS dt_min
FROM s sp
JOIN cell_ecl ce ON ce.clat = round(sp.mid_lat) AND ce.clon = round(sp.mid_lon)
WHERE sp.tx_time BETWEEN '2026-08-12 14:30' AND '2026-08-12 21:00'
  AND sp.mid_lat IS NOT NULL
  AND sp.dist_km BETWEEN 300 AND 2500
  AND (sp.t_tx - ce.t_ecl) / 60.0 BETWEEN -180 AND 120;

-- Each pair's own pre-eclipse level, from 3 to 2 hours before its local maximum
CREATE OR REPLACE TEMP TABLE base AS
SELECT tx_call, rx_call, band, median(snr) AS snr0, count(*) AS n0
FROM ep WHERE dt_min BETWEEN -180 AND -120
GROUP BY 1, 2, 3 HAVING count(*) >= 3;

SELECT '=== A. SNR change vs minutes from local maximum eclipse, by band ===' AS section;
SELECT '    (each pair against its own pre-eclipse level; 0 = local maximum)' AS section;

SELECT
  CAST(floor(e.dt_min / 20) * 20 AS INT)              AS dt_bin_min,
  round(median(e.snr - b.snr0) FILTER (WHERE e.d_min_km < 1000), 2)  AS d_snr_eclipsed,
  count(*) FILTER (WHERE e.d_min_km < 1000)                          AS n_eclipsed,
  round(median(e.snr - b.snr0) FILTER (WHERE e.d_min_km > 3000), 2)  AS d_snr_control,
  count(*) FILTER (WHERE e.d_min_km > 3000)                          AS n_control
FROM ep e JOIN base b USING (tx_call, rx_call, band)
WHERE e.band IN ('80m', '40m', '30m')
GROUP BY 1
HAVING count(*) FILTER (WHERE e.d_min_km < 1000) >= 50
ORDER BY 1;

SELECT '=== A2. same, split by band ===' AS section;

SELECT
  e.band,
  CAST(floor(e.dt_min / 30) * 30 AS INT)              AS dt_bin_min,
  round(median(e.snr - b.snr0) FILTER (WHERE e.d_min_km < 1500), 2)  AS d_snr_eclipsed,
  count(*) FILTER (WHERE e.d_min_km < 1500)                          AS n_ecl,
  round(median(e.snr - b.snr0) FILTER (WHERE e.d_min_km > 3000), 2)  AS d_snr_control
FROM ep e JOIN base b USING (tx_call, rx_call, band)
WHERE e.band IN ('80m', '40m', '30m', '20m')
GROUP BY 1, 2
HAVING count(*) FILTER (WHERE e.d_min_km < 1500) >= 40
ORDER BY 1, 2;

SELECT '=== A3. detection rate, not level: FT8 SNR saturates, decodability does not ===' AS section;
SELECT '    (of the pairs known to be active, what fraction got reported per bin)' AS section;

-- WSJT-X clips SNR at the top and truncates at the decode threshold, so a large
-- improvement shows up as paths starting to decode rather than as better numbers.
-- Over a FIXED pair set, reports-per-pair is that missing half of the picture.
WITH known AS (
  SELECT DISTINCT tx_call, rx_call, band, d_min_km FROM ep
)
SELECT
  CAST(floor(e.dt_min / 30) * 30 AS INT)                       AS dt_bin_min,
  round(count(*) FILTER (WHERE e.d_min_km < 1500)::DOUBLE
      / nullif(count(DISTINCT (e.tx_call, e.rx_call, e.band))
               FILTER (WHERE e.d_min_km < 1500), 0), 2)        AS reports_per_pair_ecl,
  round(count(*) FILTER (WHERE e.d_min_km > 3000)::DOUBLE
      / nullif(count(DISTINCT (e.tx_call, e.rx_call, e.band))
               FILTER (WHERE e.d_min_km > 3000), 0), 2)        AS reports_per_pair_ctl,
  count(*) FILTER (WHERE e.d_min_km < 1500)                    AS n_ecl
FROM ep e
WHERE e.band IN ('80m', '40m', '30m')
GROUP BY 1 ORDER BY 1;

-- ============================================================ B. persistent pairs
-- Clock-time view over the whole evening, restricted to pairs that were active
-- throughout. Answers "did anything happen at all", with no population drift.

SELECT '=== B. persistent pairs through the evening, clock time ===' AS section;

CREATE OR REPLACE TEMP TABLE win AS
SELECT * FROM s
WHERE tx_time BETWEEN '2026-08-12 15:30' AND '2026-08-12 20:30'
  AND dist_km BETWEEN 300 AND 2500 AND mid_lat IS NOT NULL;

CREATE OR REPLACE TEMP TABLE persist AS
SELECT tx_call, rx_call, band, any_value(zone) AS zone
FROM win GROUP BY 1, 2, 3
HAVING count(DISTINCT time_bucket(INTERVAL '30 minutes', tx_time)) >= 6;

SELECT
  strftime(time_bucket(INTERVAL '20 minutes', w.tx_time), '%H:%M') AS t,
  w.band,
  round(median(w.snr) FILTER (WHERE p.zone IN ('corridor','near')), 1) AS snr_ecl_zone,
  count(*) FILTER (WHERE p.zone IN ('corridor','near'))               AS n_ecl,
  round(median(w.snr) FILTER (WHERE p.zone = 'far'), 1)               AS snr_far,
  round(median(w.snr) FILTER (WHERE p.zone IN ('corridor','near'))
      - median(w.snr) FILTER (WHERE p.zone = 'far'), 1)               AS delta
FROM win w JOIN persist p USING (tx_call, rx_call, band)
WHERE w.band IN ('80m', '40m', '30m')
GROUP BY 1, 2
HAVING count(*) FILTER (WHERE p.zone IN ('corridor','near')) >= 30
ORDER BY 2, 1;
