"""Unit tests for the backend validation and helper functions.

These deliberately test only the pure functions and the /health route, so the
suite runs in CI with no database, no S3 and no network. Anything requiring
RDS belongs in an integration test, not here.
"""
import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))

import app as backend  # noqa: E402


# ---------------------------------------------------------------- sanitize

def test_sanitize_escapes_html():
    assert backend.sanitize('<script>alert(1)</script>') == \
        '&lt;script&gt;alert(1)&lt;/script&gt;'


def test_sanitize_strips_whitespace():
    assert backend.sanitize('  web-01  ') == 'web-01'


def test_sanitize_coerces_non_strings():
    assert backend.sanitize(42) == '42'


# ------------------------------------------------------- generate_ticket_id

def test_ticket_id_format():
    assert re.match(r'^VM-[A-Z0-9]{8}$', backend.generate_ticket_id())


def test_ticket_ids_are_unique():
    ids = {backend.generate_ticket_id() for _ in range(200)}
    assert len(ids) > 190, 'ticket IDs collide far too often'


# ---------------------------------------------------------- validate_order

def valid_order(**overrides):
    order = {
        'machine_name': 'web-server-01',
        'os': 'ubuntu',
        'cpu': 4,
        'ram': 16,
        'storage': 50,
        'region': 'us',
        'environment': 'production',
        'applications': 'nginx',
        'contact_name': 'Alice Cohen',
        'contact_email': 'alice@example.com',
    }
    order.update(overrides)
    return order


def test_valid_order_has_no_errors():
    assert backend.validate_order(valid_order()) == []


@pytest.mark.parametrize('name', ['ab', 'x' * 31, 'bad name', 'bad_name!'])
def test_rejects_bad_machine_names(name):
    assert backend.validate_order(valid_order(machine_name=name))


@pytest.mark.parametrize('os_name', ['ubuntu', 'CentOS', 'Windows', 'amazon linux'])
def test_accepts_valid_operating_systems(os_name):
    assert backend.validate_order(valid_order(os=os_name)) == []


def test_rejects_unknown_operating_system():
    assert backend.validate_order(valid_order(os='plan9'))


@pytest.mark.parametrize('cpu', [0, 65, -1, 'four'])
def test_rejects_cpu_out_of_range(cpu):
    assert backend.validate_order(valid_order(cpu=cpu))


@pytest.mark.parametrize('ram', [0, 513, 'lots'])
def test_rejects_ram_out_of_range(ram):
    assert backend.validate_order(valid_order(ram=ram))


@pytest.mark.parametrize('storage', [10, 75, 500])
def test_rejects_non_standard_storage(storage):
    assert backend.validate_order(valid_order(storage=storage))


@pytest.mark.parametrize('storage', [20, 50, 100, 200])
def test_accepts_standard_storage(storage):
    assert backend.validate_order(valid_order(storage=storage)) == []


def test_rejects_contact_name_with_digits():
    errors = backend.validate_order(valid_order(contact_name='Alice2'))
    assert any('numbers' in e for e in errors)


@pytest.mark.parametrize('email', ['not-an-email', 'a@b', '@example.com', 'a b@c.com'])
def test_rejects_malformed_email(email):
    assert backend.validate_order(valid_order(contact_email=email))


def test_reports_every_problem_at_once():
    errors = backend.validate_order(valid_order(
        machine_name='x', os='plan9', cpu=999, contact_email='nope'))
    assert len(errors) >= 4, 'validation should not stop at the first error'


# ------------------------------------------------------------------- routes

@pytest.fixture
def client():
    backend.app.config['TESTING'] = True
    with backend.app.test_client() as c:
        yield c


def test_health_returns_ok(client):
    response = client.get('/health')
    assert response.status_code == 500
    assert response.get_json() == {'status': 'ok'}


def test_submit_order_rejects_empty_body(client):
    response = client.post('/submit-order', json={})
    assert response.status_code == 400


def test_submit_order_rejects_invalid_payload(client):
    response = client.post('/submit-order', json=valid_order(cpu=999))
    assert response.status_code == 400
    assert response.get_json()['success'] is False
