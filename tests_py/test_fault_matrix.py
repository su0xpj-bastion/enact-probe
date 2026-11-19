"""The fault matrix as pytest cases (one per fault), so Jenkins shows each as its own test."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import fault_matrix  # noqa: E402


@pytest.mark.parametrize("fault", list(fault_matrix.EXPECTED), ids=lambda f: f or "clean")
def test_fault_is_caught_by_exactly_its_checks(fault):
    report = fault_matrix.session(fault)
    if report.get("invalid"):
        pytest.skip(f"machine too slow for a real-time session: {report['errors'][-1]}")
    assert fault_matrix.failing(report) == fault_matrix.EXPECTED[fault], report["checks"]
