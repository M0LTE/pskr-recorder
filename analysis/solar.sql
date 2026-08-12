-- Solar position, so the eclipse can be separated from the sunset it happens during.
--
-- The whole difficulty with this event is that it lands on European dusk, when
-- the low bands improve anyway. Comparing "before" with "during" therefore
-- measures dusk, not the Moon. The fix is to control for how high the Sun is:
-- compare paths at the SAME solar elevation that differ only in how close they
-- are to the shadow. Anything left after that cannot be the diurnal cycle.
--
-- NOAA general solar position equations. Good to about 0.1 degrees, far better
-- than we need for binning into 5-degree buckets.

CREATE OR REPLACE MACRO solar_decl(ts) AS (
  WITH g AS (
    SELECT 2 * pi() / 365.0 * (dayofyear(ts) - 1 + (hour(ts) - 12) / 24.0) AS y
  )
  SELECT 0.006918 - 0.399912 * cos(y) + 0.070257 * sin(y)
       - 0.006758 * cos(2 * y) + 0.000907 * sin(2 * y)
       - 0.002697 * cos(3 * y) + 0.00148 * sin(3 * y)      -- radians
  FROM g
);

CREATE OR REPLACE MACRO solar_eqtime(ts) AS (
  WITH g AS (
    SELECT 2 * pi() / 365.0 * (dayofyear(ts) - 1 + (hour(ts) - 12) / 24.0) AS y
  )
  SELECT 229.18 * (0.000075 + 0.001868 * cos(y) - 0.032077 * sin(y)
                 - 0.014615 * cos(2 * y) - 0.040849 * sin(2 * y))   -- minutes
  FROM g
);

-- Solar zenith angle in degrees. 0 = overhead, 90 = on the horizon,
-- >90 = below the horizon (night).
CREATE OR REPLACE MACRO solar_zenith(ts, lat, lon) AS (
  degrees(acos(greatest(-1, least(1,
      sin(radians(lat)) * sin(solar_decl(ts))
    + cos(radians(lat)) * cos(solar_decl(ts))
      * cos(radians(
          (hour(ts) * 60 + minute(ts) + second(ts) / 60.0
           + solar_eqtime(ts) + 4 * lon) / 4 - 180
        ))
  ))))
);

-- Solar elevation is just the complement, and reads more naturally.
CREATE OR REPLACE MACRO solar_elev(ts, lat, lon) AS (90 - solar_zenith(ts, lat, lon));
