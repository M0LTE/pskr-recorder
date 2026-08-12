#!/usr/bin/env python3
"""
PSK Reporter full-feed MQTT collector.

Subscribes to the full (unsampled) pskreporter MQTT feed and appends every spot
to hourly-rotated gzipped NDJSON. Deliberately dumb: no parsing, no filtering,
no database. The only job is to not lose spots.

Each output line is the broker's payload byte-for-byte, with one extra key
"_rx" (local receive time, epoch seconds) spliced in before the closing brace.
The vendor's bytes are preserved exactly; the line stays valid JSON.

Configured entirely by environment:
  PSKR_TOPIC     MQTT topic filter          (default pskr/filter/v2/#)
  PSKR_HOST      broker host                (default mqtt.pskreporter.info)
  PSKR_PORT      broker port                (default 1883)
  PSKR_OUTDIR    output directory           (default /var/lib/pskr/data)
  PSKR_INSTANCE  instance tag, used in the client id and filenames (default a)
"""

import gzip
import json
import os
import queue
import signal
import sys
import threading
import time
import zlib

import paho.mqtt.client as mqtt

HOST = os.environ.get("PSKR_HOST", "mqtt.pskreporter.info")
PORT = int(os.environ.get("PSKR_PORT", "1883"))
TOPIC = os.environ.get("PSKR_TOPIC", "pskr/filter/v2/#")
OUTDIR = os.environ.get("PSKR_OUTDIR", "/var/lib/pskr/data")
INSTANCE = os.environ.get("PSKR_INSTANCE", "a")

# At ~600 spots/s this is about 5 minutes of slack between the network thread
# and the writer. It should never fill; if it does we drop and say so loudly
# rather than blocking the paho loop, which would stall the TCP read and get us
# disconnected by the broker.
QUEUE_MAX = 200_000

FLUSH_SECS = 5.0  # Z_SYNC_FLUSH cadence: bounds loss if we are hard-killed
STATS_SECS = 60.0

q: "queue.Queue[tuple[float, bytes]]" = queue.Queue(maxsize=QUEUE_MAX)
stop = threading.Event()

stats = {
    "received": 0,
    "written": 0,
    "dropped": 0,
    "connects": 0,
    "disconnects": 0,
    "started": time.time(),
}


def log(msg):
    """Plain ASCII to stderr; systemd puts it in the journal."""
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    sys.stderr.write("%s %s\n" % (ts, msg))
    sys.stderr.flush()


# ---------------------------------------------------------------- writer

def hour_key(t):
    return time.strftime("%Y%m%d-%H", time.gmtime(t))


def next_free_path(hk):
    """Never reuse a filename.

    A gzip member left truncated by a hard kill cannot be safely extended: if a
    new member is appended after it, zcat stops at the damaged block and
    everything written afterwards becomes unreachable. Opening in append mode
    therefore turns a 5-second loss into the loss of the rest of the hour.
    Verified the hard way with a SIGKILL test, so each run gets its own file and
    a truncated one is left alone to be read up to its last flush.

    Normal case stays tidy: spots-<hour>-<inst>.jsonl.gz. Only a restart within
    the same hour adds the .rN suffix.
    """
    base = os.path.join(OUTDIR, "spots-%s-%s" % (hk, INSTANCE))
    if not os.path.exists(base + ".jsonl.gz"):
        return base + ".jsonl.gz"
    n = 1
    while os.path.exists("%s.r%d.jsonl.gz" % (base, n)):
        n += 1
    return "%s.r%d.jsonl.gz" % (base, n)


def writer_thread():
    gz = None
    cur_hour = None
    path = None
    last_flush = time.time()
    last_stats = time.time()
    hour_count = 0

    def close_current():
        nonlocal gz, path, hour_count
        if gz is not None:
            gz.close()
            log("closed %s (%d spots)" % (os.path.basename(path), hour_count))
        gz = None
        hour_count = 0

    while not stop.is_set() or not q.empty():
        try:
            rx, payload = q.get(timeout=0.5)
        except queue.Empty:
            rx = None

        now = time.time()

        if rx is not None:
            hk = hour_key(rx)
            if hk != cur_hour:
                close_current()
                cur_hour = hk
                path = next_free_path(hk)
                gz = gzip.open(path, "wb", compresslevel=6)
                log("opened %s" % os.path.basename(path))

            p = payload.rstrip()
            if p.startswith(b"{") and p.endswith(b"}") and len(p) > 2:
                line = b"%s,\"_rx\":%.3f}\n" % (p[:-1], rx)
            else:
                # never seen in practice, but never drop a spot on the floor
                line = json.dumps(
                    {"_rx": round(rx, 3), "_raw": payload.decode("utf-8", "replace")}
                ).encode() + b"\n"

            gz.write(line)
            stats["written"] += 1
            hour_count += 1

        if gz is not None and now - last_flush >= FLUSH_SECS:
            # flush the deflate stream so everything so far is recoverable with
            # `gzip -dc` even if this process is killed without closing the file
            gz.flush(zlib.Z_SYNC_FLUSH)
            os.fsync(gz.fileno())
            last_flush = now

        if now - last_stats >= STATS_SECS:
            el = now - stats["started"]
            log(
                "stats inst=%s recv=%d written=%d dropped=%d qdepth=%d "
                "rate=%.1f/s conn=%d disc=%d uptime=%.0fs"
                % (
                    INSTANCE, stats["received"], stats["written"], stats["dropped"],
                    q.qsize(), stats["received"] / el if el else 0.0,
                    stats["connects"], stats["disconnects"], el,
                )
            )
            write_heartbeat()
            last_stats = now

    close_current()


def write_heartbeat():
    tmp = os.path.join(OUTDIR, ".status-%s.json.tmp" % INSTANCE)
    dst = os.path.join(OUTDIR, "status-%s.json" % INSTANCE)
    try:
        with open(tmp, "w") as f:
            json.dump(
                dict(stats, instance=INSTANCE, topic=TOPIC, now=time.time(),
                     qdepth=q.qsize()),
                f,
            )
        os.replace(tmp, dst)
    except OSError as e:
        log("heartbeat write failed: %s" % e)


# ---------------------------------------------------------------- mqtt

def on_connect(client, userdata, flags, *args):
    # paho 1.x passes (rc); paho 2.x passes (reason_code, properties)
    rc = args[0] if args else 0
    stats["connects"] += 1
    log("connected rc=%s, subscribing to %s" % (rc, TOPIC))
    client.subscribe(TOPIC, qos=0)


def on_disconnect(client, userdata, *args):
    stats["disconnects"] += 1
    log("disconnected (%s); paho will retry" % (args[0] if args else "?"))


def on_message(client, userdata, msg):
    stats["received"] += 1
    try:
        q.put_nowait((time.time(), msg.payload))
    except queue.Full:
        stats["dropped"] += 1
        if stats["dropped"] % 1000 == 1:
            log("QUEUE FULL, dropped=%d - writer cannot keep up" % stats["dropped"])


def main():
    os.makedirs(OUTDIR, exist_ok=True)

    client_id = "pskr-eclipse-%s-%d" % (INSTANCE, os.getpid())
    try:
        # paho 2.x
        client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2, client_id=client_id, clean_session=True
        )
    except AttributeError:
        # paho 1.x (Debian 12 ships 1.6.1)
        client = mqtt.Client(client_id=client_id, clean_session=True)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=15)
    # generous receive buffer; we are a firehose consumer
    client.max_queued_messages_set(0)

    w = threading.Thread(target=writer_thread, name="writer", daemon=False)
    w.start()

    def shutdown(signum, frame):
        log("signal %d, shutting down" % signum)
        stop.set()
        try:
            client.disconnect()
        except Exception:
            pass

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log("starting instance=%s host=%s:%d topic=%s outdir=%s"
        % (INSTANCE, HOST, PORT, TOPIC, OUTDIR))

    while not stop.is_set():
        try:
            client.connect(HOST, PORT, keepalive=30)
            client.loop_forever(retry_first_connection=True)
        except Exception as e:
            if stop.is_set():
                break
            log("loop error: %s; retrying in 3s" % e)
            time.sleep(3)

    stop.set()
    w.join(timeout=30)
    write_heartbeat()
    log("stopped; recv=%d written=%d dropped=%d"
        % (stats["received"], stats["written"], stats["dropped"]))


if __name__ == "__main__":
    main()
