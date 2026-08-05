#!/bin/bash
# Functional end-to-end test: runs the REAL app code (backend, worker, nginx
# with the chart env contract) against local PostgreSQL + moto mock AWS,
# pushes a real order through and verifies every hop.
# Requires: postgresql, nginx, python3-venv, internet for pip. Skips if absent.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v psql >/dev/null || ! command -v nginx >/dev/null; then
    echo "SKIPPED (needs postgresql + nginx installed)"
    exit 0
fi

VENV=/tmp/qa_func_venv
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -r "$REPO/app/backend/requirements.txt" -r "$REPO/app/worker/requirements.txt" "moto[server]==5.0.28" requests

pg_ctlcluster 16 main start 2>/dev/null || service postgresql start 2>/dev/null || true
su postgres -c "psql -c \"CREATE USER vmadmin WITH PASSWORD 'testpass123';\"" 2>/dev/null || true
su postgres -c "psql -c \"CREATE DATABASE vmorders OWNER vmadmin;\"" 2>/dev/null || true

curl -s -m 2 http://127.0.0.1:5566/moto-api/data.json >/dev/null 2>&1 || \
  { setsid "$VENV/bin/moto_server" -p 5566 </dev/null >/tmp/qa_moto.log 2>&1 & sleep 3; }

fuser -k 5000/tcp 5001/tcp 8080/tcp 2>/dev/null || true; sleep 1
# An array, not a string: `env "${COMMON[@]}"` passes each KEY=VALUE as one
# argument, so a value containing a space could never split into two.
COMMON=(
  AWS_ENDPOINT_URL=http://127.0.0.1:5566
  AWS_ACCESS_KEY_ID=test
  AWS_SECRET_ACCESS_KEY=test
  AWS_REGION=us-east-1
  DB_HOST=127.0.0.1
  DB_PORT=5432
  DB_USER=vmadmin
  DB_PASSWORD=testpass123
  DB_NAME=vmorders
  PYTHONDONTWRITEBYTECODE=1
)
env "${COMMON[@]}" SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:vm-order-func-sns SES_SENDER=func-test@example.com \
  setsid "$VENV/bin/python" "$REPO/app/worker/worker.py" </dev/null >/tmp/qa_worker.log 2>&1 &
env "${COMMON[@]}" S3_BUCKET=vm-order-func-test WORKER_URL=http://127.0.0.1:5001 \
  setsid "$VENV/bin/python" "$REPO/app/backend/app.py" </dev/null >/tmp/qa_backend.log 2>&1 &
sleep 5

grep -q "127.0.0.1 backend" /etc/hosts 2>/dev/null || echo "127.0.0.1 backend" >> /etc/hosts
mkdir -p /tmp/qa_ngx && cp "$REPO/docker/frontend/nginx.conf" /tmp/qa_ngx/default.conf
cp "$REPO/app/index.html" /usr/share/nginx/html/index.html 2>/dev/null || true
printf "pid /tmp/qa_ngx/nginx.pid;\nerror_log /tmp/qa_ngx/error.log;\nevents {}\nhttp { access_log off; include /etc/nginx/mime.types; include /tmp/qa_ngx/default.conf; }\n" > /tmp/qa_ngx/main.conf
nginx -c /tmp/qa_ngx/main.conf 2>/dev/null || nginx -s reload 2>/dev/null || true
sleep 1

AWS_ENDPOINT_URL=http://127.0.0.1:5566 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
  "$VENV/bin/python" "$REPO/tests/functional_assert.py"
