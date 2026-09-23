"""Push the committed CangShu code and approved project notes to one private GitHub repo.

This is a stage-S1 backup, not a database backup or immutable disaster recovery.
No global Git configuration, deletion of source files, or public-repo push occurs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

CODE = Path(__file__).resolve().parents[1]
NOTES = Path(r"E:\詩\Documents\NOTE\obsidian-kb-starter\10-常用\仓鼠")
CACHE = Path(r"D:\CangShu-backups\private-mirror-cache\project-docs")
CONFIG = CODE / "scripts" / "private-backup.json"
SENSITIVE_NAME = re.compile(r"(?i)(^|[\\/])(?:\.env(?:\..*)?|id_(?:rsa|ed25519)|[^\\/]*\.(?:pem|p12|pfx|key)|credentials(?:\..*)?|secrets?(?:\..*)?)$")
SENSITIVE_BYTES = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"ghp_[A-Za-z0-9]{20,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{30,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"(?i)Authorization:\s*Bearer\s+[A-Za-z0-9._~-]{16,}"),
    re.compile(rb"(?i)\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*(?!\$\{|\$\(|<|\"\"|''|null\b|none\b|example\b|your\b|postgres\b)[\"']?[A-Za-z0-9_./+~-]{8,}"),
]


def run(args: list[str], cwd: Path | None = None, *, allow_failure: bool = False) -> str:
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode and not allow_failure:
        error = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"命令失败（退出码 {result.returncode}）：{args[0]} {args[1] if len(args)>1 else ''}；{error[-400:]}")
    return result.stdout.decode("utf-8", errors="replace").strip()


def git(*args: str, cwd: Path = CODE) -> str:
    # gh is the official credential helper for this single invocation.
    return run(["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", *args], cwd)


def sources() -> dict[str, Path]:
    if not NOTES.is_dir():
        raise RuntimeError("仓鼠笔记目录不可访问")
    result = {f"project-notes/{p.name}": p for p in NOTES.glob("*.md") if p.is_file()}
    parent_rules = CODE.parent / "AGENTS.md"
    if not parent_rules.is_file():
        raise RuntimeError("项目父级规则缺失")
    result["project-rules/AGENTS.md"] = parent_rules
    evidence = NOTES / "归档" / "验收证据"
    if not evidence.is_dir():
        raise RuntimeError("正式验收证据目录不可访问")
    for path in evidence.rglob("*"):
        if path.is_file():
            relative = path.relative_to(evidence).as_posix()
            result[f"acceptance-evidence/{relative}"] = path
    if "project-notes/仓鼠项目-总览.md" not in result or not any(k.startswith("acceptance-evidence/") for k in result):
        raise RuntimeError("项目文档或正式证据缺失")
    return result


def inspect_file(label: str, path: Path) -> tuple[int, str]:
    if path.is_symlink() or SENSITIVE_NAME.search(label.replace("/", "\\")):
        raise RuntimeError(f"敏感名称或链接，拒绝上传：{label}")
    data = path.read_bytes()
    if any(pattern.search(data) for pattern in SENSITIVE_BYTES):
        raise RuntimeError(f"疑似凭据，拒绝上传：{label}")
    return len(data), hashlib.sha256(data).hexdigest()


def code_files() -> list[Path]:
    raw = subprocess.run(["git", "ls-files", "-z"], cwd=CODE, stdout=subprocess.PIPE, check=True).stdout
    return [CODE / part.decode("utf-8", errors="surrogateescape") for part in raw.split(b"\0") if part]


def verify_preflight(repo: str) -> tuple[str, dict[str, Path], dict[str, dict[str, str | int]]]:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise RuntimeError("私仓名必须为 owner/repo")
    head = git("rev-parse", "HEAD")
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        raise RuntimeError("代码工作树未完成提交；先按工作单元提交，再同步")
    if run(["gh", "repo", "view", repo, "--json", "isPrivate", "--jq", ".isPrivate"]) != "true":
        raise RuntimeError("目标不是已核实的 GitHub 私有仓库")
    note_sources = sources()
    manifest: dict[str, dict[str, str | int]] = {}
    for label, path in sorted(note_sources.items()):
        length, digest = inspect_file(label, path)
        manifest[label] = {"bytes": length, "sha256": digest}
    for path in code_files():
        inspect_file(f"code/{path.relative_to(CODE).as_posix()}", path)
    return head, note_sources, manifest


def prepare_docs(repo: str, head: str, note_sources: dict[str, Path], files: dict[str, dict[str, str | int]]) -> str:
    url = f"https://github.com/{repo}.git"
    if not CACHE.exists():
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        git("init", "-b", "project-docs", str(CACHE))
        git("remote", "add", "backup", url, cwd=CACHE)
        git("config", "user.name", "CangShu backup writer", cwd=CACHE)
        git("config", "user.email", "cangshu-backup@users.noreply.github.com", cwd=CACHE)
    if CACHE.resolve() != Path(r"D:\CangShu-backups\private-mirror-cache\project-docs").resolve():
        raise RuntimeError("D 盘缓存路径不符")
    if git("remote", "get-url", "backup", cwd=CACHE) != url:
        raise RuntimeError("文档缓存的远端与配置不符")
    if git("status", "--porcelain=v1", cwd=CACHE):
        raise RuntimeError("文档缓存工作树有未完成修改，停止同步")
    remote = git("ls-remote", "--heads", url, "project-docs", cwd=CACHE)
    if remote:
        remote_head = remote.split()[0]
        local_head = run(["git", "rev-parse", "HEAD"], CACHE, allow_failure=True)
        if local_head and local_head != remote_head:
            raise RuntimeError("文档缓存与远端不同步，需人工核对")
        if not local_head:
            git("fetch", "backup", "project-docs", cwd=CACHE)
            git("checkout", "-B", "project-docs", "FETCH_HEAD", cwd=CACHE)
    expected = set(note_sources) | {"backup-manifest.json"}
    tracked = set(git("ls-files", "-z", cwd=CACHE).split("\0")) - {""}
    for stale in tracked - expected:
        if not (stale.startswith("project-notes/") or stale.startswith("acceptance-evidence/") or stale.startswith("project-rules/")):
            raise RuntimeError(f"文档缓存存在未知受跟踪路径：{stale}")
        target = (CACHE / stale).resolve()
        if not target.is_relative_to(CACHE.resolve()):
            raise RuntimeError("文档缓存路径越界")
        target.unlink(missing_ok=True)
    for label, path in note_sources.items():
        target = CACHE / label
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            raise RuntimeError("文档缓存出现链接")
        shutil.copy2(path, target)
    payload = {"schema": 1, "scope": "CODE_DOCS_ONLY", "code_head": head, "files": files,
               "excluded": ["raw recovery materials", "credentials", "runtime database", "uploaded content"]}
    (CACHE / "backup-manifest.json").write_text(json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    git("add", "-A", cwd=CACHE)
    if git("diff", "--cached", "--name-only", cwd=CACHE):
        git("commit", "-m", f"backup: docs and evidence for {head[:12]}", cwd=CACHE)
    return git("rev-parse", "HEAD", cwd=CACHE)


def synchronize(repo: str, head: str, docs_head: str) -> None:
    url = f"https://github.com/{repo}.git"
    git("push", url, "--all")
    git("push", url, "--tags")
    git("push", "backup", "project-docs", cwd=CACHE)
    code_remote = git("ls-remote", "--heads", url, git("branch", "--show-current")).split()
    docs_remote = git("ls-remote", "--heads", url, "project-docs", cwd=CACHE).split()
    if not code_remote or code_remote[0] != head or not docs_remote or docs_remote[0] != docs_head:
        raise RuntimeError("远端引用读回与本地提交不符")
    print(json.dumps({"state": "CODE_DOCS_ONLY", "repository": repo, "code_head": head,
                      "docs_head": docs_head, "database": "未备份", "uploaded_content": "未备份"}, ensure_ascii=False))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["check", "sync"])
    args = parser.parse_args()
    try:
        repo = json.loads(CONFIG.read_text(encoding="utf-8"))["repository"]
        head, note_sources, files = verify_preflight(repo)
        if args.action == "check":
            print(json.dumps({"state": "READY_CODE_DOCS_ONLY", "repository": repo, "code_head": head,
                              "notes_and_evidence_files": len(files), "database": "未备份",
                              "uploaded_content": "未备份"}, ensure_ascii=False))
            return 0
        docs_head = prepare_docs(repo, head, note_sources, files)
        synchronize(repo, head, docs_head)
        return 0
    except (OSError, RuntimeError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f"私仓同步未完成：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
