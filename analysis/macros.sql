-- Reusable DuckDB macros for the PSK Reporter eclipse capture.
-- Load with:  duckdb -init /opt/pskr/analysis/macros.sql
-- or inside a session:  .read /opt/pskr/analysis/macros.sql

-- ---------------------------------------------------------------- Maidenhead
-- Decodes 2/4/6/8-character locators to the CENTRE of the referenced cell.
-- Case-insensitive. Returns NULL for anything shorter than a 2-char field.

-- These MUST stay pure expressions. Written with a `WITH ... SELECT ... FROM g`
-- body to avoid repeating upper(), each call became a correlated scalar
-- subquery, which DuckDB rewrites into a materialising join. Between the
-- midpoint and the distance, one row costs about sixteen of these, so over 12M
-- rows the plan tried to materialise its way through 20 GB of temp and died.
-- Repeating upper() is far cheaper than a subquery.

CREATE OR REPLACE MACRO mh_lon(g) AS (
  CASE WHEN g IS NULL OR length(g) < 2 THEN NULL ELSE
      (ascii(upper(g[1:1])) - 65) * 20.0 - 180.0
    + CASE WHEN length(g) >= 4 THEN TRY_CAST(g[3:3] AS INTEGER) * 2.0 ELSE 0 END
    + CASE WHEN length(g) >= 6 THEN (ascii(upper(g[5:5])) - 65) * (2.0/24.0) ELSE 0 END
    + CASE WHEN length(g) >= 8 THEN TRY_CAST(g[7:7] AS INTEGER) * (2.0/240.0) ELSE 0 END
    -- half-cell offset so we land in the middle, not the SW corner
    + CASE WHEN length(g) >= 8 THEN (2.0/240.0)/2
           WHEN length(g) >= 6 THEN (2.0/24.0)/2
           WHEN length(g) >= 4 THEN 1.0
           ELSE 10.0 END
  END
);

CREATE OR REPLACE MACRO mh_lat(g) AS (
  CASE WHEN g IS NULL OR length(g) < 2 THEN NULL ELSE
      (ascii(upper(g[2:2])) - 65) * 10.0 - 90.0
    + CASE WHEN length(g) >= 4 THEN TRY_CAST(g[4:4] AS INTEGER) * 1.0 ELSE 0 END
    + CASE WHEN length(g) >= 6 THEN (ascii(upper(g[6:6])) - 65) * (1.0/24.0) ELSE 0 END
    + CASE WHEN length(g) >= 8 THEN TRY_CAST(g[8:8] AS INTEGER) * (1.0/240.0) ELSE 0 END
    + CASE WHEN length(g) >= 8 THEN (1.0/240.0)/2
           WHEN length(g) >= 6 THEN (1.0/24.0)/2
           WHEN length(g) >= 4 THEN 0.5
           ELSE 5.0 END
  END
);

-- ---------------------------------------------------------------- geometry

CREATE OR REPLACE MACRO haversine_km(lat1, lon1, lat2, lon2) AS (
  6371.0088 * 2 * asin(sqrt(
      pow(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2))
      * pow(sin(radians(lon2 - lon1) / 2), 2)
  ))
);

-- Great-circle midpoint of a path. This is the crude but standard proxy for
-- the ionospheric reflection point on a one-hop path. On multi-hop paths it is
-- only indicative -- see NOTES.md.
CREATE OR REPLACE MACRO gc_mid_lat(lat1, lon1, lat2, lon2) AS (
  degrees(atan2(
    sin(radians(lat1)) + sin(radians(lat2)),
    sqrt(pow(cos(radians(lat1)) + cos(radians(lat2)) * cos(radians(lon2 - lon1)), 2)
       + pow(cos(radians(lat2)) * sin(radians(lon2 - lon1)), 2))
  ))
);

CREATE OR REPLACE MACRO gc_mid_lon(lat1, lon1, lat2, lon2) AS (
  degrees(radians(lon1) + atan2(
    cos(radians(lat2)) * sin(radians(lon2 - lon1)),
    cos(radians(lat1)) + cos(radians(lat2)) * cos(radians(lon2 - lon1))
  ))
);
