"""Gunicorn configuration for the worker service.

REVIEW FIX 3.4 — see app/backend/gunicorn.conf.py for the reasoning. There is
no on_starting hook here: the worker owns no schema, it only reads and updates
rows the backend created.
"""
import os

bind = "0.0.0.0:5001"

# See app/backend/gunicorn.conf.py: readOnlyRootFilesystem plus an emptyDir at
# /tmp, and gunicorn kills workers whose heartbeat file cannot be written.
worker_tmp_dir = "/tmp"

# /notify calls SNS, then SES, then updates RDS — three blocking round trips.
# Threads keep a second notification from queueing behind the first.
worker_class = "gthread"
workers = int(os.environ.get("GUNICORN_WORKERS", "2"))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))

# The backend gives up on this service after 5s (requests.post timeout=5), so a
# long gunicorn timeout only holds a connection the caller has abandoned.
# 30s leaves room for a slow SES call while still bounding the worker.
timeout = 30
graceful_timeout = 30
keepalive = 65

accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")
access_log_format = '%(h)s "%(r)s" %(s)s %(b)s %(D)sus'
