-- Reusable DuckDB macros for the PSK Reporter eclipse capture.
-- Load with:  duckdb -init /opt/pskr/analysis/macros.sql
-- or inside a session:  .read /opt/pskr/analysis/macros.sql

-- ---------------------------------------------------------------- Maidenhead
-- Decodes 2/4/6/8-character locators to the CENTRE of the referenced cell.
-- Case-insensitive. Returns NULL for anything shorter than a 2-char field.

CREATE OR REPLACE MACRO mh_lon(g0) AS (
  WITH g AS (SELECT upper(g0) AS s)
  SELECT CASE WHEN g0 IS NULL OR length(g0) < 2 THEN NULL ELSE
      (ascii(s[1:1]) - 65) * 20.0 - 180.0
    + CASE WHEN length(s) >= 4 THEN TRY_CAST(s[3:3] AS INTEGER) * 2.0 ELSE 0 END
    + CASE WHEN length(s) >= 6 THEN (ascii(s[5:5]) - 65) * (2.0/24.0) ELSE 0 END
    + CASE WHEN length(s) >= 8 THEN TRY_CAST(s[7:7] AS INTEGER) * (2.0/240.0) ELSE 0 END
    -- half-cell offset so we land in the middle, not the SW corner
    + CASE WHEN length(s) >= 8 THEN (2.0/240.0)/2
           WHEN length(s) >= 6 THEN (2.0/24.0)/2
           WHEN length(s) >= 4 THEN 1.0
           ELSE 10.0 END
  END FROM g
);

CREATE OR REPLACE MACRO mh_lat(g0) AS (
  WITH g AS (SELECT upper(g0) AS s)
  SELECT CASE WHEN g0 IS NULL OR length(g0) < 2 THEN NULL ELSE
      (ascii(s[2:2]) - 65) * 10.0 - 90.0
    + CASE WHEN length(s) >= 4 THEN TRY_CAST(s[4:4] AS INTEGER) * 1.0 ELSE 0 END
    + CASE WHEN length(s) >= 6 THEN (ascii(s[6:6]) - 65) * (1.0/24.0) ELSE 0 END
    + CASE WHEN length(s) >= 8 THEN TRY_CAST(s[8:8] AS INTEGER) * (1.0/240.0) ELSE 0 END
    + CASE WHEN length(s) >= 8 THEN (1.0/240.0)/2
           WHEN length(s) >= 6 THEN (1.0/24.0)/2
           WHEN length(s) >= 4 THEN 0.5
           ELSE 5.0 END
  END FROM g
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
