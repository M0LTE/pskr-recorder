-- Cross-instance capture integrity.
--
-- The broker's `sq` is a contiguous global sequence, so a spot present in one
-- instance and absent from the other is a real loss in that instance. This is
-- the whole justification for running two collectors.
--
--   duckdb -c ".read /opt/pskr/analysis/integrity.sql"
--
-- The LIKE patterns match both spots-<hour>-a.jsonl.gz and the .rN files a
-- restart produces.

SET memory_limit = '6GB';
SET temp_directory = '/var/lib/pskr/tmp';
SET preserve_insertion_order = false;

SELECT count(*) FILTER (WHERE ha AND hb)     AS in_both,
       count(*) FILTER (WHERE ha AND NOT hb) AS a_only,
       count(*) FILTER (WHERE NOT ha AND hb) AS b_only,
       count(*)                              AS union_total,
       round(100.0 * count(*) FILTER (WHERE ha) / count(*), 3) AS pct_in_a,
       round(100.0 * count(*) FILTER (WHERE hb) / count(*), 3) AS pct_in_b
FROM (
  SELECT sq,
         bool_or(filename LIKE '%-a.%') AS ha,
         bool_or(filename LIKE '%-b.%') AS hb
  FROM read_json_auto('/var/lib/pskr/clean/spots-*.jsonl.gz',
                      filename = true, union_by_name = true, ignore_errors = true)
  GROUP BY sq
);
