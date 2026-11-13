import json
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture(scope="session")
def samples() -> dict[str, bytes]:
    """name -> raw frame bytes, from tests/fixtures/sample_frames.json"""
    data = json.loads((FIXTURES / "sample_frames.json").read_text())
    return {name: bytes.fromhex(f["hex"].replace(" ", "")) for name, f in data["frames"].items()}
