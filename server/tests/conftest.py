import pytest


@pytest.fixture(autouse=True)
def isolated_data_dir(tmp_path, monkeypatch):
    """Tests must never write the real mistake log."""
    monkeypatch.setenv("VOICECHESS_DATA_DIR", str(tmp_path / "data"))
