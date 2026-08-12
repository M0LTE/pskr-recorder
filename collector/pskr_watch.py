#!/usr/bin/env python3
"""
Live eclipse watcher for the PSK Reporter feed.

Strictly read-only and completely independent of the collectors: it opens its
own MQTT subscription and holds everything in memory. If this dies, crashes or
is killed, the capture is untouched. Nothing here writes to the data directory.

Splits spots by how close the great-circle midpoint of the path lies to the
umbral centre line of the 2026-08-12 eclipse, and shows spot rate and median
SNR per band per zone over a rolling window.

  corridor   < 800 km from the centre line
  near        800 - 2000 km
  penumbral  2000 - 4000 km
  far        everything else (the control)

Usage:  pskr-watch [--window-min 20] [--interval 15] [--bands 160m,80m,40m,30m,20m]
"""

import argparse
import bisect
import csv
import json
import math
import os
import random
import sys
import threading
import time
from collections import defaultdict

import paho.mqtt.client as mqtt

TRACK_CSV = os.environ.get(
    "PSKR_TRACK", "/opt/pskr/analysis/eclipse_track.csv"
)
HOST = os.environ.get("PSKR_HOST", "mqtt.pskreporter.info")
PORT = int(os.environ.get("PSKR_PORT", "1883"))
TOPIC = os.environ.get("PSKR_TOPIC", "pskr/filter/v2/#")

SAMPLE_CAP = 3000  # reservoir size per (minute, band, zone) cell

# Observer location, for the "where is the shadow relative to me" readout.
HOME_NAME = os.environ.get("PSKR_HOME_NAME", "Reading UK")
HOME_LAT = float(os.environ.get("PSKR_HOME_LAT", "51.4543"))
HOME_LON = float(os.environ.get("PSKR_HOME_LON", "-0.9781"))

# ------------------------------------------------------------------ geometry

def load_track(path):
    pts = []
    with open(path) as f:
        for row in csv.DictReader(f):
            pts.append((int(row["epoch"]), float(row["lat"]), float(row["lon"])))
    pts.sort()
    return pts


TRACK = load_track(TRACK_CSV)
TRACK_EPOCHS = [p[0] for p in TRACK]


def maidenhead(g):
    """Locator -> (lat, lon) at the centre of the cell. None if unusable."""
    if not g or len(g) < 4:
        return None
    g = g.upper()
    try:
        lon = (ord(g[0]) - 65) * 20.0 - 180.0 + int(g[2]) * 2.0
        lat = (ord(g[1]) - 65) * 10.0 - 90.0 + int(g[3]) * 1.0
        if len(g) >= 6:
            lon += (ord(g[4]) - 65) * (2.0 / 24.0)
            lat += (ord(g[5]) - 65) * (1.0 / 24.0)
            if len(g) >= 8 and g[6].isdigit() and g[7].isdigit():
                lon += int(g[6]) * (2.0 / 240.0) + (2.0 / 240.0) / 2
                lat += int(g[7]) * (1.0 / 240.0) + (1.0 / 240.0) / 2
            else:
                lon += (2.0 / 24.0) / 2
                lat += (1.0 / 24.0) / 2
        else:
            lon += 1.0
            lat += 0.5
    except (ValueError, IndexError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return lat, lon


def haversine_km(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0088 * 2 * math.asin(math.sqrt(a))


def gc_midpoint(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    l1 = math.radians(lon1)
    dl = math.radians(lon2 - lon1)
    bx = math.cos(p2) * math.cos(dl)
    by = math.cos(p2) * math.sin(dl)
    lat = math.atan2(math.sin(p1) + math.sin(p2),
                     math.sqrt((math.cos(p1) + bx) ** 2 + by ** 2))
    lon = l1 + math.atan2(by, math.cos(p1) + bx)
    return math.degrees(lat), (math.degrees(lon) + 540) % 360 - 180


_cell_cache = {}


def dist_to_track(lat, lon):
    """Min distance to the centre line, cached per 1-degree cell."""
    key = (round(lat), round(lon))
    d = _cell_cache.get(key)
    if d is None:
        d = min(haversine_km(key[0], key[1], p[1], p[2]) for p in TRACK)
        _cell_cache[key] = d
    return d


def shadow_at(epoch):
    """Interpolated umbral centre position, or None if the umbra is not on Earth."""
    if epoch < TRACK_EPOCHS[0] or epoch > TRACK_EPOCHS[-1]:
        return None
    i = bisect.bisect_left(TRACK_EPOCHS, epoch)
    if i == 0:
        return TRACK[0][1], TRACK[0][2]
    t0, la0, lo0 = TRACK[i - 1]
    t1, la1, lo1 = TRACK[i]
    if t1 == t0:
        return la0, lo0
    w = (epoch - t0) / (t1 - t0)
    return la0 + w * (la1 - la0), lo0 + w * (lo1 - lo0)


def zone_of(d):
    if d < 800:
        return "corridor"
    if d < 2000:
        return "near"
    if d < 4000:
        return "penumbral"
    return "far"


ZONES = ["corridor", "near", "penumbral", "far"]

# Closest approach of the umbral centre line to the observer, from the track.
_ca = min(TRACK, key=lambda p: haversine_km(HOME_LAT, HOME_LON, p[1], p[2]))
HOME_CA_UTC = time.strftime("%H:%M", time.gmtime(_ca[0]))
HOME_CA_KM = round(haversine_km(HOME_LAT, HOME_LON, _ca[1], _ca[2]))

# ------------------------------------------------------------------ state

lock = threading.Lock()
cells = defaultdict(lambda: {"n": 0, "s": []})  # (minute, band, zone) -> agg
totals = {"msgs": 0, "bad": 0, "lag_sum": 0.0, "lag_n": 0}


def add_sample(cell, v):
    """Count every spot; only feed numeric reports into the SNR reservoir.
    Some spots carry a null rp, which must not poison the median."""
    cell["n"] += 1
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return
    s = cell["s"]
    if len(s) < SAMPLE_CAP:
        s.append(v)
    else:  # reservoir: keep the sample unbiased over the whole minute
        j = random.randrange(cell["n"])
        if j < SAMPLE_CAP:
            s[j] = v


def on_message(client, userdata, msg):
    try:
        d = json.loads(msg.payload)
    except Exception:
        with lock:
            totals["bad"] += 1
        return

    sl, rl = d.get("sl"), d.get("rl")
    a, b = maidenhead(sl), maidenhead(rl)
    if not a or not b:
        with lock:
            totals["msgs"] += 1
        return

    mlat, mlon = gc_midpoint(a[0], a[1], b[0], b[1])
    z = zone_of(dist_to_track(mlat, mlon))
    minute = int(d.get("t_tx") or d.get("t") or time.time()) // 60 * 60

    with lock:
        totals["msgs"] += 1
        t = d.get("t")
        if t:
            totals["lag_sum"] += time.time() - t
            totals["lag_n"] += 1
        add_sample(cells[(minute, d.get("b", "?"), z)], d.get("rp"))


def median(v):
    if not v:
        return None
    v = sorted(v)
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2.0


# ------------------------------------------------------------------ display

def render(bands, window_min):
    now = time.time()
    cutoff = now - window_min * 60

    with lock:
        for k in [k for k in cells if k[0] < cutoff - 600]:
            del cells[k]
        snap = {k: (v["n"], list(v["s"])) for k, v in cells.items() if k[0] >= cutoff}
        tot = dict(totals)

    per = defaultdict(lambda: {"n": 0, "s": []})
    minutes = set()
    for (minute, band, z), (n, s) in snap.items():
        minutes.add(minute)
        c = per[(band, z)]
        c["n"] += n
        c["s"].extend(s)

    nmin = max(len(minutes), 1)
    lag = tot["lag_sum"] / tot["lag_n"] if tot["lag_n"] else 0.0
    shadow = shadow_at(now - lag)

    out = []
    out.append("=" * 78)
    out.append("PSK Reporter eclipse watch   %s UTC   window %d min"
               % (time.strftime("%H:%M:%S", time.gmtime()), window_min))
    if shadow:
        out.append("  UMBRA ON EARTH at %.1fN %.1fE, %d km from %s  (feed lag %.0fs)"
                   % (shadow[0], shadow[1],
                      haversine_km(HOME_LAT, HOME_LON, shadow[0], shadow[1]),
                      HOME_NAME, lag))
    else:
        first = time.strftime("%H:%M", time.gmtime(TRACK_EPOCHS[0]))
        last = time.strftime("%H:%M", time.gmtime(TRACK_EPOCHS[-1]))
        out.append("  umbra not on Earth (track runs %s - %s UTC); feed lag %.0fs"
                   % (first, last, lag))
        out.append("  %s closest approach: %s UTC at %d km"
                   % (HOME_NAME, HOME_CA_UTC, HOME_CA_KM))
    out.append("  spots seen %d   unparseable %d" % (tot["msgs"], tot["bad"]))
    out.append("-" * 78)
    out.append("%-6s | %-28s | %-28s" % ("", "spots/min", "median SNR dB"))
    out.append("%-6s | %s | %s" % (
        "band",
        " ".join("%8s" % z[:8] for z in ZONES),
        " ".join("%8s" % z[:8] for z in ZONES)))
    out.append("-" * 78)

    for band in bands:
        rates, meds = [], []
        any_data = False
        for z in ZONES:
            c = per.get((band, z))
            if c and c["n"]:
                any_data = True
                rates.append("%8.1f" % (c["n"] / nmin))
                m = median(c["s"])
                meds.append("%8.1f" % m if m is not None else "%8s" % "-")
            else:
                rates.append("%8s" % "-")
                meds.append("%8s" % "-")
        if any_data:
            out.append("%-6s | %s | %s" % (band, " ".join(rates), " ".join(meds)))

    out.append("=" * 78)
    out.append("corridor <800km  near 800-2000  penumbral 2000-4000  far = control")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window-min", type=int, default=20)
    ap.add_argument("--interval", type=int, default=15)
    ap.add_argument("--bands", default="160m,80m,60m,40m,30m,20m,17m,15m,12m,10m,6m")
    args = ap.parse_args()
    bands = [b.strip() for b in args.bands.split(",") if b.strip()]

    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                             client_id="pskr-watch-%d" % os.getpid())
    except AttributeError:
        client = mqtt.Client(client_id="pskr-watch-%d" % os.getpid())

    client.on_connect = lambda c, u, f, *a: c.subscribe(TOPIC, qos=0)
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=15)
    client.connect(HOST, PORT, keepalive=30)
    client.loop_start()

    try:
        while True:
            time.sleep(args.interval)
            sys.stdout.write("\033[H\033[J" + render(bands, args.window_min) + "\n")
            sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
