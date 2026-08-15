"""Gunicorn configuration for the backend API.

REVIEW FIX 3.4 — replaces Flask's development server (app.run), which is
single-threaded, prints a production warning into the pod log on every start,
and is explicitly not intended to face traffic.

The reason this file exists rather than a longer CMD line: init_db() used to
run inside app.py's `if __name__ == "__main__"` block. Gunicorn IMPORTS the
module instead of executing it, so that block never runs and the table would
never be created. on_starting() below runs in the MASTER process before any
worker forks, so the schema is created exactly once per pod regardless of the
worker count.
"""
import os
import sys
import time

bind = "0.0.0.0:5000"

# The container runs with readOnlyRootFilesystem: true and an emptyDir mounted
# at /tmp. Gunicorn writes a heartbeat file per worker and the arbiter kills
# any worker whose file goes stale — on a read-only filesystem every worker
# would look hung and be killed in a loop. The default already resolves to
# /tmp, but TMPDIR could change that, so pin it to the volume we know exists.
worker_tmp_dir = "/tmp"

# gthread, not the default sync worker: /submit-order blocks on RDS, then on
# S3, then on an HTTP call to the worker. Sync workers would each sit idle
# through all of that, and 2 concurrent orders would queue behind each other.
worker_class = "gthread"
workers = int(os.environ.get("GUNICORN_WORKERS", "2"))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))

# Must be >= nginx's proxy_read_timeout (60s) or gunicorn kills the worker
# while nginx is still waiting, and the client sees a bare 502 instead of a
# useful error.
timeout = 60
graceful_timeout = 30

# Slightly above the ALB's 60s idle timeout so the ALB, not gunicorn, closes
# idle connections. The other way round produces sporadic 502s on reused
# connections.
keepalive = 65

# Logs to stdout/stderr so `kubectl logs` sees them. There is no log file in a
# container: the collector reads the stream.
accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")
# %(D)s is request time in microseconds — useful when the reviewer asks which
# hop is slow.
access_log_format = '%(h)s "%(r)s" %(s)s %(b)s %(D)sus'


def on_starting(server):
    """Create the schema once, in the master, before any worker forks."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from app import init_db

    # RDS can still be accepting-but-not-ready when the pod starts, and a bare
    # failure here would CrashLoopBackOff with an opaque message. Retry a few
    # times, then fail loudly — a pod that cannot reach its database SHOULD
    # die so Kubernetes restarts it, rather than serving 500s forever.
    last = None
    for attempt in range(1, 6):
        try:
            init_db()
            server.log.info("schema ready (attempt %d)", attempt)
            return
        except Exception as exc:              # noqa: BLE001 - reported below
            last = exc
            server.log.warning(
                "database not ready (attempt %d/5): %s", attempt, exc
            )
            time.sleep(3)
    server.log.error("giving up on database init: %s", last)
    raise SystemExit(1)
