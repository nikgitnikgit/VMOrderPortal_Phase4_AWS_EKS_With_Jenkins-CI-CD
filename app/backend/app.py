"""
app.py - Backend Flask API for VM Order Portal
Handles:
  - GET  /check-name     → check if machine name exists in RDS
  - POST /submit-order   → save order to RDS, upload JSON to S3, notify Worker
"""

import os
import json
import random
import string
import re
import html
import time
import threading
from datetime import datetime

import boto3
import psycopg2
import psycopg2.extras
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

# REVIEW FIX 2.5 — CORS removed entirely.
# `CORS(app)` allowed EVERY origin. It was a phase 2 leftover: back then the
# browser talked to the frontend EC2 box and called this API on a different
# host, so cross-origin headers were genuinely required.
# Under Kubernetes the browser only ever talks to nginx, which proxies /api/
# to this Service. Same origin, so the browser never sends an Origin header
# that needs answering and CORS is not needed at all.
# Removing it means a page on any other site can no longer read responses
# from this API using a visitor's browser.

# -----------------------------------------------------------------------
# Config — loaded from environment variables (set on EC2)
# -----------------------------------------------------------------------
DB_HOST     = os.environ.get("DB_HOST")       # RDS endpoint
DB_PORT     = int(os.environ.get("DB_PORT", "5432"))  # RDS port
DB_USER     = os.environ.get("DB_USER", "admin")
DB_PASSWORD = os.environ.get("DB_PASSWORD")
DB_NAME     = os.environ.get("DB_NAME", "vmorders")
S3_BUCKET   = os.environ.get("S3_BUCKET")     # e.g. vm-order-prod-s3-orders
AWS_REGION  = os.environ.get("AWS_REGION", "us-east-1")
WORKER_URL  = os.environ.get("WORKER_URL")    # e.g. http://<worker-ip>:5001/notify

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------


def get_db_connection():
    """Return a new psycopg2 connection to RDS PostgreSQL."""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        dbname=DB_NAME,
        cursor_factory=psycopg2.extras.RealDictCursor,
        connect_timeout=5
    )


def get_db_connection_no_db():
    """Return a psycopg2 connection without selecting a database (used for init)."""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        cursor_factory=psycopg2.extras.RealDictCursor,
        connect_timeout=5
    )


def init_db():
    """Create the vm_orders table if it doesn't exist."""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            # PostgreSQL creates DB at connection time — just create table
            cur.execute("""
                CREATE TABLE IF NOT EXISTS vm_orders (
                    order_id          SERIAL PRIMARY KEY,
                    ticket_id         VARCHAR(20)  NOT NULL,
                    machine_name      VARCHAR(30)  NOT NULL,
                    os                VARCHAR(50)  NOT NULL,
                    cpu               INT          NOT NULL,
                    ram               INT          NOT NULL,
                    storage           INT          NOT NULL,
                    region            VARCHAR(20)  NOT NULL,
                    environment       VARCHAR(20)  NOT NULL,
                    applications      TEXT,
                    contact_name      VARCHAR(50)  NOT NULL,
                    contact_email     VARCHAR(100) NOT NULL,
                    created_at        TIMESTAMP    DEFAULT NOW(),
                    notification_sent SMALLINT     DEFAULT 0
                );
            """)
        conn.commit()
        print("Database initialized successfully.")
    finally:
        conn.close()


def generate_ticket_id():
    """Generate a unique ticket ID like VM-T88ARN23."""
    chars = string.ascii_uppercase + string.digits
    suffix = ''.join(random.choices(chars, k=8))
    return f"VM-{suffix}"


def sanitize(value: str) -> str:
    """Sanitize input — escape HTML chars and strip whitespace."""
    if not isinstance(value, str):
        return str(value)
    return html.escape(value.strip())


def validate_order(data: dict) -> list:
    """Server-side validation — returns list of error messages."""
    errors = []

    name = data.get("machine_name", "")
    if not name or len(name) < 3 or len(name) > 30:
        errors.append("Machine name must be 3-30 characters.")
    if not re.match(r'^[a-zA-Z0-9-]+$', name):
        errors.append("Machine name can only contain letters, numbers and hyphens.")

    valid_os = {"ubuntu", "centos", "debian", "fedora", "amazon linux", "windows"}
    if data.get("os", "").lower() not in valid_os:
        errors.append("Invalid operating system.")

    try:
        cpu = int(data.get("cpu", 0))
        if not (1 <= cpu <= 64):
            errors.append("CPU must be between 1 and 64.")
    except (ValueError, TypeError):
        errors.append("Invalid CPU value.")

    try:
        ram = int(data.get("ram", 0))
        if not (1 <= ram <= 512):
            errors.append("RAM must be between 1 and 512 GB.")
    except (ValueError, TypeError):
        errors.append("Invalid RAM value.")

    valid_storage = {20, 50, 100, 200}
    try:
        storage = int(data.get("storage", 0))
        if storage not in valid_storage:
            errors.append("Invalid storage size.")
    except (ValueError, TypeError):
        errors.append("Invalid storage value.")

    valid_regions = {"us", "europe", "asia"}
    if data.get("region", "").lower() not in valid_regions:
        errors.append("Invalid region.")

    valid_envs = {"development", "testing", "production", "private usage"}
    if data.get("environment", "").lower() not in valid_envs:
        errors.append("Invalid environment.")

    contact_name = data.get("contact_name", "")
    if not contact_name or len(contact_name) < 2:
        errors.append("Contact name must be at least 2 characters.")
    if re.search(r'\d', contact_name):
        errors.append("Contact name cannot contain numbers.")

    email = data.get("contact_email", "")
    if not re.match(r'^[^\s@]+@[^\s@]+\.[^\s@]+$', email):
        errors.append("Invalid email address.")

    return errors


# -----------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------

@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    return jsonify({"status": "ok"}), 200


@app.route("/check-name", methods=["GET"])
def check_name():
    """
    Check if a machine name already exists in RDS.
    Query: GET /check-name?name=my-server
    Response: { "taken": true/false, "suggestions": ["my-server-1", ...] }
    """
    name = request.args.get("name", "").strip().lower()

    if not name or not re.match(r'^[a-zA-Z0-9-]+$', name):
        return jsonify({"taken": False}), 200

    try:
        conn = get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COUNT(*) as cnt FROM vm_orders WHERE LOWER(machine_name) = %s",
                    (name,)
                )
                row = cur.fetchone()
                taken = row["cnt"] > 0
        finally:
            conn.close()

        suggestions = []
        if taken:
            # Generate suggestions that are not taken
            candidates = [f"{name}-{i}" for i in range(1, 6)]
            candidates += [f"{name}-a", f"{name}-b", f"{name}-new"]
            for candidate in candidates:
                conn2 = get_db_connection()
                try:
                    with conn2.cursor() as cur:
                        cur.execute(
                            "SELECT COUNT(*) as cnt FROM vm_orders WHERE LOWER(machine_name) = %s",
                            (candidate,)
                        )
                        row = cur.fetchone()
                        if row["cnt"] == 0:
                            suggestions.append(candidate)
                finally:
                    conn2.close()
                if len(suggestions) == 3:
                    break

        return jsonify({"taken": taken, "suggestions": suggestions}), 200

    except Exception as e:
        print(f"Error checking name: {e}")
        return jsonify({"taken": False, "error": str(e)}), 500


@app.route("/submit-order", methods=["POST"])
def submit_order():
    """
    Receive VM order from Frontend.
    1. Validate input
    2. Save to RDS
    3. Upload JSON to S3
    4. Notify Worker
    Response: { "success": true, "ticket_id": "VM-XXXXXXXX" }
    """
    data = request.get_json()
    if not data:
        return jsonify({"success": False, "error": "No data received"}), 400

    # Sanitize all string inputs
    sanitized = {
        "machine_name":  sanitize(data.get("machine_name", "")),
        "os":            sanitize(data.get("os", "")),
        "cpu":           data.get("cpu", 0),
        "ram":           data.get("ram", 0),
        "storage":       data.get("storage", 0),
        "region":        sanitize(data.get("region", "")),
        "environment":   sanitize(data.get("environment", "")),
        "applications":  sanitize(data.get("applications", "")),
        "contact_name":  sanitize(data.get("contact_name", "")),
        "contact_email": sanitize(data.get("contact_email", "")),
    }

    # Server-side validation
    errors = validate_order(sanitized)
    if errors:
        return jsonify({"success": False, "errors": errors}), 400

    # Generate ticket ID
    ticket_id = generate_ticket_id()
    sanitized["ticket_id"] = ticket_id
    sanitized["created_at"] = datetime.now().isoformat()

    # 1. Save to RDS
    try:
        conn = get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO vm_orders
                    (ticket_id, machine_name, os, cpu, ram, storage,
                     region, environment, applications, contact_name, contact_email)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """, (
                    ticket_id,
                    sanitized["machine_name"],
                    sanitized["os"],
                    sanitized["cpu"],
                    sanitized["ram"],
                    sanitized["storage"],
                    sanitized["region"],
                    sanitized["environment"],
                    sanitized["applications"],
                    sanitized["contact_name"],
                    sanitized["contact_email"],
                ))
            conn.commit()
            print(f"Order {ticket_id} saved to RDS.")
        finally:
            conn.close()
    except Exception as e:
        print(f"RDS error: {e}")
        return jsonify({"success": False, "error": "Database error"}), 500

    # 2. Upload JSON to S3
    try:
        s3 = boto3.client("s3", region_name=AWS_REGION)
        s3_key = f"orders/{ticket_id}.json"
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=s3_key,
            Body=json.dumps(sanitized, indent=2),
            ContentType="application/json"
        )
        print(f"Order {ticket_id} uploaded to S3: {s3_key}")
    except Exception as e:
        print(f"S3 error: {e}")
        # Don't fail the whole order if S3 fails — just log it

    # 3. Notify Worker
    try:
        worker_payload = {
            "ticket_id":     ticket_id,
            "machine_name":  sanitized["machine_name"],
            "os":            sanitized["os"],
            "contact_name":  sanitized["contact_name"],
            "contact_email": sanitized["contact_email"],
            "environment":   sanitized["environment"],
            "region":        sanitized["region"],
        }
        response = requests.post(
            f"{WORKER_URL}/notify",
            json=worker_payload,
            timeout=5
        )
        print(f"Worker notified: {response.status_code}")
    except Exception as e:
        print(f"Worker notification error: {e}")
        # Don't fail the order if Worker is unreachable

    return jsonify({"success": True, "ticket_id": ticket_id}), 200


# -----------------------------------------------------------------------
# Health checks
# -----------------------------------------------------------------------

def check_worker_health():
    """Background thread — checks Worker health every 60 seconds."""
    while True:
        try:
            r = requests.get(
                f"{WORKER_URL.replace('/notify', '')}/health",
                timeout=3
            )
            if r.status_code == 200:
                print("[Health] Worker: OK")
            else:
                print(f"[Health] Worker: DEGRADED (status {r.status_code})")
        except Exception as e:
            print(f"[Health] Worker: UNREACHABLE ⚠️ ({e})")
        time.sleep(60)


@app.route("/health/full", methods=["GET"])
def health_full():
    """
    Full system health check.
    Checks: Backend itself, Worker, RDS connection.
    """
    status = {
        "backend": "ok",
        "worker": "unknown",
        "rds": "unknown"
    }

    # Check Worker
    try:
        r = requests.get(
            f"{WORKER_URL.replace('/notify', '')}/health",
            timeout=3
        )
        status["worker"] = "ok" if r.status_code == 200 else "degraded"
    except Exception as e:
        status["worker"] = f"unreachable: {str(e)}"

    # Check RDS
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        conn.close()
        status["rds"] = "ok"
    except Exception as e:
        status["rds"] = f"unreachable: {str(e)}"

    overall = "ok" if all(v == "ok" for v in status.values()) else "degraded"
    status["overall"] = overall

    return jsonify(status), 200 if overall == "ok" else 503


# -----------------------------------------------------------------------
# Startup
# -----------------------------------------------------------------------

if __name__ == "__main__":
    print("Initializing database...")
    init_db()

    # Start Worker health check background thread
    print("Starting Worker health check thread (every 60 seconds)...")
    health_thread = threading.Thread(target=check_worker_health, daemon=True)
    health_thread.start()

    print("Starting Backend API on port 5000...")
    app.run(host="0.0.0.0", port=5000, debug=False)
