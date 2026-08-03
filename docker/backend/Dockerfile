# docker/backend/Dockerfile
# Build from the REPO ROOT:  docker build -f docker/backend/Dockerfile -t vm-order-backend:1.0.0 .
# Pinned base image — never "latest" (course requirement + reproducible builds)
FROM python:3.12-slim

WORKDIR /app

# Dependencies first — Docker caches this layer, so code changes
# do not trigger a full reinstall on every build
COPY --chmod=0644 app/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code (unchanged from phase 2)
COPY --chmod=0644 app/backend/app.py .

# Run as a NON-root user (course requirement + container security)
RUN adduser --system --no-create-home --uid 10001 appuser
USER 10001

EXPOSE 5000

# app.py binds 0.0.0.0:5000 and reads all config from environment
# variables — injected by Kubernetes from ConfigMap + Secret
CMD ["python3", "app.py"]
