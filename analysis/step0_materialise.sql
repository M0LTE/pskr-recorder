-- Step 0: dedupe both collector instances, decode locators, compute geometry,
-- write Parquet. Run once after capture, then query the Parquet or the tables.
--
--   duckdb /var/lib/pskr/eclipse.duckdb -init /opt/pskr/analysis/macros.sql \
--          -c ".read /opt/pskr/analysis/step0_materialise.sql"

-- Dedup and Parquet export are both memory-hungry. Spill to disk rather than
-- meeting the OOM killer: by the time this runs over several days of capture
-- the input is tens of GB, far more than will ever fit in RAM.
SET memory_limit = '6GB';
SET temp_directory = '/var/lib/pskr/tmp';
SET preserve_insertion_order = false;   -- large win on bulk scan and COPY

-- Tear the dependency chain down first. CREATE OR REPLACE TABLE fails on a
-- table that a view depends on, so on a SECOND run `spots` silently keeps its
-- old contents while everything downstream is rebuilt from it: the script
-- reports success and the numbers are yesterday's. Found the hard way, on a
-- rerun that cheerfully reported a row count three hours out of date.
-- Order matters: dependants before dependencies.
DROP VIEW  IF EXISTS s;
DROP TABLE IF EXISTS cell_dist;
DROP TABLE IF EXISTS spots;

CREATE OR REPLACE TABLE eclipse_track AS
  SELECT * FROM read_csv_auto('/opt/pskr/analysis/eclipse_track.csv');

CREATE OR REPLACE TABLE spots AS
SELECT
  sq, f, md AS mode, rp AS snr, t, t_tx,
  sc AS tx_call, sl AS tx_grid, rc AS rx_call, rl AS rx_grid,
  sa AS tx_dxcc, ra AS rx_dxcc, b AS band, _rx,
  to_timestamp(t_tx) AS tx_time,
  _rx - t            AS ingest_lag_s,
  mh_lat(sl) AS tx_lat, mh_lon(sl) AS tx_lon,
  mh_lat(rl) AS rx_lat, mh_lon(rl) AS rx_lon,
  gc_mid_lat(mh_lat(sl), mh_lon(sl), mh_lat(rl), mh_lon(rl)) AS mid_lat,
  gc_mid_lon(mh_lat(sl), mh_lon(sl), mh_lat(rl), mh_lon(rl)) AS mid_lon,
  haversine_km(mh_lat(sl), mh_lon(sl), mh_lat(rl), mh_lon(rl)) AS dist_km
FROM (
  SELECT DISTINCT ON (sq) *
  FROM read_json_auto('/var/lib/pskr/clean/spots-*.jsonl.gz',
                      union_by_name = true, ignore_errors = true)
);

-- Distance from each 1-degree cell to the nearest point on the umbral centre
-- line. Fixed in space, so the same corridor is comparable before, during and
-- after the event.
CREATE OR REPLACE TABLE cell_dist AS
WITH cells AS (
  SELECT DISTINCT round(mid_lat) AS clat, round(mid_lon) AS clon
  FROM spots WHERE mid_lat IS NOT NULL
)
SELECT clat, clon, min(haversine_km(clat, clon, t.lat, t.lon)) AS d_track_km
FROM cells CROSS JOIN eclipse_track t
GROUP BY 1, 2;

CREATE OR REPLACE VIEW s AS
SELECT sp.*, cd.d_track_km,
       CASE WHEN cd.d_track_km <  800 THEN 'corridor'
            WHEN cd.d_track_km < 2000 THEN 'near'
            WHEN cd.d_track_km < 4000 THEN 'penumbral'
            ELSE 'far' END AS zone
FROM spots sp
LEFT JOIN cell_dist cd
  ON cd.clat = round(sp.mid_lat) AND cd.clon = round(sp.mid_lon);

COPY (SELECT * FROM s)
  TO '/var/lib/pskr/spots.parquet' (FORMAT parquet, COMPRESSION zstd);

-- max(tx_time) is here so a stale build is obvious at a glance rather than
-- hiding behind a plausible-looking row count.
SELECT count(*)                            AS total_spots,
       max(tx_time)                        AS last_tx_time,
       count(DISTINCT tx_call)             AS tx_stations,
       count(DISTINCT rx_call)             AS rx_stations,
       round(median(ingest_lag_s), 1)      AS median_lag_s,
       round(median(dist_km))              AS median_path_km,
       count(*) FILTER (WHERE mid_lat IS NULL) AS spots_without_geometry
FROM s;
