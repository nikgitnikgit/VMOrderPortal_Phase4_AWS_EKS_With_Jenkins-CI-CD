"""Unit tests for the worker service.

AWS calls (SNS, SES) and the database are patched out, so the suite runs in CI
with no credentials and no network. What we are testing here is the request
handling contract: which payloads are accepted, which are rejected, and that a
failure in one notification channel does not take down the endpoint.
"""
import os
import sys
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(__file__))

import worker  # noqa: E402


@pytest.fixture
def client():
    worker.app.config['TESTING'] = True
    with worker.app.test_client() as c:
        yield c


def valid_payload(**overrides):
    payload = {
        'ticket_id': 'VM-ABCD1234',
        'machine_name': 'web-server-01',
        'os': 'ubuntu',
        'contact_name': 'Alice Cohen',
        'contact_email': 'alice@example.com',
        'environment': 'production',
        'region': 'us',
    }
    payload.update(overrides)
    return payload


# ------------------------------------------------------------------- health

def test_health_returns_ok(client):
    response = client.get('/health')
    assert response.status_code == 200
    assert response.get_json() == {'status': 'ok'}


# ------------------------------------------------------------------- notify

def test_notify_rejects_empty_body(client):
    assert client.post('/notify', json={}).status_code == 400


@pytest.mark.parametrize('missing_field', [
    'ticket_id', 'machine_name', 'os',
    'contact_name', 'contact_email', 'environment', 'region',
])
def test_notify_rejects_missing_required_field(client, missing_field):
    payload = valid_payload()
    del payload[missing_field]

    response = client.post('/notify', json=payload)

    assert response.status_code == 400
    assert missing_field in response.get_json()['error']


def test_notify_lists_every_missing_field_at_once(client):
    payload = valid_payload()
    del payload['ticket_id']
    del payload['contact_email']

    error = client.post('/notify', json=payload).get_json()['error']

    assert 'ticket_id' in error and 'contact_email' in error


@patch('worker.update_notification_sent', return_value=True)
@patch('worker.send_ses_confirmation', return_value=True)
@patch('worker.send_sns_notification', return_value=True)
def test_notify_accepts_valid_payload(mock_sns, mock_ses, mock_db, client):
    response = client.post('/notify', json=valid_payload())

    assert response.status_code == 200
    body = response.get_json()
    assert body['success'] is True
    assert body['ticket_id'] == 'VM-ABCD1234'
    mock_sns.assert_called_once()
    mock_ses.assert_called_once()


# REVIEW FIX 3.2 — the two tests below previously asserted the OPPOSITE.
# They were updated because the review identified the behaviour they pinned as
# the defect, not because they were in the way:
#   * "one channel failed but return success: true"  -> §5, losing channel state
#   * "write nothing when both channels fail"        -> §6.2, silent data loss
# Both now assert the corrected behaviour and would fail against the old code.

@patch('worker.update_notification_sent', return_value=True)
@patch('worker.send_ses_confirmation', return_value=True)
@patch('worker.send_sns_notification', return_value=False)
def test_notify_reports_partial_send_as_partial(mock_sns, mock_ses, mock_db, client):
    """A partial send is NOT a success.

    The request still returns 207 rather than 5xx — the notification was
    accepted and one channel did deliver, so the backend should not retry the
    whole order. But success=False stops the backend advancing the order to
    state=notified while the customer's confirmation email is missing.
    """
    resp = client.post('/notify', json=valid_payload())
    body = resp.get_json()

    assert resp.status_code == 207, "partial send must be distinguishable from full"
    assert body['success'] is False
    assert body['sns_sent'] is False
    assert body['ses_sent'] is True
    mock_db.assert_called_once()


@patch('worker.update_notification_sent', return_value=True)
@patch('worker.send_ses_confirmation', return_value=True)
@patch('worker.send_sns_notification', return_value=True)
def test_notify_reports_full_send_as_success(mock_sns, mock_ses, mock_db, client):
    resp = client.post('/notify', json=valid_payload())
    body = resp.get_json()

    assert resp.status_code == 200
    assert body['success'] is True
    assert body['sns_sent'] is True and body['ses_sent'] is True


@patch('worker.update_notification_sent', return_value=True)
@patch('worker.send_ses_confirmation', return_value=False)
@patch('worker.send_sns_notification', return_value=False)
def test_db_records_total_failure_rather_than_staying_silent(mock_sns, mock_ses, mock_db, client):
    """Both channels failing must still be WRITTEN.

    The old code skipped the update entirely, leaving the row at its default
    zeros — indistinguishable from an order the worker had never received.
    An operator could not tell "notification failed" from "never attempted".
    """
    resp = client.post('/notify', json=valid_payload())

    assert resp.status_code == 207
    assert resp.get_json()['success'] is False
    mock_db.assert_called_once_with('VM-ABCD1234', False, False)
