-- Step 0: dedupe both collector instances, decode locators, compute geometry.
-- Run once after each capture window, then query `s`.
--
--   cat /opt/pskr/analysis/macros.sql /opt/pskr/analysis/step0_materialise.sql \
--     | duckdb /var/lib/pskr/eclipse.duckdb
--
-- Do NOT pipe the output through `tail`. A failure here prints its error above
-- the result table, and tail will hide it while the summary still looks healthy.
--
-- Memory notes, all learned by hitting them on a 2-core 8 GB box with 12M+ spots:
--
--   * `DISTINCT ON (sq) *` sorts every column of every row. Unprojected that
--     spilled 55 GB; projected to the fourteen needed columns it still passed
--     20 GB. It is replaced below by a hash anti-join, which does not sort.
--   * Materialising the deduped rows into a table AND then copying them out is
--     two full materialisations. Everything now streams once, straight into
--     Parquet, and `spots` is a lazily-read view over that file. Parquet is
--     compressed and columnar, so downstream queries touch only what they need.

SET memory_limit = '6GB';
SET temp_directory = '/var/lib/pskr/tmp';
SET preserve_insertion_order = false;
SET threads = 4;
-- Cap the spill well below free space: the temp directory shares a volume with
-- the live capture, and analysis must never be able to fill the disk out from
-- under the collectors. An earlier run took 55.6 GB of 62 GB free while they
-- were writing.
SET max_temp_directory_size = '20GiB';

-- Tear the dependency chain down first, dependants before dependencies. A
-- failed CREATE OR REPLACE leaves the previous object in place, and everything
-- downstream then rebuilds happily from stale data and reports success.
DROP VIEW  IF EXISTS s;
DROP TABLE IF EXISTS cell_dist;
DROP VIEW  IF EXISTS spots;
DROP TABLE IF EXISTS spots;

CREATE OR REPLACE TABLE eclipse_track AS
  SELECT * FROM read_csv_auto('/opt/pskr/analysis/eclipse_track.csv');

-- ---------------------------------------------------------------- dedup
-- Within one instance sq is already unique: each collector run writes its own
-- file, files are disjoint in time, and sq is a global sequence. So the union
-- of the two instances is "all of one, plus the rows the other has that it
-- lacks" -- a hash anti-join on a single int64 column, no sort.

CREATE OR REPLACE TEMP TABLE sq_base AS
SELECT sq FROM read_json_auto('/var/lib/pskr/clean/spots-*-b*.jsonl.gz',
                              union_by_name = true, ignore_errors = true);

-- Guard the assumption instead of trusting it.
SELECT CASE WHEN count(*) = count(DISTINCT sq)
            THEN 'ok: base instance has no duplicate sq'
            ELSE 'WARNING: duplicate sq in base instance, dedup assumption broken'
       END AS dedup_assumption,
       count(*) AS base_rows
FROM sq_base;

-- Which sq values does the other instance have that the base lacks? Both sides
-- are a single int64 column here. Joining the FULL rows instead is what blew up:
-- a plain COPY of one instance runs in 8 seconds with no spill, while the same
-- COPY with a 14-column LEFT JOIN welded on exceeded 20 GB of temp. Keep the
-- join narrow and let the wide scans stream untouched.
CREATE OR REPLACE TEMP TABLE sq_extra AS
SELECT a.sq
FROM (SELECT sq FROM read_json_auto('/var/lib/pskr/clean/spots-*-a*.jsonl.gz',
                                    union_by_name = true, ignore_errors = true)) a
LEFT JOIN sq_base ON sq_base.sq = a.sq
WHERE sq_base.sq IS NULL;

SELECT count(*) AS rows_only_in_other_instance FROM sq_extra;

-- Base instance: no join at all, streams straight out.
COPY (
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
  FROM read_json_auto('/var/lib/pskr/clean/spots-*-b*.jsonl.gz',
                      union_by_name = true, ignore_errors = true)
) TO '/var/lib/pskr/spots_base.parquet' (FORMAT parquet, COMPRESSION zstd);

-- Only the gap rows from the other instance. The filter set is tiny, so this
-- scan produces almost nothing and costs a hash probe per row.
COPY (
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
  FROM read_json_auto('/var/lib/pskr/clean/spots-*-a*.jsonl.gz',
                      union_by_name = true, ignore_errors = true)
  WHERE sq IN (SELECT sq FROM sq_extra)
) TO '/var/lib/pskr/spots_gap.parquet' (FORMAT parquet, COMPRESSION zstd);

CREATE VIEW spots AS
SELECT * FROM read_parquet(['/var/lib/pskr/spots_base.parquet',
                            '/var/lib/pskr/spots_gap.parquet']);

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

CREATE VIEW s AS
SELECT sp.*, cd.d_track_km,
       CASE WHEN cd.d_track_km <  800 THEN 'corridor'
            WHEN cd.d_track_km < 2000 THEN 'near'
            WHEN cd.d_track_km < 4000 THEN 'penumbral'
            ELSE 'far' END AS zone
FROM spots sp
LEFT JOIN cell_dist cd
  ON cd.clat = round(sp.mid_lat) AND cd.clon = round(sp.mid_lon);

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
