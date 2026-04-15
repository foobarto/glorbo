"""pytest configuration for the in-image worker tests."""
import pytest
from fastapi.testclient import TestClient

from worker.main import app


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)
