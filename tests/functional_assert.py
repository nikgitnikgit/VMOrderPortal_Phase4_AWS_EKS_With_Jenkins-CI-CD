import requests, boto3, json, psycopg2, sys, time
s3 = boto3.client("s3"); sns = boto3.client("sns"); sqs = boto3.client("sqs"); ses = boto3.client("ses")
try: s3.create_bucket(Bucket="vm-order-func-test")
except Exception: pass
topic = sns.create_topic(Name="vm-order-func-sns")["TopicArn"]
q = sqs.create_queue(QueueName="probe")["QueueUrl"]
qarn = sqs.get_queue_attributes(QueueUrl=q, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
sns.subscribe(TopicArn=topic, Protocol="sqs", Endpoint=qarn)
try: ses.verify_email_identity(EmailAddress="func-test@example.com")
except Exception: pass
sqs.purge_queue(QueueUrl=q)
base = ses.get_send_quota()["SentLast24Hours"]

order = {"machine_name":"qa-func-vm","os":"ubuntu","cpu":2,"ram":8,"storage":50,
         "region":"us","environment":"development","applications":"nginx",
         "contact_name":"QA Tester","contact_email":"qa@test.com"}
r = requests.post("http://127.0.0.1:8080/api/submit-order", json=order, timeout=20)
body = r.json(); assert body.get("success"), body
ticket = body["ticket_id"]; time.sleep(2)

conn = psycopg2.connect(host="127.0.0.1", user="vmadmin", password="testpass123", dbname="vmorders")
cur = conn.cursor(); cur.execute("SELECT notification_sent FROM vm_orders WHERE ticket_id=%s",(ticket,))
row = cur.fetchone(); assert row and row[0]==1, f"db/flag: {row}"

keys = [o["Key"] for o in s3.list_objects_v2(Bucket="vm-order-func-test").get("Contents",[])]
assert any(ticket in k for k in keys), keys

msgs = sqs.receive_message(QueueUrl=q, MaxNumberOfMessages=10, WaitTimeSeconds=3).get("Messages",[])
assert any(ticket in json.loads(m["Body"]).get("Message","") for m in msgs), "sns"
assert ses.get_send_quota()["SentLast24Hours"] > base, "ses"
print(f"functional chain OK (ticket {ticket}): nginx->backend->[DB+S3]->worker->[SNS+SES]->flag")
