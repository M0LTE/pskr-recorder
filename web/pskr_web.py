#!/usr/bin/env python3
"""
Public web view of the PSK Reporter eclipse feed.

Like pskr_watch, this is strictly read-only and completely independent of the
collectors: its own MQTT subscription, everything in memory, nothing written to
the capture directory. If it dies the capture is untouched.

Serves a small JSON API and a single static page:

  GET /                     the page
  GET /api/state            header, current per-band table, map grid   (poll ~5s)
  GET /api/series?band=40m  per-zone time series for one band          (poll ~20s)

Environment:
  PSKR_WEB_PORT   listen port           (default 8080)
  PSKR_WEB_BIND   bind address          (default 0.0.0.0)
  PSKR_HOME_NAME/LAT/LON                observer, for the "distance from" readout
"""

import bisect
import csv
import gzip
import json
import math
import os
import sys
import threading
import time
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

import paho.mqtt.client as mqtt

HOST = os.environ.get("PSKR_HOST", "mqtt.pskreporter.info")
PORT = int(os.environ.get("PSKR_PORT", "1883"))
TOPIC = os.environ.get("PSKR_TOPIC", "pskr/filter/v2/#")
TRACK_CSV = os.environ.get("PSKR_TRACK", "/opt/pskr/analysis/eclipse_track.csv")
STATIC_DIR = os.environ.get("PSKR_STATIC", "/opt/pskr/web")

WEB_PORT = int(os.environ.get("PSKR_WEB_PORT", "8080"))
WEB_BIND = os.environ.get("PSKR_WEB_BIND", "0.0.0.0")

HOME_NAME = os.environ.get("PSKR_HOME_NAME", "Reading UK")
HOME_LAT = float(os.environ.get("PSKR_HOME_LAT", "51.4543"))
HOME_LON = float(os.environ.get("PSKR_HOME_LON", "-0.9781"))

BANDS = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m",
         "12m", "10m", "6m", "4m", "2m", "70cm"]
BAND_SET = set(BANDS)
ZONES = ["corridor", "near", "penumbral", "far"]

MIN_FOR_MEDIAN = 5     # a median over 1-2 reports is noise, not a measurement
INCOMPLETE_TAIL_S = 180  # the newest minutes are still filling in; see the late-report tail

# Reports for a given transmission minute keep arriving for up to ~45 minutes.
# So for any minute that had already passed when this process started, we only
# ever saw the stragglers, never the bulk. Plotting those produces a fake
# exponential ramp that is really just "how long have we been listening".
# A minute is only trustworthy if we were already running when it began.
SERVICE_START_MIN = int(time.time()) // 60 * 60 + 60

HISTORY_MIN = 360          # 6 hours of per-minute aggregate
MAP_WINDOW_MIN = 10        # map shows this much recent activity
MAP_CELL_DEG = 2.0

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


def haversine_km(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0088 * 2 * math.asin(math.sqrt(a))


def maidenhead(g):
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
    key = (round(lat), round(lon))
    d = _cell_cache.get(key)
    if d is None:
        d = min(haversine_km(key[0], key[1], p[1], p[2]) for p in TRACK)
        _cell_cache[key] = d
    return d


def shadow_at(epoch):
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


_ca = min(TRACK, key=lambda p: haversine_km(HOME_LAT, HOME_LON, p[1], p[2]))
HOME_CA_EPOCH = _ca[0]
HOME_CA_KM = round(haversine_km(HOME_LAT, HOME_LON, _ca[1], _ca[2]))

# ------------------------------------------------------------------ state

lock = threading.Lock()

# (minute, band, zone) -> {"n": int, "h": {snr: count}}
cells = defaultdict(lambda: {"n": 0, "h": defaultdict(int)})
# minute -> {(latbin, lonbin): count}
mapgrid = defaultdict(lambda: defaultdict(int))

totals = {"msgs": 0, "bad": 0, "started": time.time(),
          "connects": 0, "disconnects": 0}
lag_recent = deque(maxlen=2000)
rate_recent = deque(maxlen=600)   # (second, count)


def hist_median(h):
    n = sum(h.values())
    if not n:
        return None
    half = n / 2.0
    c = 0
    for k in sorted(h):
        c += h[k]
        if c >= half:
            return k
    return None


def on_connect(client, userdata, flags, *args):
    with lock:
        totals["connects"] += 1
    client.subscribe(TOPIC, qos=0)


def on_disconnect(client, userdata, *args):
    with lock:
        totals["disconnects"] += 1


def on_message(client, userdata, msg):
    try:
        d = json.loads(msg.payload)
    except Exception:
        with lock:
            totals["bad"] += 1
        return

    a = maidenhead(d.get("sl"))
    b = maidenhead(d.get("rl"))
    now = time.time()

    with lock:
        totals["msgs"] += 1
        t = d.get("t")
        if t:
            lag_recent.append(now - t)
        sec = int(now)
        if rate_recent and rate_recent[-1][0] == sec:
            rate_recent[-1][1] += 1
        else:
            rate_recent.append([sec, 1])

        if not a or not b:
            return

        mlat, mlon = gc_midpoint(a[0], a[1], b[0], b[1])
        z = zone_of(dist_to_track(mlat, mlon))
        minute = int(d.get("t_tx") or t or now) // 60 * 60
        band = d.get("b", "?")

        c = cells[(minute, band, z)]
        c["n"] += 1
        rp = d.get("rp")
        if isinstance(rp, int) and not isinstance(rp, bool) and -60 <= rp <= 60:
            c["h"][rp] += 1

        latb = int(math.floor(mlat / MAP_CELL_DEG))
        lonb = int(math.floor(mlon / MAP_CELL_DEG))
        mapgrid[int(now) // 60 * 60][(latb, lonb)] += 1


def prune():
    """Drop aggregate older than the retention window."""
    cutoff = time.time() - HISTORY_MIN * 60
    with lock:
        for k in [k for k in cells if k[0] < cutoff]:
            del cells[k]
        for m in [m for m in mapgrid if m < time.time() - MAP_WINDOW_MIN * 60 - 120]:
            del mapgrid[m]


def build_state():
    now = time.time()
    with lock:
        lag = sorted(lag_recent)[len(lag_recent) // 2] if lag_recent else 0.0
        rate = sum(c for s, c in rate_recent if s >= int(now) - 60) / 60.0
        msgs, bad = totals["msgs"], totals["bad"]
        conn, disc = totals["connects"], totals["disconnects"]

        # Ten *complete* minutes, ending before the still-filling tail. Including
        # the newest minutes would depress every rate in the table and make it
        # disagree with the chart, which already excludes them.
        until = (int(now) - INCOMPLETE_TAIL_S) // 60 * 60
        since = until - 10 * 60
        table = {}
        for (minute, band, z), c in cells.items():
            if (minute < since or minute > until or band not in BAND_SET
                    or minute < SERVICE_START_MIN):
                continue
            e = table.setdefault(band, {})
            zz = e.setdefault(z, {"n": 0, "h": defaultdict(int)})
            zz["n"] += c["n"]
            for k, v in c["h"].items():
                zz["h"][k] += v

        mstart = (int(now) // 60 * 60) - MAP_WINDOW_MIN * 60
        grid = defaultdict(int)
        for m, g in mapgrid.items():
            if m >= mstart:
                for k, v in g.items():
                    grid[k] += v

    bands_out = []
    for band in BANDS:
        e = table.get(band)
        if not e:
            continue
        row = {"band": band, "zones": {}}
        for z in ZONES:
            zz = e.get(z)
            if zz and zz["n"]:
                row["zones"][z] = {"rate": round(zz["n"] / 10.0, 1),
                                   "snr": hist_median(zz["h"]),
                                   "n": zz["n"]}
        if row["zones"]:
            bands_out.append(row)

    sh = shadow_at(now - lag)
    return {
        "now": now,
        "feed_lag_s": round(lag, 1),
        "rate_per_s": round(rate, 1),
        "spots_seen": msgs,
        "unparseable": bad,
        "connects": conn,
        "disconnects": disc,
        "uptime_s": round(now - totals["started"]),
        "collecting_since": SERVICE_START_MIN,
        "eclipse": {
            "umbra": {"lat": round(sh[0], 2), "lon": round(sh[1], 2),
                      "km_from_home": round(haversine_km(HOME_LAT, HOME_LON, sh[0], sh[1]))}
            if sh else None,
            "track_start": TRACK_EPOCHS[0],
            "track_end": TRACK_EPOCHS[-1],
            "home": {"name": HOME_NAME, "lat": HOME_LAT, "lon": HOME_LON,
                     "closest_epoch": HOME_CA_EPOCH, "closest_km": HOME_CA_KM},
        },
        "bands": bands_out,
        "grid": [[k[0] * MAP_CELL_DEG + MAP_CELL_DEG / 2,
                  k[1] * MAP_CELL_DEG + MAP_CELL_DEG / 2, v]
                 for k, v in grid.items()],
        "grid_cell_deg": MAP_CELL_DEG,
        "grid_window_min": MAP_WINDOW_MIN,
        "track": [[p[0], p[1], p[2]] for p in TRACK],
        "zones": ZONES,
    }


def build_series(band):
    now = int(time.time()) // 60 * 60
    start = now - HISTORY_MIN * 60
    # Reports arrive up to tens of minutes late, so the most recent minutes are
    # always partial. Plotting them produces a fake cliff at the right edge.
    cutoff = int(time.time()) - INCOMPLETE_TAIL_S

    with lock:
        acc = defaultdict(lambda: {"n": 0, "h": defaultdict(int)})
        for (minute, b, z), c in cells.items():
            if (b != band or minute < start or minute > cutoff
                    or minute < SERVICE_START_MIN):
                continue
            e = acc[(minute, z)]
            e["n"] += c["n"]
            for k, v in c["h"].items():
                e["h"][k] += v

    out = {z: [] for z in ZONES}
    for (minute, z), e in sorted(acc.items()):
        med = hist_median(e["h"]) if sum(e["h"].values()) >= MIN_FOR_MEDIAN else None
        out[z].append([minute, e["n"], med])
    return {"band": band, "series": out, "zones": ZONES,
            "min_for_median": MIN_FOR_MEDIAN, "complete_to": cutoff,
            "collecting_since": SERVICE_START_MIN}


# ------------------------------------------------------------------ http

class Handler(BaseHTTPRequestHandler):
    server_version = "pskr-eclipse"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass  # keep the journal for the collectors, not access logs

    def _send(self, code, body, ctype, cache="no-store", gz=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if gz:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, cache="no-store"):
        raw = json.dumps(obj, separators=(",", ":")).encode()
        if "gzip" in self.headers.get("Accept-Encoding", ""):
            self._send(200, gzip.compress(raw, 5), "application/json",
                       cache=cache, gz=True)
        else:
            self._send(200, raw, "application/json", cache=cache)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path, _, query = self.path.partition("?")
        try:
            if path == "/" or path == "/index.html":
                with open(os.path.join(STATIC_DIR, "index.html"), "rb") as f:
                    body = f.read()
                self._send(200, body, "text/html; charset=utf-8", cache="no-cache")
            elif path == "/api/state":
                # A few seconds of shared caching: the underlying aggregate only
                # changes once a minute, and every viewer polling this at 5s
                # otherwise lands on the origin.
                self._json(build_state(), cache="public, max-age=3")
            elif path == "/api/series":
                q = parse_qs(query or "")
                band = q.get("band", ["40m"])[0]
                # band never reaches the filesystem, but reject rather than
                # silently serving a different band than was asked for
                if band not in BAND_SET:
                    self._send(400, b'{"error":"unknown band"}', "application/json")
                    return
                self._json(build_series(band), cache="public, max-age=10")
            elif path == "/healthz":
                self._send(200, b"ok\n", "text/plain")
            else:
                self._send(404, b"not found\n", "text/plain")
        except BrokenPipeError:
            pass
        except Exception as e:
            sys.stderr.write("request error: %s\n" % e)
            try:
                self._send(500, b'{"error":"internal"}', "application/json")
            except Exception:
                pass


def pruner():
    while True:
        time.sleep(60)
        try:
            prune()
        except Exception as e:
            sys.stderr.write("prune error: %s\n" % e)


def main():
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                             client_id="pskr-web-%d" % os.getpid())
    except AttributeError:
        client = mqtt.Client(client_id="pskr-web-%d" % os.getpid())

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=15)
    client.connect(HOST, PORT, keepalive=30)
    client.loop_start()

    threading.Thread(target=pruner, daemon=True).start()

    srv = ThreadingHTTPServer((WEB_BIND, WEB_PORT), Handler)
    srv.daemon_threads = True
    sys.stderr.write("listening on %s:%d, feed %s:%d %s\n"
                     % (WEB_BIND, WEB_PORT, HOST, PORT, TOPIC))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
