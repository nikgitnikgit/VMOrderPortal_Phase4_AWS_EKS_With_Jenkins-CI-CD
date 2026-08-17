# docker/backend/Dockerfile
# Build from the REPO ROOT:  docker build -f docker/backend/Dockerfile -t vm-order-backend:1.0.0 .
# Pinned base image — never "latest" (course requirement + reproducible builds)
FROM python:3.12-slim@sha256:2c941e860699f878900b0edc2403613c234d4b32eda3cc9fa7036991a2a63c4a

WORKDIR /app

# Dependencies first — Docker caches this layer, so code changes
# do not trigger a full reinstall on every build
COPY --chmod=0644 app/backend/requirements.txt .
# REVIEW FIX 4.3 — --require-hashes makes the build FAIL if any package
# lacks a hash or if the downloaded bytes do not match. pip already
# enters hash-checking mode when hashes are present, but stating it
# explicitly means a future edit that strips the hashes breaks the
# build loudly instead of quietly reverting to unverified installs.
RUN pip install --no-cache-dir --require-hashes -r requirements.txt

# Application code (unchanged from phase 2)
COPY --chmod=0644 app/backend/app.py .
# REVIEW FIX 3.4 — gunicorn settings live in a config file rather than a
# long CMD line, because the backend needs an on_starting hook and both
# services benefit from the same documented reasoning.
COPY --chmod=0644 app/backend/gunicorn.conf.py .

# Run as a NON-root user (course requirement + container security)
RUN adduser --system --no-create-home --uid 10001 appuser
USER 10001

EXPOSE 5000

# app.py binds 0.0.0.0:5000 and reads all config from environment
# variables — injected by Kubernetes from ConfigMap + Secret
# REVIEW FIX 3.4 — was: CMD ["python3", "app.py"], i.e. Flask's development
# server. Werkzeug is single-threaded by default, prints a production
# warning into the pod log on every start, and is not built to face
# traffic. Gunicorn is a real WSGI server.
CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:app"]
