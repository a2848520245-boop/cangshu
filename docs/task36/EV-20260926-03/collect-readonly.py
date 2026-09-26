"""Read-only Task 36 observations. Writes only beside this script."""

from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess


OUT = Path(__file__).resolve().parent
REPO = Path(r"E:\AgentWork\CangShu\cangshu")
STAGING = Path(r"E:\AgentWork\CangShu-recovery-staging-20260923")
EVIDENCE = Path(r"E:\詩\Documents\NOTE\obsidian-kb-starter\10-常用\仓鼠\归档\验收证据")
OLD = EVIDENCE / "EV-20260924-02"
CHECKED_AT = datetime.now().astimezone().isoformat()


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_json(name: str, data: object) -> None:
    (OUT / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


old_sources = json.loads((OLD / "source-index.json").read_text(encoding="utf-8"))["sources"]
paths: dict[str, dict] = {item["path"]: item for item in old_sources}
for path in [
    EVIDENCE / "EV-20260924-01" / "prior-audit.md",
    EVIDENCE / "EV-20260924-01" / "manifest.json",
    Path(r"E:\AgentWork\CangShu\_status\task18-active-docs-delivery-20260926\receipt.md"),
    *OLD.iterdir(),
    STAGING / "backup-transfer-20260923" / "backup-transfer-20260923.zip",
    Path(r"C:\Users\詩\Documents\Codex\CangShu-offsite-readback-7b3d18fe149c4d33b3d39e6c5ea68d3f\received.zip"),
]:
    if path.is_file() or path.name in {"prior-audit.md", "manifest.json", "received.zip"}:
        paths.setdefault(str(path), {})

indexed = []
for raw, previous in sorted(paths.items(), key=lambda pair: pair[0].casefold()):
    path = Path(raw)
    item = {"path": raw, "current_exists": path.is_file()}
    if "historical_sha256" in previous:
        item["historical_sha256"] = previous["historical_sha256"].lower()
        item["historical_bytes"] = previous.get("historical_bytes")
        item["historical_reference"] = "EV-20260924-02 source-index; historical checkpoint only"
    if path.is_file():
        try:
            item["current_bytes"] = path.stat().st_size
            item["current_sha256"] = digest(path)
        except OSError as exc:
            item["read_error"] = type(exc).__name__
    indexed.append(item)
write_json("source-index.json", {"checked_at": CHECKED_AT, "scope": "declared small reports and two historical ZIPs; no recursive source scan", "sources": indexed})


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, timeout=180)


head = git("rev-parse", "HEAD")
branch = git("branch", "--show-current")
status = git("status", "--porcelain=v1", "--untracked-files=all")
fsck = git("fsck", "--full", "--no-reflogs", "--no-progress")
(OUT / "git-fsck.stdout.txt").write_text(fsck.stdout, encoding="utf-8")
(OUT / "git-fsck.stderr.txt").write_text(fsck.stderr, encoding="utf-8")
old_commits = {}
for oid in ("429b339", "dbef395", "d367204", "13a6f8d"):
    result = git("cat-file", "-e", f"{oid}^{{commit}}")
    old_commits[oid] = {"commit_object_present": result.returncode == 0, "exit_code": result.returncode}

snapshot = json.loads((OUT / "snapshot.json").read_text(encoding="utf-8-sig"))
baseline_id = snapshot["docs"]["baseline_id"]
if not baseline_id or not snapshot["docs"]["complete"]:
    raise ValueError("current eight-file documentation baseline is incomplete")
os_state = json.loads((OUT / "os-observations.json").read_text(encoding="utf-8-sig"))
integrity = json.loads((STAGING / "integrity-summary.json").read_text(encoding="utf-8"))
copy = json.loads((STAGING / "live-repo-copy-summary.json").read_text(encoding="utf-8"))
observations = {
    "checked_at": CHECKED_AT,
    "method": "specified paths, git object checks, hashed declared sources; no service, database or network connection",
    "snapshot_path": "snapshot.json",
    "snapshot_sha256": digest(OUT / "snapshot.json"),
    "git": {
        "head": head.stdout.strip() if head.returncode == 0 else None,
        "head_exit": head.returncode,
        "branch": branch.stdout.strip() if branch.returncode == 0 else None,
        "branch_exit": branch.returncode,
        "status_exit": status.returncode,
        "dirty": bool(status.stdout) if status.returncode == 0 else None,
        "status_entry_count": len(status.stdout.splitlines()) if status.returncode == 0 else None,
        "fsck_exit": fsck.returncode,
        "fsck_output_bytes": len((fsck.stdout + fsck.stderr).encode("utf-8")),
        "fsck_command": "git -C <repo> fsck --full --no-reflogs --no-progress",
        "fsck_stdout_path": "git-fsck.stdout.txt",
        "fsck_stdout_sha256": digest(OUT / "git-fsck.stdout.txt"),
        "fsck_stderr_path": "git-fsck.stderr.txt",
        "fsck_stderr_sha256": digest(OUT / "git-fsck.stderr.txt"),
        "old_commit_objects": old_commits,
    },
    "docs_baseline": baseline_id,
    "c_recovery_root": {"path": r"C:\AgentWork-recovery", "exists": Path(r"C:\AgentWork-recovery").exists()},
    "staging": {
        "path": str(STAGING),
        "exists": STAGING.is_dir(),
        "integrity_summary_readable": True,
        "integrity_summary_historical_checked_at": integrity.get("CheckedAt"),
        "integrity_summary_historical_expected": integrity.get("ExpectedFileCount"),
        "integrity_summary_historical_copied": integrity.get("TargetCopiedFileCount"),
        "integrity_summary_historical_mismatch": integrity.get("HashMismatchCount"),
        "live_repo_copy_historical_checked_at": copy.get("FinalCheckedAt"),
        "live_repo_copy_historical_pairs": copy.get("FilePairsRechecked"),
        "current_full_247_file_rehash": "not performed",
    },
    "new_pgdata": {
        "path": r"E:\AgentWork\CangShu-db-rebuild-20260923\pgdata",
        "path_exists": Path(r"E:\AgentWork\CangShu-db-rebuild-20260923\pgdata").is_dir(),
        "pg_version_file_exists": Path(r"E:\AgentWork\CangShu-db-rebuild-20260923\pgdata\PG_VERSION").is_file(),
        "postmaster_pid_exists": Path(r"E:\AgentWork\CangShu-db-rebuild-20260923\pgdata\postmaster.pid").exists(),
        "database_connection_or_query": "not performed",
    },
    "os_observations_path": "os-observations.json",
    "os_observations_sha256": digest(OUT / "os-observations.json"),
    "os_process_and_port": os_state,
    "current_full_business_test": "not performed in this audit",
    "current_remote_delivery": "not queried in this audit; use single-writer receipt",
}
write_json("observations.json", observations)
print(f"observed_head={observations['git']['head']}")
print(f"git_fsck_exit={observations['git']['fsck_exit']}")
print(f"source_files={len(indexed)}")
