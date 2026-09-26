#!/usr/bin/env python3
"""Fail closed when a Java test has no reviewed CI lane."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "src/test/java"

# Every Java test source is listed exactly once. New sources must be classified
# before the automatic PR gate can pass.
NO_DB = {
    "ApiExceptionHandlerTests",
    "ResourceControllerContentTests",
    "ResourceHeadContractTests",
    "HashDisplayTests",
    "DependencyStructureTests",
    "CatalogServiceTests",
    "DownloadServiceTests",
    "ProtectionReferenceServiceTests",
    "TrashRestoreEmptyTests",
    "TrashServiceTests",
    "UuidV7Tests",
    "CangshuPropertiesTests",
    "WriterGateTests",
    "UploadIngestServiceTests",
    "ReconcileReclaimingTests",
    "SchemaVerifierTests",
    "ResourceQueryServiceTests",
    "AlgorithmsTests",
    "FileStoreTests",
    "SegmentLockManagerTests",
}

POSTGRES = {
    "CangshuApplicationTests",
    "ConfigInjectionTests",
    "DeleteResourceIntegrationTests",
    "DownloadFlowIntegrationTests",
    "HealthEndpointTests",
    "ResourceQueryIntegrationTests",
    "TrashEndpointsIntegrationTests",
    "UploadFlowIntegrationTests",
    "UploadOverLimitIntegrationTests",
    "ContentRevivalIntegrationTests",
    "ReferenceSemanticsIntegrationTests",
    "GcAndReconcileIntegrationTests",
}

# Abstract fixture, never run by Surefire as a test.
SUPPORT = {"IsolatedPostgresIntegrationTest"}


def validate() -> None:
    sources = list(TESTS.rglob("*.java"))
    actual = {path.stem for path in sources}
    if len(actual) != len(sources):
        raise ValueError("Duplicate Java test source names; Maven -Dtest would be ambiguous")
    lanes = (NO_DB, POSTGRES, SUPPORT)
    if any(left & right for index, left in enumerate(lanes) for right in lanes[index + 1:]):
        raise ValueError("Java CI lane lists overlap")
    listed = NO_DB | POSTGRES | SUPPORT
    if actual != listed:
        raise ValueError(f"Unclassified Java sources: {sorted(actual - listed)}; "
                         f"missing classified sources: {sorted(listed - actual)}")
    for path in sources:
        body = path.read_text(encoding="utf-8")
        if path.stem in NO_DB and re.search(r"@SpringBootTest\b|extends\s+IsolatedPostgresIntegrationTest\b", body):
            raise ValueError(f"Database context appeared in no-DB lane: {path}")
        if path.stem in POSTGRES and not (
            "IsolatedPostgresIntegrationTest" in body or "CANGSHU_DB_" in body
        ):
            raise ValueError(f"PostgreSQL lane requires review of fixture: {path}")
    print(f"Classified {len(NO_DB)} no-DB, {len(POSTGRES)} PostgreSQL, "
          f"{len(SUPPORT)} support source(s)", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in {"check", "unit"}:
        raise SystemExit("usage: ci-test-selection.py check|unit")
    try:
        validate()
    except ValueError as error:
        raise SystemExit(str(error)) from error
    if sys.argv[1] == "unit":
        print(",".join(sorted(NO_DB)))
