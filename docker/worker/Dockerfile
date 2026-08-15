# docker/worker/Dockerfile
# Build from the REPO ROOT:  docker build -f docker/worker/Dockerfile -t vm-order-worker:1.0.0 .
# Pinned base image — never "latest" (course requirement + reproducible builds)
FROM python:3.12-slim

WORKDIR /app

# Dependencies first — Docker caches this layer, so code changes
# do not trigger a full reinstall on every build
COPY --chmod=0644 app/worker/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code (unchanged from phase 2)
COPY --chmod=0644 app/worker/worker.py .
# REVIEW FIX 3.4 — gunicorn settings live in a config file rather than a
# long CMD line, because the backend needs an on_starting hook and both
# services benefit from the same documented reasoning.
COPY --chmod=0644 app/worker/gunicorn.conf.py .

# Run as a NON-root user (course requirement + container security)
RUN adduser --system --no-create-home --uid 10001 appuser
USER 10001

EXPOSE 5001

# worker.py binds 0.0.0.0:5001 and reads all config from environment
# variables — injected by Kubernetes from ConfigMap + Secret
# REVIEW FIX 3.4 — was: CMD ["python3", "worker.py"], i.e. Flask's development
# server. Werkzeug is single-threaded by default, prints a production
# warning into the pod log on every start, and is not built to face
# traffic. Gunicorn is a real WSGI server.
CMD ["gunicorn", "--config", "gunicorn.conf.py", "worker:app"]
