#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""仓鼠文档体系与状态核验工具（doc_status.py）。

设计依据：``approved-design.md`` 第三节「治理机制设计」与第四节模板。
本工具只读代码仓与文档，不修改代码仓、不修改知识库；只有 ``--write-status``
会替换任务表中 ``<!-- status:start -->`` 与 ``<!-- status:end -->`` 之间的区域。

约束：
  * 只使用 Python 3.12 标准库（git 通过 CLI 子进程调用）。
  * 状态是计算结果：读取任务表的**计划字段**，但不信任手填的「核验」列。
  * 缺任一规范基线文件即不能通过。

子命令：
  snapshot --repo --docs --out
  check    --repo --docs --tasks --evidence-dir --out [--write-status]
  lint     --docs [--tasks] [--out] [--json]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath

TOOL_VERSION = "1.0.0"
SCHEMA = "cangshu.doc-status/1"

#: 规范基线固定 8 个文件，缺任一个 complete=False，任务不能判定为通过。
BASELINE_FILES = (
    "01-开发宪章与治理.md",
    "ADR-0001-项目启动与技术栈裁决.md",
    "03-M1-SPEC.md",
    "04-M1-架构与计划.md",
    "05-M1-接口契约.md",
    "06-M1-数据契约.md",
    "07-M1-运行手册.md",
    "08-M1-验收规范.md",
)

#: 根目录 12 份活文档（lint 篇幅预算对象）。
LIVE_DOCS = (
    "仓鼠项目-总览.md",
    "01-开发宪章与治理.md",
    "ADR-0001-项目启动与技术栈裁决.md",
    "03-M1-SPEC.md",
    "04-M1-架构与计划.md",
    "05-M1-接口契约.md",
    "06-M1-数据契约.md",
    "07-M1-运行手册.md",
    "08-M1-验收规范.md",
    "M1-任务表.md",
    "10-变更记录.md",
    "11-术语索引.md",
)

MAX_DOC_BYTES = 20000

#: 单文档预算覆盖（用户 2026-09-19 授权）：仅 ADR-0001 放宽到 32000 字节，
#: 其余活文档仍用 MAX_DOC_BYTES。见 10-变更记录.md 追加批次 ADR-BUDGET-2026-09-19。
DOC_BYTE_BUDGETS = {
    "ADR-0001-项目启动与技术栈裁决.md": 32000,
}

#: 任务表表头固定 10 列（顺序可变，名称必须齐全）。
TASK_COLUMNS = (
    "任务号",
    "类型",
    "里程碑",
    "交付物",
    "依赖",
    "验收ID",
    "安排",
    "核验",
    "证据ID",
    "阻塞ID",
)

#: 决策／文档类任务绑定文档证据，不因代码回滚失效。
DOC_TYPES = frozenset({"决策", "文档"})

#: manifest.kind 的分类（用于校验证据类型与任务绑定是否矛盾）。
DOC_KINDS_NORM = frozenset({"doc", "document", "decision", "决策", "文档"})
CODE_KINDS_NORM = frozenset(
    {"code", "impl", "implementation", "代码", "实现", "test", "验证", "ci"}
)

#: 受控核验状态。
VERIFY_STATES = ("通过", "失败", "待重验", "未验", "不可观测")

STATUS_START = "<!-- status:start -->"
STATUS_END = "<!-- status:end -->"

STATUS_REGION_RE = re.compile(
    r"(?P<start><!--\s*status:start\s*-->)(?P<body>.*?)(?P<end><!--\s*status:end\s*-->)",
    re.DOTALL,
)

#: 块 ID 定义：``^id``，但 ``#^id``（Obsidian 块引用）不算定义。
BLOCK_DEF_RE = re.compile(r"(?<![\w#])\^([A-Za-z][A-Za-z0-9_-]*)")

HEX40_RE = re.compile(r"[0-9a-fA-F]{40}")
HEX64_RE = re.compile(r"[0-9a-fA-F]{64}")

#: 证据 ID 必须是单个安全路径分量。
UNSAFE_COMPONENT_RE = re.compile(r"^[A-Za-z]:")


class DocStatusError(Exception):
    """可预期错误：干净失败，不打印堆栈。"""

    def __init__(self, message: str, exit_code: int = 2):
        super().__init__(message)
        self.exit_code = exit_code


# --------------------------------------------------------------------------
# 基础工具
# --------------------------------------------------------------------------


def iso_now() -> str:
    """本地时区带偏移的 ISO8601 时间戳。"""
    return datetime.now().astimezone().isoformat(timespec="seconds")


def sha256_file(path: Path) -> tuple[str, int]:
    """流式计算文件 SHA-256，返回 (十六进制摘要, 字节数)。"""
    hasher = hashlib.sha256()
    size = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
            size += len(chunk)
    return hasher.hexdigest(), size


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_text(path: Path, encoding: str = "utf-8") -> str:
    try:
        return path.read_text(encoding=encoding)
    except UnicodeDecodeError:
        return path.read_text(encoding=encoding, errors="replace")
    except OSError as exc:
        raise DocStatusError(f"无法读取文件 {path}：{exc}") from exc


def load_json(path: Path):
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise DocStatusError(f"无法读取 {path}：{exc}") from exc
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise DocStatusError(f"{path} 不是合法 UTF-8：{exc}") from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise DocStatusError(f"{path} 不是合法 JSON：{exc}") from exc


def write_json(out: Path, data) -> None:
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
    except OSError as exc:
        raise DocStatusError(f"无法写出 {out}：{exc}") from exc


def ensure_out_not_in_repo(out: Path, repo: Path) -> None:
    """``--out`` 不得位于被核验的代码仓内。"""
    try:
        out_res = Path(out).expanduser().resolve()
        repo_res = Path(repo).expanduser().resolve()
    except OSError as exc:
        raise DocStatusError(f"路径解析失败：{exc}") from exc
    if out_res == repo_res or out_res.is_relative_to(repo_res):
        raise DocStatusError(
            f"--out 不得位于被核验仓内：{out_res} 位于 {repo_res} 之下"
        )


def is_within(child: Path, base: Path) -> bool:
    try:
        child_res = child.resolve()
        base_res = base.resolve()
    except OSError:
        return False
    return child_res == base_res or child_res.is_relative_to(base_res)


def is_safe_component(name: str) -> bool:
    """证据 ID 必须是单个路径分量：拒绝绝对路径、``..``、盘符与分隔符。"""
    if not name or name in (".", ".."):
        return False
    if name.startswith("/") or name.startswith("\\"):
        return False
    if UNSAFE_COMPONENT_RE.match(name):
        return False
    if "/" in name or "\\" in name:
        return False
    if "\x00" in name:
        return False
    return True


def resolve_within(base: Path, relative: str, boundary: Path):
    """把证据内的相对路径解析到 ``boundary`` 之内；逃逸返回 ``None``。"""
    if not isinstance(relative, str):
        return None
    rel = relative.strip()
    if not rel:
        return None
    if UNSAFE_COMPONENT_RE.match(rel):
        return None
    if rel.startswith("/") or rel.startswith("\\"):
        return None
    posix = PurePosixPath(rel.replace("\\", "/"))
    if posix.is_absolute():
        return None
    if any(part in ("..",) for part in posix.parts):
        return None
    target = base.joinpath(*posix.parts)
    try:
        target_res = target.resolve()
        boundary_res = boundary.resolve()
    except OSError:
        return None
    if not target_res.is_relative_to(boundary_res):
        return None
    return target_res


def short_hash(value) -> str:
    if not isinstance(value, str):
        return str(value)
    text = value.strip()
    if text.startswith("sha256:"):
        text = text[len("sha256:") :]
    return text[:12]


# --------------------------------------------------------------------------
# 代码仓观测
# --------------------------------------------------------------------------


def run_git(repo: Path, args: list[str]):
    if shutil.which("git") is None:
        return 255, "", "未找到 git 可执行文件"
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=str(repo),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 255, "", f"{type(exc).__name__}: {exc}"
    return proc.returncode, proc.stdout or "", proc.stderr or ""


def observe_repo(repo: Path) -> dict:
    """观测代码仓：HEAD、工作树（含未跟踪）、分支、可观测性。"""
    info = {
        "path": str(repo),
        "observable": False,
        "head": None,
        "branch": None,
        "dirty": None,
        "dirty_count": None,
        "changes": [],
        "error": None,
        "queried_at": iso_now(),
    }
    if not repo.exists():
        info["error"] = "仓库路径不存在"
        return info
    if not repo.is_dir():
        info["error"] = "仓库路径不是目录"
        return info

    code, out, err = run_git(repo, ["rev-parse", "--is-inside-work-tree"])
    if code != 0 or out.strip() != "true":
        info["error"] = (err.strip() or "不是可访问的 git 工作树")[:500]
        return info

    code, out, err = run_git(repo, ["rev-parse", "HEAD"])
    if code != 0:
        info["error"] = ("无法读取 HEAD：" + (err.strip() or "可能尚无提交"))[:500]
        return info
    info["head"] = out.strip()

    code, out, _ = run_git(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    if code == 0:
        info["branch"] = out.strip()

    code, out, err = run_git(
        repo, ["status", "--porcelain=v1", "--untracked-files=all"]
    )
    if code != 0:
        info["error"] = ("无法读取工作树状态：" + err.strip())[:500]
        return info
    changes = [line for line in out.splitlines() if line.strip()]
    info["changes"] = changes[:200]
    info["dirty_count"] = len(changes)
    info["dirty"] = bool(changes)
    info["observable"] = True
    return info


# --------------------------------------------------------------------------
# 规范基线
# --------------------------------------------------------------------------


def compute_baseline(docs: Path) -> dict:
    """对固定 8 个规范文件取 SHA-256，生成规范基线 ID。"""
    files: dict[str, dict] = {}
    missing: list[str] = []
    canonical: list[str] = []
    for name in BASELINE_FILES:
        path = docs / name
        if path.is_file():
            digest, size = sha256_file(path)
            files[name] = {"present": True, "sha256": digest, "bytes": size}
            canonical.append(f"{name}\n{digest}\n")
        else:
            files[name] = {"present": False, "sha256": None, "bytes": None}
            missing.append(name)
            canonical.append(f"{name}\nMISSING\n")
    baseline_id = "sha256:" + sha256_bytes("".join(canonical).encode("utf-8"))
    return {
        "path": str(docs),
        "files": files,
        "missing": missing,
        "complete": not missing,
        "present_count": len(BASELINE_FILES) - len(missing),
        "baseline_id": baseline_id,
        "checked_at": iso_now(),
    }


def normalize_baseline(value) -> str | None:
    """把各种 manifest 基线写法归一成 ``sha256:<hex>``，无法解析返回 None。"""
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.startswith("sha256:"):
            text = text[len("sha256:") :]
        if HEX64_RE.fullmatch(text):
            return "sha256:" + text.lower()
        return value.strip()
    if isinstance(value, dict):
        if "baseline_id" in value:
            return normalize_baseline(value["baseline_id"])
        inner = value.get("files") if isinstance(value.get("files"), dict) else value
        parts = []
        for name in BASELINE_FILES:
            item = inner.get(name)
            if not isinstance(item, str) or not HEX64_RE.fullmatch(item.strip()):
                return None
            parts.append(f"{name}\n{item.strip().lower()}\n")
        return "sha256:" + sha256_bytes("".join(parts).encode("utf-8"))
    return None


# --------------------------------------------------------------------------
# 任务表解析
# --------------------------------------------------------------------------


def normalize_cell(cell: str) -> str:
    return re.sub(r"[\s`*]+", "", cell or "")


def split_md_row(line: str) -> list[str]:
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|"):
        text = text[:-1]
    parts: list[str] = []
    buf: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text) and text[index + 1] == "|":
            buf.append("|")
            index += 2
            continue
        if char == "|":
            parts.append("".join(buf))
            buf = []
            index += 1
            continue
        buf.append(char)
        index += 1
    parts.append("".join(buf))
    return [part.strip() for part in parts]


def is_separator_row(line: str) -> bool:
    text = line.strip()
    if not text.startswith("|"):
        return False
    cells = split_md_row(text)
    if not cells:
        return False
    return all(re.fullmatch(r":?-{2,}:?", cell.strip()) for cell in cells)


def split_field_list(value: str) -> list[str]:
    if value is None:
        return []
    text = value.strip()
    if text in ("", "-", "—", "–", "无", "N/A", "n/a", "/"):
        return []
    text = re.sub(r"<br\s*/?>", " ", text, flags=re.IGNORECASE)
    out: list[str] = []
    for part in re.split(r"[,，、;；/\s]+", text):
        part = part.strip()
        if not part or part in ("-", "—", "无"):
            continue
        if part not in out:
            out.append(part)
    return out


def parse_task_table(text: str) -> list[dict]:
    """解析任务 MD 表；表头 10 列必须齐全。"""
    lines = text.splitlines()
    header_index = None
    header_cols: list[str] = []
    for index, line in enumerate(lines):
        if not line.strip().startswith("|"):
            continue
        cells = [normalize_cell(cell) for cell in split_md_row(line)]
        if all(column in cells for column in TASK_COLUMNS):
            if index + 1 < len(lines) and is_separator_row(lines[index + 1]):
                header_index = index
                header_cols = cells
                break
    if header_index is None:
        raise DocStatusError(
            "未找到任务表表头；需要 10 列：" + "、".join(TASK_COLUMNS)
        )

    column_index: dict[str, int] = {}
    for column in TASK_COLUMNS:
        column_index[column] = header_cols.index(column)
    width = len(header_cols)

    tasks: list[dict] = []
    index = header_index + 2
    while index < len(lines):
        line = lines[index]
        if not line.strip().startswith("|"):
            break
        cells = split_md_row(line)
        if len(cells) != width:
            # 宽度不符：视为表结束（例如紧随其后的状态区域表）。
            break
        row = {column: cells[column_index[column]] for column in TASK_COLUMNS}
        task_id = row["任务号"].strip()
        if not task_id:
            index += 1
            continue
        tasks.append(
            {
                "task_id": task_id,
                "type": row["类型"].strip(),
                "milestone": row["里程碑"].strip(),
                "deliverable": row["交付物"].strip(),
                "dependencies": split_field_list(row["依赖"]),
                "acceptance": split_field_list(row["验收ID"]),
                "schedule": row["安排"].strip(),
                "declared_verification": row["核验"].strip(),
                "evidence_ids": split_field_list(row["证据ID"]),
                "blocked_by": row["阻塞ID"].strip(),
            }
        )
        index += 1
    return tasks


def classify_binding(type_value: str) -> str:
    """决策／文档类型全部命中才绑定文档证据，否则绑定代码证据。"""
    tokens = [token for token in split_field_list(type_value)]
    if tokens and all(token in DOC_TYPES for token in tokens):
        return "doc"
    return "code"


# --------------------------------------------------------------------------
# 证据清单
# --------------------------------------------------------------------------


def build_evidence_index(evidence_dir: Path) -> dict[str, Path]:
    """建立 证据ID -> manifest 路径 索引；拒绝被 symlink 带出证据根的条目。"""
    index: dict[str, Path] = {}
    if not evidence_dir.is_dir():
        return index
    try:
        entries = sorted(evidence_dir.iterdir(), key=lambda p: p.name)
    except OSError as exc:
        raise DocStatusError(f"无法枚举证据目录 {evidence_dir}：{exc}") from exc
    for entry in entries:
        if not is_safe_component(entry.name):
            continue
        if not is_within(entry, evidence_dir):
            # symlink 指向证据根之外：不登记，避免逃逸。
            continue
        if entry.is_dir():
            manifest = entry / "manifest.json"
            if manifest.is_file():
                index[entry.name] = manifest
        elif entry.is_file() and entry.suffix.lower() == ".json" and entry.name != "manifest.json":
            index[entry.stem] = entry
    return index


def normalize_result(value) -> str:
    if isinstance(value, bool):
        return "pass" if value else "fail"
    if value is None:
        return "unknown"
    text = str(value).strip().lower()
    if text in ("pass", "passed", "ok", "success", "true", "通过", "是", "p"):
        return "pass"
    if text in ("fail", "failed", "error", "false", "失败", "否", "f"):
        return "fail"
    return "unknown"


def normalize_checks(manifest: dict):
    """读取 manifest 的验收逐项结果；格式非法返回 None。"""
    raw = None
    for key in ("checks", "acceptance", "acceptance_results", "results", "验收"):
        if key in manifest:
            raw = manifest[key]
            break
    if raw is None:
        return None
    if isinstance(raw, dict):
        raw = [{"id": key, "result": value} for key, value in raw.items()]
    if not isinstance(raw, list):
        return None
    out: list[dict] = []
    for item in raw:
        if not isinstance(item, dict):
            return None
        rid = item.get("id", item.get("acceptance_id", item.get("name", item.get("验收ID"))))
        out.append(
            {
                "id": None if rid is None else str(rid),
                "result": normalize_result(item.get("result", item.get("status"))),
            }
        )
    return out


def validate_artifact(evidence_id: str, package: Path, boundary: Path, artifact, problems: list[str]) -> None:
    if not isinstance(artifact, dict):
        problems.append(f"证据 {evidence_id} 的工件条目不是对象")
        return
    rel = artifact.get("path")
    digest = artifact.get("sha256")
    if not isinstance(rel, str) or not rel.strip():
        problems.append(f"证据 {evidence_id} 的工件缺少 path")
        return
    if not isinstance(digest, str) or not HEX64_RE.fullmatch(digest.strip()):
        problems.append(f"证据 {evidence_id} 的工件 {rel} 缺少合法 sha256")
        return
    resolved = resolve_within(package, rel, boundary)
    if resolved is None:
        problems.append(f"证据 {evidence_id} 的工件路径逃逸被拒绝：{rel}")
        return
    if not resolved.is_file():
        problems.append(f"证据 {evidence_id} 的原始工件不存在：{rel}")
        return
    actual, _ = sha256_file(resolved)
    if actual.lower() != digest.strip().lower():
        problems.append(f"证据 {evidence_id} 的工件摘要不符：{rel}")


# --------------------------------------------------------------------------
# 核验推导
# --------------------------------------------------------------------------


def evaluate_task(task: dict, ctx: dict) -> dict:
    binding = classify_binding(task["type"])
    required = list(task["acceptance"])
    evidence_ids = list(task["evidence_ids"])
    result = {
        "task_id": task["task_id"],
        "type": task["type"],
        "milestone": task["milestone"],
        "schedule": task["schedule"],
        "declared_verification": task["declared_verification"],
        "blocked_by": task["blocked_by"],
        "binding": binding,
        "required_acceptance": required,
        "evidence_ids": evidence_ids,
        "verification": None,
        "reasons": [],
        "reason_text": "",
        "evidence": [],
    }

    repo = ctx["repo"]
    baseline = ctx["baseline"]

    if binding == "code" and not repo["observable"]:
        result["verification"] = "不可观测"
        result["reasons"].append(f"代码仓不可访问：{repo.get('error') or '未知原因'}")
        return _finalize(result)

    if not evidence_ids:
        result["verification"] = "未验"
        result["reasons"].append("任务表未登记证据ID")
        if not required:
            result["reasons"].append("任务表也未声明验收ID")
        return _finalize(result)

    if not required:
        result["verification"] = "失败"
        result["reasons"].append("任务表未声明验收ID，无法判断所需验收项")
        return _finalize(result)

    problems: list[str] = []
    stale: list[str] = []

    if not baseline["complete"]:
        problems.append(
            "当前规范基线不完整（缺少：" + "、".join(baseline["missing"]) + "）"
        )

    unsafe = [eid for eid in evidence_ids if not is_safe_component(eid)]
    if unsafe:
        problems.append("证据ID非法（拒绝路径逃逸）：" + "、".join(unsafe))

    missing_ids = [
        eid
        for eid in evidence_ids
        if is_safe_component(eid) and eid not in ctx["evidence_index"]
    ]
    if missing_ids:
        problems.append("声明的证据无法定位（可能已丢失）：" + "、".join(missing_ids))

    manifests: list[tuple[str, dict]] = []
    for eid in evidence_ids:
        if not is_safe_component(eid):
            continue
        manifest_path = ctx["evidence_index"].get(eid)
        if manifest_path is None:
            continue
        try:
            manifest = load_json(manifest_path)
        except DocStatusError as exc:
            problems.append(f"证据 {eid} 清单无法读取：{exc}")
            continue
        if not isinstance(manifest, dict):
            problems.append(f"证据 {eid} 清单不是 JSON 对象")
            continue
        manifest_task = manifest.get("task_id")
        if manifest_task is None:
            problems.append(f"证据 {eid} 缺少 task_id")
        elif str(manifest_task).strip() != task["task_id"]:
            problems.append(
                f"证据 {eid} 的 task_id={manifest_task!r} 与任务 {task['task_id']} 不一致"
            )
        kind = manifest.get("kind")
        if not isinstance(kind, str) or not kind.strip():
            problems.append(f"证据 {eid} 缺少 kind")
        else:
            kind_norm = kind.strip().lower()
            if binding == "code" and kind_norm in DOC_KINDS_NORM:
                problems.append(
                    f"证据 {eid} 的 kind={kind!r} 属文档/决策证据，不能证明代码任务"
                )
            elif binding == "doc" and kind_norm in CODE_KINDS_NORM:
                problems.append(
                    f"证据 {eid} 的 kind={kind!r} 属代码证据，不能证明决策/文档任务"
                )
        manifests.append((eid, manifest))
        result["evidence"].append(
            {
                "id": eid,
                "manifest": str(manifest_path),
                "task_id": manifest.get("task_id"),
                "kind": manifest.get("kind"),
                "commit": manifest.get("commit"),
                "exit_code": manifest.get("exit_code"),
            }
        )

    if not manifests and not problems:
        result["verification"] = "未验"
        result["reasons"].append("未找到可用的证据清单")
        return _finalize(result)

    acceptance_results: dict[str, list[str]] = {rid: [] for rid in required}
    for eid, manifest in manifests:
        # exit_code：必须显式存在且为 0。
        if "exit_code" not in manifest:
            problems.append(f"证据 {eid} 缺少 exit_code")
        else:
            exit_code = manifest["exit_code"]
            if isinstance(exit_code, bool) or not isinstance(exit_code, int):
                problems.append(f"证据 {eid} 的 exit_code 非整数：{exit_code!r}")
            elif exit_code != 0:
                problems.append(f"证据 {eid} 的 exit_code={exit_code}（仅 0 视为通过）")

        # commit：代码任务必须精准等于当前 HEAD；祖先可达不继承结论。
        if binding == "code":
            commit = manifest.get("commit")
            commit_text = commit.strip() if isinstance(commit, str) else ""
            if not (HEX40_RE.fullmatch(commit_text) or HEX64_RE.fullmatch(commit_text)):
                problems.append(f"证据 {eid} 缺少或非法 commit（代码任务要求完整提交）")
            elif commit_text.lower() != (repo["head"] or "").lower():
                stale.append(
                    f"证据 {eid} 的提交 {commit_text[:12]} 与当前 HEAD "
                    f"{(repo['head'] or '')[:12]} 不一致（祖先可达不继承结论）"
                )

        # docs_baseline：两种绑定都必须与当前基线一致。
        normalized = normalize_baseline(manifest.get("docs_baseline"))
        if baseline["complete"]:
            if normalized is None:
                problems.append(f"证据 {eid} 缺少或无法解析 docs_baseline")
            elif normalized != baseline["baseline_id"]:
                stale.append(
                    f"证据 {eid} 的文档基线 {short_hash(normalized)} 与当前基线 "
                    f"{short_hash(baseline['baseline_id'])} 不一致"
                )

        checks = normalize_checks(manifest)
        if checks is None:
            problems.append(f"证据 {eid} 的验收逐项结果缺失或格式非法")
        else:
            for rid in required:
                for check in checks:
                    if check["id"] and check["id"].upper() == rid.upper():
                        acceptance_results[rid].append(check["result"])

        artifacts = manifest.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            problems.append(f"证据 {eid} 未登记原始工件（artifacts）")
        else:
            package = ctx["evidence_index"][eid].parent
            for artifact in artifacts:
                validate_artifact(eid, package, ctx["evidence_dir"], artifact, problems)

    for rid in required:
        results = acceptance_results[rid]
        if not results:
            problems.append(f"缺少验收项 {rid} 的结果")
        elif "fail" in results:
            problems.append(f"验收项 {rid} 存在失败结果")
        elif "unknown" in results:
            problems.append(f"验收项 {rid} 结果不可判定")
        elif "pass" not in results:
            problems.append(f"缺少验收项 {rid} 的通过结果")

    if binding == "code" and repo["dirty"]:
        stale.append("代码仓工作树不干净（含未跟踪文件）")

    if problems:
        result["verification"] = "失败"
        result["reasons"] = problems + stale
    elif stale:
        result["verification"] = "待重验"
        result["reasons"] = stale
    else:
        result["verification"] = "通过"
        result["reasons"] = ["本地 HEAD、工作树、规范基线与证据全部匹配"]
    return _finalize(result)


def _finalize(result: dict) -> dict:
    result["reason_text"] = "；".join(result["reasons"]) if result["reasons"] else "—"
    return result


def build_statistics_line(tasks: list[dict]) -> str:
    counts = {state: 0 for state in VERIFY_STATES}
    for task in tasks:
        counts[task["verification"]] = counts.get(task["verification"], 0) + 1
    total = len(tasks)
    code_bound = sum(1 for task in tasks if task["binding"] == "code")
    doc_bound = total - code_bound
    deferred = sum(1 for task in tasks if task["schedule"] == "后置")
    return (
        f"**统计**：共 {total} 项 ｜ 通过 {counts['通过']} ｜ 失败 {counts['失败']} ｜ "
        f"待重验 {counts['待重验']} ｜ 未验 {counts['未验']} ｜ "
        f"不可观测 {counts['不可观测']}"
        f"（代码绑定 {code_bound}；决策/文档绑定 {doc_bound}；后置 {deferred}）"
    )


# --------------------------------------------------------------------------
# 状态区域
# --------------------------------------------------------------------------


def md_cell(value) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\\", "\\\\").replace("|", "\\|")
    return re.sub(r"\s*\r?\n\s*", " ", text).strip()


def detect_newline(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def build_status_body(report: dict, newline: str) -> str:
    repo = report["repo"]
    docs = report["docs"]
    lines: list[str] = []
    lines.append(f"- 生成时间：{report['generated_at']}")
    if repo["observable"]:
        worktree = (
            f"脏（{repo['dirty_count']} 项变更/未跟踪）"
            if repo["dirty"]
            else "干净"
        )
        lines.append(f"- 代码仓：{repo['path']} ｜ HEAD：{repo['head']} ｜ 工作树：{worktree}")
    else:
        lines.append(
            f"- 代码仓：{repo['path']} ｜ 不可观测（{repo.get('error') or '未知原因'}）"
        )
    if docs["complete"]:
        lines.append(f"- 规范基线：{docs['baseline_id']}（{docs['present_count']}/8 齐全）")
    else:
        lines.append(
            f"- 规范基线：{docs['baseline_id']}（不完整，缺少：{'、'.join(docs['missing'])}）"
        )
    delivery = report.get("delivery", {})
    lines.append(f"- 远端交付：{delivery.get('state', '未核验')}（{delivery.get('note', '')}）")
    lines.append("")
    lines.append("| 任务号 | 类型 | 里程碑 | 安排 | 核验 | 证据ID | 说明 |")
    lines.append("|---|---|---|---|---|---|---|")
    for task in report["tasks"]:
        lines.append(
            "| "
            + " | ".join(
                md_cell(value)
                for value in (
                    task["task_id"],
                    task["type"],
                    task["milestone"],
                    task["schedule"],
                    task["verification"],
                    "、".join(task["evidence_ids"]) if task["evidence_ids"] else "—",
                    task["reason_text"],
                )
            )
            + " |"
        )
    lines.append("")
    lines.append(report["statistics_line"])
    return newline.join(lines)


def validate_status_markers(text: str) -> None:
    matches = list(STATUS_REGION_RE.finditer(text))
    if not matches:
        raise DocStatusError(
            f"任务表缺少 {STATUS_START} / {STATUS_END} 标记，无法 --write-status"
        )
    if len(matches) > 1:
        raise DocStatusError("任务表存在多个 status 区域，拒绝写入")


def write_status_region(path: Path, body: str, original: str) -> bool:
    validate_status_markers(original)
    newline = detect_newline(original)

    def _replace(match: re.Match) -> str:
        return match.group("start") + newline + body + newline + match.group("end")

    new_text = STATUS_REGION_RE.sub(_replace, original, count=1)
    if new_text == original:
        return False
    try:
        path.write_text(new_text, encoding="utf-8", newline="")
    except OSError as exc:
        raise DocStatusError(f"无法写入任务表 {path}：{exc}") from exc
    return True


# --------------------------------------------------------------------------
# 子命令
# --------------------------------------------------------------------------


def cmd_snapshot(args) -> int:
    repo = Path(args.repo)
    docs = Path(args.docs)
    out = Path(args.out)
    ensure_out_not_in_repo(out, repo)
    report = {
        "schema": SCHEMA,
        "kind": "snapshot",
        "tool_version": TOOL_VERSION,
        "generated_at": iso_now(),
        "repo": observe_repo(repo),
        "docs": compute_baseline(docs),
    }
    write_json(out, report)
    repo_info = report["repo"]
    head = repo_info["head"] or "不可观测"
    if not repo_info["observable"]:
        worktree = "不可观测"
    else:
        worktree = "脏" if repo_info["dirty"] else "干净"
    print(f"已写出快照：{out}")
    print(
        f"HEAD：{head} ｜ 工作树：{worktree} ｜ "
        f"规范基线：{report['docs']['baseline_id']}"
        f"（{report['docs']['present_count']}/8）"
    )
    return 0


def cmd_check(args) -> int:
    repo = Path(args.repo)
    docs = Path(args.docs)
    tasks_path = Path(args.tasks)
    evidence_dir = Path(args.evidence_dir)
    out = Path(args.out)
    ensure_out_not_in_repo(out, repo)

    if not tasks_path.is_file():
        raise DocStatusError(f"任务表不存在：{tasks_path}")
    original = read_text(tasks_path, encoding="utf-8-sig")
    if args.write_status:
        validate_status_markers(original)

    tasks = parse_task_table(original)
    if not tasks:
        raise DocStatusError("任务表未解析到任何任务行")

    ctx = {
        "repo": observe_repo(repo),
        "baseline": compute_baseline(docs),
        "evidence_dir": evidence_dir,
        "evidence_index": build_evidence_index(evidence_dir),
    }
    results = [evaluate_task(task, ctx) for task in tasks]
    report = {
        "schema": SCHEMA,
        "kind": "check",
        "tool_version": TOOL_VERSION,
        "generated_at": iso_now(),
        "repo": ctx["repo"],
        "docs": ctx["baseline"],
        "evidence_dir": str(evidence_dir),
        "delivery": {
            "verified": False,
            "state": "未核验",
            "checked_at": None,
            "note": "本轮只核对本地证据与本地 HEAD，未查询远端交付分支或发布 tag。",
        },
        "tasks": results,
        "summary": {
            state: sum(1 for task in results if task["verification"] == state)
            for state in VERIFY_STATES
        },
        "statistics_line": build_statistics_line(results),
    }
    report["summary"]["共"] = len(results)

    if args.write_status:
        body = build_status_body(report, detect_newline(original))
        changed = write_status_region(tasks_path, body, original)
        report["status_written"] = True
        report["status_changed"] = changed
        report["status_region"] = body

    write_json(out, report)

    for task in results:
        print(
            f"任务 {task['task_id']}：{task['verification']}"
            f"（{task['binding']} 绑定）{task['reason_text']}"
        )
    print(report["statistics_line"])
    print(f"报告：{out}")
    all_pass = all(task["verification"] == "通过" for task in results)
    return 0 if all_pass else 1


def find_cycles(nodes: list[str], edges: dict[str, list[str]]) -> list[list[str]]:
    color = {node: 0 for node in nodes}
    stack: list[str] = []
    cycles: list[list[str]] = []

    def visit(node: str) -> None:
        color[node] = 1
        stack.append(node)
        for dep in edges.get(node, []):
            if color.get(dep, 2) == 1:
                start = stack.index(dep)
                cycles.append(stack[start:] + [dep])
            elif color.get(dep, 2) == 0:
                visit(dep)
        stack.pop()
        color[node] = 2

    for node in nodes:
        if color[node] == 0:
            visit(node)

    unique: list[list[str]] = []
    seen = set()
    for cycle in cycles:
        key = tuple(sorted(cycle))
        if key in seen:
            continue
        seen.add(key)
        unique.append(cycle)
    return unique


def cmd_lint(args) -> int:
    docs = Path(args.docs)
    if not docs.is_dir():
        raise DocStatusError(f"文档目录不存在：{docs}")

    findings: list[dict] = []
    size_report: list[dict] = []

    # 1) 12 份根活文档存在且不超各自篇幅预算（默认 MAX_DOC_BYTES，可被 DOC_BYTE_BUDGETS 覆盖）。
    for name in LIVE_DOCS:
        path = docs / name
        if not path.is_file():
            findings.append({"check": "doc-budget", "detail": f"缺少活文档：{name}"})
            continue
        size = path.stat().st_size
        limit = DOC_BYTE_BUDGETS.get(name, MAX_DOC_BYTES)
        size_report.append({"name": name, "bytes": size, "limit": limit})
        if size > limit:
            findings.append(
                {
                    "check": "doc-budget",
                    "detail": f"{name} 超过预算：{size} > {limit} bytes",
                }
            )

    # 2) 重复块 ID（跨 12 份活文档全局唯一，`#^id` 引用不算定义）。
    definitions: dict[str, list[dict]] = {}
    for name in LIVE_DOCS:
        path = docs / name
        if not path.is_file():
            continue
        text = read_text(path, encoding="utf-8-sig")
        for lineno, line in enumerate(text.splitlines(), 1):
            for match in BLOCK_DEF_RE.finditer(line):
                block_id = match.group(1).lower()
                definitions.setdefault(block_id, []).append(
                    {"file": name, "line": lineno}
                )
    for block_id, locations in sorted(definitions.items()):
        if len(locations) > 1:
            where = "、".join(f"{item['file']}:{item['line']}" for item in locations)
            findings.append(
                {
                    "check": "duplicate-block-id",
                    "detail": f"块 ID ^{block_id} 重复定义：{where}",
                    "id": block_id,
                    "locations": locations,
                }
            )

    # 3) 任务依赖成环。
    tasks_path = Path(args.tasks) if args.tasks else docs / "M1-任务表.md"
    cycle_report: list[list[str]] = []
    node_ids: list[str] = []
    if not tasks_path.is_file():
        findings.append(
            {"check": "task-graph", "detail": f"任务表不存在：{tasks_path}"}
        )
    else:
        try:
            tasks = parse_task_table(read_text(tasks_path, encoding="utf-8-sig"))
        except DocStatusError as exc:
            findings.append({"check": "task-graph", "detail": str(exc)})
            tasks = []
        node_ids = [task["task_id"] for task in tasks]
        node_set = set(node_ids)
        edges = {
            task["task_id"]: [
                dep for dep in task["dependencies"] if dep in node_set
            ]
            for task in tasks
        }
        cycle_report = find_cycles(node_ids, edges)
        for cycle in cycle_report:
            findings.append(
                {
                    "check": "task-cycle",
                    "detail": "任务依赖成环：" + " → ".join(cycle),
                    "cycle": cycle,
                }
            )

    report = {
        "schema": SCHEMA,
        "kind": "lint",
        "tool_version": TOOL_VERSION,
        "generated_at": iso_now(),
        "docs": str(docs),
        "tasks": str(tasks_path),
        "max_doc_bytes": MAX_DOC_BYTES,
        "sizes": size_report,
        "block_id_definitions": len(definitions),
        "cycles": cycle_report,
        "findings": findings,
        "passed": not findings,
    }
    if args.out:
        write_json(Path(args.out), report)

    if args.as_json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        if size_report:
            for item in size_report:
                mark = "OK" if item["bytes"] <= MAX_DOC_BYTES else "FAIL"
                print(f"[{mark}] {item['name']}：{item['bytes']} / {item['limit']} bytes")
        if not findings:
            print("[OK] 12 份根活文档字节预算")
            print(f"[OK] 块 ID 全局唯一（{len(definitions)} 个定义）")
            print(f"[OK] 任务依赖无环（{len(node_ids)} 个任务节点）")
        else:
            for item in findings:
                print(f"[FAIL] {item['detail']}")
        print(f"lint 结果：{'通过' if not findings else f'{len(findings)} 项问题'}")
    return 0 if not findings else 1


# --------------------------------------------------------------------------
# 入口
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="doc_status.py",
        description="仓鼠文档体系与状态核验工具（只读代码仓与文档；不改代码、不改知识库）。",
    )
    parser.add_argument("--version", action="version", version=f"doc_status.py {TOOL_VERSION}")
    parser.add_argument(
        "--debug", action="store_true", help="调试模式：遇到未预期错误时打印完整堆栈"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    snapshot = sub.add_parser(
        "snapshot", help="采集 HEAD／工作树／规范基线／时间，写出 JSON 快照"
    )
    snapshot.add_argument("--repo", required=True, help="代码仓路径（只读）")
    snapshot.add_argument("--docs", required=True, help="活文档目录（规范基线所在）")
    snapshot.add_argument("--out", required=True, help="快照 JSON 输出路径（不得在仓内）")
    snapshot.set_defaults(func=cmd_snapshot)

    check = sub.add_parser("check", help="按任务表与证据清单推导核验状态")
    check.add_argument("--repo", required=True, help="代码仓路径（只读）")
    check.add_argument("--docs", required=True, help="活文档目录（规范基线所在）")
    check.add_argument("--tasks", required=True, help="任务表 Markdown 路径")
    check.add_argument("--evidence-dir", required=True, dest="evidence_dir", help="证据根目录")
    check.add_argument("--out", required=True, help="核验报告 JSON 输出路径（不得在仓内）")
    check.add_argument(
        "--write-status",
        action="store_true",
        dest="write_status",
        help="只替换任务表 status 标记之间的区域",
    )
    check.set_defaults(func=cmd_check)

    lint = sub.add_parser(
        "lint", help="机械检查：篇幅预算、重复块 ID、任务依赖环"
    )
    lint.add_argument("--docs", required=True, help="活文档目录")
    lint.add_argument("--tasks", default=None, help="任务表路径（默认 <docs>/M1-任务表.md）")
    lint.add_argument("--out", default=None, help="可选：lint JSON 输出路径")
    lint.add_argument("--json", action="store_true", dest="as_json", help="以 JSON 打印结果")
    lint.set_defaults(func=cmd_lint)

    return parser


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args) or 0)
    except DocStatusError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return exc.exit_code
    except BrokenPipeError:
        return 2
    except KeyboardInterrupt:
        print("已中断", file=sys.stderr)
        return 130
    except Exception as exc:  # 兜底：任何输入都干净失败，不 traceback。
        if getattr(args, "debug", False):
            raise
        print(f"未预期错误：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
