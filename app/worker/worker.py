"""
worker.py - Worker service for VM Order Portal
Handles:
  - POST /notify → receives order details from Backend
                 → sends SNS notification to DevOps team
                 → sends SES confirmation email to customer
                 → updates notification_sent in RDS
"""

import os
import re
import psycopg2
import psycopg2.extras
import boto3
from flask import Flask, request, jsonify
from botocore.exceptions import ClientError

app = Flask(__name__)

# -----------------------------------------------------------------------
# Config — loaded from environment variables (set on EC2)
# -----------------------------------------------------------------------
DB_HOST         = os.environ.get("DB_HOST")
DB_USER         = os.environ.get("DB_USER", "vmadmin")
DB_PASSWORD     = os.environ.get("DB_PASSWORD")
DB_NAME         = os.environ.get("DB_NAME", "vmorders")
AWS_REGION      = os.environ.get("AWS_REGION", "us-east-1")
SNS_TOPIC_ARN   = os.environ.get("SNS_TOPIC_ARN")   # vm-order-prod-sns ARN
SES_SENDER      = os.environ.get("SES_SENDER")       # verified email in SES

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

def get_db_connection():
    """Return a new psycopg2 connection to RDS."""
    return psycopg2.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        dbname=DB_NAME,
        cursor_factory=psycopg2.extras.RealDictCursor,
        connect_timeout=5
    )


def send_sns_notification(order: dict) -> bool:
    """Send SNS notification to DevOps team."""
    try:
        sns = boto3.client("sns", region_name=AWS_REGION)
        message = f"""
New VM Order Received!

Ticket ID:    {order['ticket_id']}
Machine Name: {order['machine_name']}
OS:           {order['os']}
Region:       {order['region']}
Environment:  {order['environment']}
Contact:      {order['contact_name']} ({order['contact_email']})

Please provision this machine within 24 hours.
        """.strip()

        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"New VM Order: {order['ticket_id']}",
            Message=message
        )
        print(f"SNS notification sent for {order['ticket_id']}")
        return True
    except ClientError as e:
        print(f"SNS error: {e}")
        return False


def send_ses_confirmation(order: dict) -> bool:
    """Send SES confirmation email to customer."""
    try:
        ses = boto3.client("ses", region_name=AWS_REGION)

        # Plain text version
        text_body = f"""
Hello {order['contact_name']},

Thank you for your VM order! Here are your order details:

Ticket ID:    {order['ticket_id']}
Machine Name: {order['machine_name']}
OS:           {order['os']}
Region:       {order['region']}
Environment:  {order['environment']}

Your server will be provisioned within 24 hours.
Please keep your ticket ID for reference.

Best regards,
VM Order Portal Team
        """.strip()

        # HTML version
        html_body = f"""
<!DOCTYPE html>
<html>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <div style="background: #0e0f11; padding: 30px; border-radius: 12px; color: #f0f0f0;">
        <h1 style="color: #00e5a0; margin-bottom: 5px;">&#x2699; VM Order Portal</h1>
        <h2 style="color: #f0f0f0; margin-top: 0;">Order Confirmed!</h2>
        <p style="color: #9aa0b0;">Hello <strong style="color: #f0f0f0;">{order['contact_name']}</strong>,<br>
        Thank you for your VM order. Here are your details:</p>

        <div style="background: #16181c; border-radius: 8px; padding: 20px; margin: 20px 0;">
            <div style="text-align: center; margin-bottom: 20px;">
                <span style="background: rgba(0,229,160,0.1); color: #00e5a0;
                             font-family: monospace; font-size: 18px;
                             padding: 10px 20px; border-radius: 8px;">
                    Ticket: {order['ticket_id']}
                </span>
            </div>
            <table style="width: 100%; border-collapse: collapse;">
                <tr style="border-bottom: 1px solid #1e2026;">
                    <td style="padding: 10px; color: #9aa0b0;">Machine Name</td>
                    <td style="padding: 10px; color: #f0f0f0; font-weight: bold;">{order['machine_name']}</td>
                </tr>
                <tr style="border-bottom: 1px solid #1e2026;">
                    <td style="padding: 10px; color: #9aa0b0;">Operating System</td>
                    <td style="padding: 10px; color: #f0f0f0;">{order['os']}</td>
                </tr>
                <tr style="border-bottom: 1px solid #1e2026;">
                    <td style="padding: 10px; color: #9aa0b0;">Region</td>
                    <td style="padding: 10px; color: #f0f0f0;">{order['region']}</td>
                </tr>
                <tr>
                    <td style="padding: 10px; color: #9aa0b0;">Environment</td>
                    <td style="padding: 10px; color: #f0f0f0;">{order['environment']}</td>
                </tr>
            </table>
        </div>

        <p style="color: #9aa0b0;">Your server will be provisioned within <strong style="color: #00e5a0;">24 hours</strong>.<br>
        Please keep your ticket ID for reference.</p>

        <p style="color: #5a6070; font-size: 12px; margin-top: 30px;">
            VM Order Portal &mdash; Automated Notification
        </p>
    </div>
</body>
</html>
        """.strip()

        ses.send_email(
            Source=SES_SENDER,
            Destination={"ToAddresses": [order["contact_email"]]},
            Message={
                "Subject": {"Data": f"Your VM Order Confirmation - {order['ticket_id']}"},
                "Body": {
                    "Text": {"Data": text_body},
                    "Html": {"Data": html_body}
                }
            }
        )
        print(f"SES confirmation sent to {order['contact_email']} for {order['ticket_id']}")
        return True
    except ClientError as e:
        print(f"SES error: {e}")
        return False


def update_notification_sent(ticket_id: str) -> bool:
    """Update notification_sent = 1 in RDS after emails are sent."""
    try:
        conn = get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE vm_orders SET notification_sent = 1 WHERE ticket_id = %s",
                    (ticket_id,)
                )
            conn.commit()
            print(f"RDS updated: notification_sent = 1 for {ticket_id}")
            return True
        finally:
            conn.close()
    except Exception as e:
        print(f"RDS update error: {e}")
        return False


# -----------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------

@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    return jsonify({"status": "ok"}), 200


@app.route("/notify", methods=["POST"])
def notify():
    """
    Receive order notification from Backend.
    1. Send SNS notification to DevOps team
    2. Send SES confirmation email to customer
    3. Update notification_sent in RDS
    """
    data = request.get_json()
    if not data:
        return jsonify({"success": False, "error": "No data received"}), 400

    # Validate required fields
    required = ["ticket_id", "machine_name", "os",
                "contact_name", "contact_email", "environment", "region"]
    missing = [f for f in required if not data.get(f)]
    if missing:
        return jsonify({
            "success": False,
            "error": f"Missing fields: {', '.join(missing)}"
        }), 400

    ticket_id = data["ticket_id"]
    print(f"Processing notification for {ticket_id}...")

    # Track results
    sns_sent = False
    ses_sent = False

    # 1. Send SNS to DevOps team
    sns_sent = send_sns_notification(data)

    # 2. Send SES confirmation to customer
    ses_sent = send_ses_confirmation(data)

    # 3. Update RDS if at least one notification was sent
    if sns_sent or ses_sent:
        update_notification_sent(ticket_id)

    return jsonify({
        "success": True,
        "ticket_id": ticket_id,
        "sns_sent": sns_sent,
        "ses_sent": ses_sent
    }), 200


# -----------------------------------------------------------------------
# Startup
# -----------------------------------------------------------------------

if __name__ == "__main__":
    print("Starting Worker service on port 5001...")
    app.run(host="0.0.0.0", port=5001, debug=False)
