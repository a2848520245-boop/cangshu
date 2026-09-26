"""Temporary fixture verifier for CI classifier; never edits the checkout."""
import importlib.util
from pathlib import Path
import sys
import tempfile

# This copy lives under docs/task40/evidence; resolve the checked-out repo root.
classifier = Path(__file__).resolve().parents[3] / "scripts/ci-test-selection.py"
spec = importlib.util.spec_from_file_location("ci_test_selection", classifier)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

case = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="cangshu-ci-classification-") as root:
    fixture = Path(root)
    for name in module.NO_DB | module.POSTGRES | module.SUPPORT:
        text = f"class {name} {{}}\n"
        if name in module.POSTGRES:
            text += "// CANGSHU_DB_ isolated fixture\n"
        (fixture / f"{name}.java").write_text(text, encoding="utf-8")
    if case == "unknown":
        (fixture / "NewTests.java").write_text("class NewTests {}\n", encoding="utf-8")
    elif case == "missing":
        (fixture / "AlgorithmsTests.java").unlink()
    elif case == "db-in-no-db":
        (fixture / "AlgorithmsTests.java").write_text(
            "@SpringBootTest class AlgorithmsTests {}\n", encoding="utf-8"
        )
    else:
        raise SystemExit("unknown case")
    module.TESTS = fixture
    try:
        module.validate()
    except ValueError as error:
        print(f"REJECTED {case}: {error}")
        raise SystemExit(2)
    print(f"UNEXPECTED PASS {case}")
    raise SystemExit(0)
