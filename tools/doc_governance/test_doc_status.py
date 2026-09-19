#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""doc_status.py 的真实运行测试。

使用临时目录与临时 git 仓库；不触碰知识库或真实代码仓。
运行：``python -m unittest -v test_doc_status``（在 output/ 目录内）。
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import doc_status  # noqa: E402

GIT = shutil.which("git")


def git_run(args, cwd):
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} 失败：{proc.stderr}")
    return proc.stdout


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def force_rmtree(path) -> None:
    """删除临时目录；Windows 上 git 写出的只读对象文件需先去掉只读位。"""
    path = Path(path)

    def _on_error(func, target, exc_info):
        try:
            os.chmod(target, 0o777)
            func(target)
        except OSError:
            pass

    try:
        if sys.version_info >= (3, 12):
            shutil.rmtree(path, onexc=_on_error)
        else:
            shutil.rmtree(path, onerror=_on_error)
    except OSError:
        pass


class Base(unittest.TestCase):
    def setUp(self):
        # 临时工作文件只落在 output/.test-tmp/ 或 DOC_STATUS_TEST_TMP 指定的目录。
        # 注意：不使用 tempfile.mkdtemp（它以 0o700 建目录，受限沙箱下不可再访问）。
        root = os.environ.get("DOC_STATUS_TEST_TMP")
        base = Path(root) if root else (Path(__file__).resolve().parent / ".test-tmp")
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = base / f"case_{uuid.uuid4().hex[:12]}"
        self.tmp.mkdir()
        self.addCleanup(force_rmtree, self.tmp)
        self.docs = self.tmp / "docs"
        self.docs.mkdir()
        self.write_baseline()

    # -- 夹具 ---------------------------------------------------------------
    def write_baseline(self):
        for name in doc_status.BASELINE_FILES:
            (self.docs / name).write_text(
                f"# {name}\n\n基线内容\n", encoding="utf-8"
            )

    def baseline_id(self) -> str:
        return doc_status.compute_baseline(self.docs)["baseline_id"]

    def make_repo(self, commits: int = 2):
        if not GIT:
            self.skipTest("需要 git")
        repo = self.tmp / "repo"
        repo.mkdir()
        git_run(["init", "-q", "-b", "main"], repo)
        git_run(["config", "user.email", "tester@example.com"], repo)
        git_run(["config", "user.name", "tester"], repo)
        git_run(["config", "commit.gpgsign", "false"], repo)
        git_run(["config", "tag.gpgsign", "false"], repo)
        for index in range(commits):
            (repo / "README.md").write_text(f"line {index}\n", encoding="utf-8")
            git_run(["add", "-A"], repo)
            git_run(["commit", "-q", "-m", f"commit {index}"], repo)
        head = git_run(["rev-parse", "HEAD"], repo).strip()
        return repo, head

    def make_plain_dir(self) -> Path:
        plain = self.tmp / "not-a-repo"
        plain.mkdir()
        (plain / "file.txt").write_text("x\n", encoding="utf-8")
        return plain

    def task_row(
        self,
        task_id="3",
        type_="实现",
        milestone="M1",
        deliverable="交付物",
        deps="—",
        acceptance="ACC-G1",
        schedule="进行中",
        verification="未验",
        evidence="EV-1",
        blocked="—",
    ):
        return [
            task_id,
            type_,
            milestone,
            deliverable,
            deps,
            acceptance,
            schedule,
            verification,
            evidence,
            blocked,
        ]

    def write_tasks(self, rows, with_markers=True) -> Path:
        header = (
            "| 任务号 | 类型 | 里程碑 | 交付物 | 依赖 | 验收ID | 安排 | 核验 | 证据ID | 阻塞ID |"
        )
        sep = "|" + "---|" * 10
        lines = ["# M1-任务表", "", header, sep]
        for row in rows:
            lines.append("| " + " | ".join(row) + " |")
        if with_markers:
            lines += ["", doc_status.STATUS_START, "（占位）", doc_status.STATUS_END]
        path = self.docs / "M1-任务表.md"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def make_evidence(
        self,
        ev_id="EV-1",
        *,
        task_id="3",
        kind="code",
        commit=None,
        baseline=None,
        checks=None,
        exit_code=0,
        artifacts=None,
        ev_dir=None,
        drop_keys=(),
    ):
        """写出一个证据包，返回 (package_dir, manifest)。"""
        ev_dir = ev_dir or (self.tmp / "evidence")
        pkg = ev_dir / ev_id
        pkg.mkdir(parents=True, exist_ok=True)
        spec = artifacts if artifacts is not None else {"logs/run.txt": "raw log\n"}
        entries = []
        for rel, content in spec.items():
            if isinstance(content, tuple):
                data, override = content
            else:
                data, override = content, None
            data_bytes = data.encode("utf-8") if isinstance(data, str) else data
            file_path = pkg / rel
            file_path.parent.mkdir(parents=True, exist_ok=True)
            file_path.write_bytes(data_bytes)
            digest = override if override is not None else hashlib.sha256(data_bytes).hexdigest()
            entries.append({"path": rel, "sha256": digest})
        manifest = {
            "task_id": task_id,
            "kind": kind,
            "commit": commit,
            "docs_baseline": baseline,
            "checks": checks if checks is not None else [{"id": "ACC-G1", "result": "pass"}],
            "exit_code": exit_code,
            "artifacts": entries,
        }
        for key in drop_keys:
            manifest.pop(key, None)
        (pkg / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return pkg, manifest

    def write_manifest(self, ev_id, manifest, ev_dir=None) -> Path:
        ev_dir = ev_dir or (self.tmp / "evidence")
        pkg = ev_dir / ev_id
        pkg.mkdir(parents=True, exist_ok=True)
        (pkg / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return pkg

    # -- 运行 ---------------------------------------------------------------
    def run_main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = doc_status.main(argv)
        return code, out.getvalue(), err.getvalue()

    def run_check(self, tasks_path, repo, ev_dir=None, out=None, write_status=False):
        ev_dir = ev_dir or (self.tmp / "evidence")
        out = out or (self.tmp / "out" / "check.json")
        out.parent.mkdir(parents=True, exist_ok=True)
        argv = [
            "check",
            "--repo",
            str(repo),
            "--docs",
            str(self.docs),
            "--tasks",
            str(tasks_path),
            "--evidence-dir",
            str(ev_dir),
            "--out",
            str(out),
        ]
        if write_status:
            argv.append("--write-status")
        code, stdout, stderr = self.run_main(argv)
        report = json.loads(out.read_text(encoding="utf-8")) if out.is_file() else None
        return code, report, stdout, stderr

    def verification_of(self, report, task_id):
        for task in report["tasks"]:
            if task["task_id"] == task_id:
                return task["verification"], task
        raise AssertionError(f"报告中没有任务 {task_id}")

    # -- live docs（lint 夹具） --------------------------------------------
    def make_live_docs(self):
        for name in doc_status.LIVE_DOCS:
            if name == "M1-任务表.md":
                continue
            (self.docs / name).write_text(f"# {name}\n\n内容\n", encoding="utf-8")


# ==========================================================================
# snapshot
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestSnapshot(Base):
    def test_records_head_clean_baseline(self):
        repo, head = self.make_repo()
        out = self.tmp / "out" / "snapshot.json"
        code, stdout, stderr = self.run_main(
            ["snapshot", "--repo", str(repo), "--docs", str(self.docs), "--out", str(out)]
        )
        self.assertEqual(code, 0, stderr)
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(report["repo"]["observable"])
        self.assertEqual(report["repo"]["head"], head)
        self.assertFalse(report["repo"]["dirty"])
        self.assertEqual(report["docs"]["baseline_id"], self.baseline_id())
        self.assertTrue(report["docs"]["complete"])
        self.assertEqual(report["docs"]["present_count"], 8)
        self.assertIn("generated_at", report)

    def test_detects_untracked_file(self):
        repo, _ = self.make_repo()
        (repo / "untracked.txt").write_text("new\n", encoding="utf-8")
        out = self.tmp / "out" / "snapshot.json"
        code, _, _ = self.run_main(
            ["snapshot", "--repo", str(repo), "--docs", str(self.docs), "--out", str(out)]
        )
        self.assertEqual(code, 0)
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(report["repo"]["dirty"])
        self.assertGreaterEqual(report["repo"]["dirty_count"], 1)

    def test_non_git_dir_is_unobservable(self):
        plain = self.make_plain_dir()
        out = self.tmp / "out" / "snapshot.json"
        code, _, _ = self.run_main(
            ["snapshot", "--repo", str(plain), "--docs", str(self.docs), "--out", str(out)]
        )
        self.assertEqual(code, 0)
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertFalse(report["repo"]["observable"])
        self.assertIsNotNone(report["repo"]["error"])

    def test_out_under_repo_rejected(self):
        repo, _ = self.make_repo()
        out = repo / "snapshot.json"
        code, _, stderr = self.run_main(
            ["snapshot", "--repo", str(repo), "--docs", str(self.docs), "--out", str(out)]
        )
        self.assertEqual(code, 2)
        self.assertFalse(out.exists())
        self.assertNotIn("Traceback", stderr)

    def test_missing_baseline_file_marks_incomplete(self):
        repo, _ = self.make_repo()
        (self.docs / doc_status.BASELINE_FILES[0]).unlink()
        out = self.tmp / "out" / "snapshot.json"
        code, _, _ = self.run_main(
            ["snapshot", "--repo", str(repo), "--docs", str(self.docs), "--out", str(out)]
        )
        self.assertEqual(code, 0)
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertFalse(report["docs"]["complete"])
        self.assertEqual(report["docs"]["present_count"], 7)
        self.assertIn(doc_status.BASELINE_FILES[0], report["docs"]["missing"])


# ==========================================================================
# check：正例 / 时效性
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestCheckPositive(Base):
    def test_matching_evidence_passes(self):
        repo, head = self.make_repo()
        baseline = self.baseline_id()
        self.make_evidence(commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, stderr = self.run_check(tasks, repo)
        self.assertEqual(code, 0, stderr)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "通过")
        self.assertEqual(task["binding"], "code")
        self.assertFalse(report["delivery"]["verified"])
        self.assertEqual(report["delivery"]["state"], "未核验")
        self.assertIn("统计", report["statistics_line"])

    def test_baseline_mapping_form_matches(self):
        repo, head = self.make_repo()
        baseline_map = {
            name: doc_status.compute_baseline(self.docs)["files"][name]["sha256"]
            for name in doc_status.BASELINE_FILES
        }
        self.make_evidence(commit=head, baseline=baseline_map)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 0)
        self.assertEqual(self.verification_of(report, "3")[0], "通过")


@unittest.skipUnless(GIT, "需要 git")
class TestCheckStaleness(Base):
    def test_reset_to_old_commit_is_stale(self):
        repo, head = self.make_repo()
        self.make_evidence(commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row()])
        git_run(["reset", "--hard", "HEAD~1"], repo)
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "待重验")
        self.assertIn("不一致", task["reason_text"])

    def test_ancestor_commit_is_not_accepted(self):
        repo, head = self.make_repo()
        first = git_run(["rev-parse", "HEAD~1"], repo).strip()
        self.assertNotEqual(first, head)
        self.make_evidence(commit=first, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "待重验")
        self.assertIn("祖先", task["reason_text"])

    def test_dirty_worktree_is_stale(self):
        repo, head = self.make_repo()
        self.make_evidence(commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row()])
        (repo / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "待重验")
        self.assertIn("工作树", task["reason_text"])

    def test_docs_baseline_change_is_stale(self):
        repo, head = self.make_repo()
        self.make_evidence(commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row()])
        (self.docs / "03-M1-SPEC.md").write_text("# 新内容\n", encoding="utf-8")
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "待重验")
        self.assertIn("文档基线", task["reason_text"])

    def test_missing_baseline_file_fails(self):
        repo, head = self.make_repo()
        self.make_evidence(commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row()])
        (self.docs / doc_status.BASELINE_FILES[0]).unlink()
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("规范基线不完整", task["reason_text"])


# ==========================================================================
# check：证据完整性
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestCheckEvidenceIntegrity(Base):
    def _setup(self):
        repo, head = self.make_repo()
        return repo, head, self.baseline_id()

    def test_no_evidence_id_is_unverified(self):
        repo, _, _ = self._setup()
        tasks = self.write_tasks([self.task_row(evidence="—")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "未验")

    def test_declared_evidence_missing_fails(self):
        repo, _, _ = self._setup()
        tasks = self.write_tasks([self.task_row(evidence="EV-404")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("无法定位", task["reason_text"])

    def test_handwritten_verification_is_ignored(self):
        repo, _, _ = self._setup()
        tasks = self.write_tasks([self.task_row(evidence="—", verification="通过")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "未验")
        self.assertEqual(task["declared_verification"], "通过")

    def test_missing_acceptance_item_fails(self):
        repo, head, baseline = self._setup()
        self.make_evidence(
            commit=head,
            baseline=baseline,
            checks=[{"id": "ACC-G2", "result": "pass"}],
        )
        tasks = self.write_tasks([self.task_row(acceptance="ACC-G1")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("缺少验收项 ACC-G1", task["reason_text"])

    def test_failed_acceptance_fails(self):
        repo, head, baseline = self._setup()
        self.make_evidence(
            commit=head,
            baseline=baseline,
            checks=[{"id": "ACC-G1", "result": "fail"}],
        )
        tasks = self.write_tasks([self.task_row(acceptance="ACC-G1")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")

    def test_nonzero_exit_code_fails(self):
        repo, head, baseline = self._setup()
        self.make_evidence(commit=head, baseline=baseline, exit_code=1)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("exit_code", task["reason_text"])

    def test_missing_exit_code_fails(self):
        repo, head, baseline = self._setup()
        self.make_evidence(commit=head, baseline=baseline, drop_keys=("exit_code",))
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")

    def test_missing_task_id_fails(self):
        repo, head, baseline = self._setup()
        self.make_evidence(commit=head, baseline=baseline, drop_keys=("task_id",))
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")

    def test_task_id_mismatch_fails(self):
        repo, head, baseline = self._setup()
        self.make_evidence(task_id="99", commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")

    def test_missing_artifact_fails(self):
        repo, head, baseline = self._setup()
        pkg, manifest = self.make_evidence(commit=head, baseline=baseline)
        (pkg / "logs" / "run.txt").unlink()
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("不存在", task["reason_text"])

    def test_artifact_digest_mismatch_fails(self):
        repo, head, baseline = self._setup()
        self.make_evidence(
            commit=head,
            baseline=baseline,
            artifacts={"logs/run.txt": ("raw log\n", "0" * 64)},
        )
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("摘要不符", task["reason_text"])

    def test_malformed_manifest_fails(self):
        repo, head, baseline = self._setup()
        pkg = self.tmp / "evidence" / "EV-1"
        pkg.mkdir(parents=True)
        (pkg / "manifest.json").write_text("{ not json", encoding="utf-8")
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")

    def test_evidence_lost_after_creation_fails(self):
        repo, head, baseline = self._setup()
        pkg, _ = self.make_evidence(commit=head, baseline=baseline)
        shutil.rmtree(pkg)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")


# ==========================================================================
# check：路径逃逸
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestPathEscape(Base):
    def _setup(self):
        repo, head = self.make_repo()
        return repo, head, self.baseline_id()

    def _manifest(self, head, baseline, artifacts):
        return {
            "task_id": "3",
            "kind": "code",
            "commit": head,
            "docs_baseline": baseline,
            "checks": [{"id": "ACC-G1", "result": "pass"}],
            "exit_code": 0,
            "artifacts": artifacts,
        }

    def test_absolute_artifact_path_rejected(self):
        repo, head, baseline = self._setup()
        manifest = self._manifest(
            head, baseline, [{"path": "/etc/passwd", "sha256": "0" * 64}]
        )
        self.write_manifest("EV-1", manifest)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("逃逸", task["reason_text"])

    def test_windows_drive_artifact_path_rejected(self):
        repo, head, baseline = self._setup()
        manifest = self._manifest(
            head, baseline, [{"path": "C:\\Windows\\win.ini", "sha256": "0" * 64}]
        )
        self.write_manifest("EV-1", manifest)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")

    def test_parent_escape_artifact_path_rejected(self):
        repo, head, baseline = self._setup()
        (self.tmp / "outside.txt").write_text("outside\n", encoding="utf-8")
        manifest = self._manifest(
            head,
            baseline,
            [{"path": "../outside.txt", "sha256": sha256_text("outside\n")}],
        )
        self.write_manifest("EV-1", manifest)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("逃逸", task["reason_text"])

    def test_evidence_id_escape_rejected(self):
        repo, head, baseline = self._setup()
        self.make_evidence(commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row(evidence="..\\..\\evil")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("非法", task["reason_text"])

    def test_artifact_symlink_escape_rejected(self):
        repo, head, baseline = self._setup()
        outside = self.tmp / "outside.txt"
        outside.write_text("secret\n", encoding="utf-8")
        pkg = self.tmp / "evidence" / "EV-1"
        pkg.mkdir(parents=True)
        link = pkg / "link.txt"
        try:
            os.symlink(outside, link)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"当前环境无法创建 symlink：{exc}")
        manifest = self._manifest(
            head,
            baseline,
            [{"path": "link.txt", "sha256": sha256_text("secret\n")}],
        )
        self.write_manifest("EV-1", manifest)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("逃逸", task["reason_text"])

    def test_symlinked_evidence_package_is_ignored(self):
        repo, head, baseline = self._setup()
        outside_pkg = self.tmp / "outside_pkg"
        outside_pkg.mkdir()
        (outside_pkg / "raw.txt").write_text("x", encoding="utf-8")
        manifest = self._manifest(
            head, baseline, [{"path": "raw.txt", "sha256": sha256_text("x")}]
        )
        (outside_pkg / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        ev_dir = self.tmp / "evidence"
        ev_dir.mkdir(exist_ok=True)
        try:
            os.symlink(outside_pkg, ev_dir / "EV-1")
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"当前环境无法创建 symlink：{exc}")
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")


# ==========================================================================
# check：决策／文档任务不受代码变动影响
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestDocBinding(Base):
    def test_decision_task_passes_without_repo(self):
        plain = self.make_plain_dir()
        baseline = self.baseline_id()
        self.make_evidence(kind="decision", commit=None, baseline=baseline)
        tasks = self.write_tasks(
            [self.task_row(type_="决策", acceptance="ACC-G1", evidence="EV-1")]
        )
        code, report, _, stderr = self.run_check(tasks, plain)
        self.assertEqual(code, 0, stderr)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "通过")
        self.assertEqual(task["binding"], "doc")

    def test_decision_task_survives_code_reset(self):
        repo, head = self.make_repo()
        baseline = self.baseline_id()
        self.make_evidence(kind="decision", commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row(type_="决策")])
        git_run(["reset", "--hard", "HEAD~1"], repo)
        (repo / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 0)
        self.assertEqual(self.verification_of(report, "3")[0], "通过")

    def test_doc_task_baseline_change_is_stale(self):
        repo, head = self.make_repo()
        self.make_evidence(kind="doc", commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row(type_="文档")])
        (self.docs / "06-M1-数据契约.md").write_text("# 改了\n", encoding="utf-8")
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "待重验")

    def test_doc_task_with_code_kind_fails(self):
        repo, head = self.make_repo()
        self.make_evidence(kind="code", commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row(type_="文档")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "失败")
        self.assertIn("kind", task["reason_text"])

    def test_code_task_with_doc_kind_fails(self):
        repo, head = self.make_repo()
        self.make_evidence(kind="decision", commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row(type_="实现")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "失败")

    def test_decision_task_no_evidence_is_unverified(self):
        repo, _ = self.make_repo()
        tasks = self.write_tasks([self.task_row(type_="决策", evidence="—")])
        code, report, _, _ = self.run_check(tasks, repo)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "未验")


# ==========================================================================
# check：仓库不可观测
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestUnobservableRepo(Base):
    def test_missing_repo_is_unobservable(self):
        baseline = self.baseline_id()
        self.make_evidence(commit="a" * 40, baseline=baseline)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, self.tmp / "no-such-repo")
        self.assertEqual(code, 1)
        verification, task = self.verification_of(report, "3")
        self.assertEqual(verification, "不可观测")
        self.assertIn("不可访问", task["reason_text"])

    def test_non_git_dir_is_unobservable(self):
        plain = self.make_plain_dir()
        baseline = self.baseline_id()
        self.make_evidence(commit="a" * 40, baseline=baseline)
        tasks = self.write_tasks([self.task_row()])
        code, report, _, _ = self.run_check(tasks, plain)
        self.assertEqual(code, 1)
        self.assertEqual(self.verification_of(report, "3")[0], "不可观测")


# ==========================================================================
# check：--write-status
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestWriteStatus(Base):
    def test_replaces_only_status_region(self):
        repo, head = self.make_repo()
        baseline = self.baseline_id()
        self.make_evidence(commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row()])
        original = tasks.read_text(encoding="utf-8")
        self.assertIn("# M1-任务表", original)
        code, report, _, _ = self.run_check(tasks, repo, write_status=True)
        self.assertEqual(code, 0)
        updated = tasks.read_text(encoding="utf-8")
        self.assertGreater(len(updated), len(original))
        self.assertNotIn("（占位）", updated)
        self.assertIn("生成时间", updated)
        self.assertIn(head, updated)
        self.assertIn(baseline, updated)
        self.assertIn("| 任务号 | 类型 | 里程碑 | 安排 | 核验 | 证据ID | 说明 |", updated)
        self.assertIn("| 3 | 实现 | M1 | 进行中 | 通过 |", updated)
        self.assertIn("**统计**：共 1 项", updated)
        self.assertTrue(report["status_written"])
        # 区域外内容原样保留。
        self.assertTrue(updated.startswith("# M1-任务表"))
        self.assertEqual(updated.count("**统计**"), 1)

    def test_missing_markers_fails(self):
        repo, head = self.make_repo()
        baseline = self.baseline_id()
        self.make_evidence(commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row()], with_markers=False)
        code, _, _, stderr = self.run_check(tasks, repo, write_status=True)
        self.assertEqual(code, 2)
        self.assertIn("status", stderr)
        self.assertNotIn("Traceback", stderr)

    def test_duplicate_markers_fail(self):
        repo, head = self.make_repo()
        baseline = self.baseline_id()
        self.make_evidence(commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row()])
        text = tasks.read_text(encoding="utf-8")
        text += f"\n{doc_status.STATUS_START}\n多余\n{doc_status.STATUS_END}\n"
        tasks.write_text(text, encoding="utf-8")
        code, _, _, stderr = self.run_check(tasks, repo, write_status=True)
        self.assertEqual(code, 2)
        self.assertIn("多个", stderr)

    def test_second_run_is_idempotent(self):
        repo, head = self.make_repo()
        baseline = self.baseline_id()
        self.make_evidence(commit=head, baseline=baseline)
        tasks = self.write_tasks([self.task_row()])
        self.run_check(tasks, repo, write_status=True)
        first = tasks.read_text(encoding="utf-8")
        self.run_check(tasks, repo, write_status=True)
        second = tasks.read_text(encoding="utf-8")

        def outside(text):
            match = doc_status.STATUS_REGION_RE.search(text)
            return text[: match.start()], text[match.end() :]

        # 状态区域外的正文必须逐字节稳定；区域内的生成时间允许不同。
        self.assertEqual(outside(first), outside(second))
        self.assertEqual(first.count("**统计**"), 1)
        self.assertEqual(second.count("**统计**"), 1)


# ==========================================================================
# lint
# ==========================================================================


class TestLint(Base):
    def run_lint(self, extra_args=None):
        argv = ["lint", "--docs", str(self.docs)]
        if extra_args:
            argv += extra_args
        return self.run_main(argv)

    def test_clean_passes(self):
        self.make_live_docs()
        self.write_tasks([self.task_row(task_id="3", deps="—")])
        (self.docs / "04-M1-架构与计划.md").write_text(
            "# 架构\n\n^dec-t2 锁协议\n", encoding="utf-8"
        )
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 0, stdout)
        self.assertIn("[OK]", stdout)

    def test_oversize_doc_fails(self):
        self.make_live_docs()
        self.write_tasks([self.task_row()])
        (self.docs / "10-变更记录.md").write_text("x" * 20001, encoding="utf-8")
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 1)
        self.assertIn("超过预算", stdout)

    def test_adr_within_relaxed_budget_prints_ok(self):
        """打印与判定使用同一生效上限：ADR 在 20000～32000 区间应判 OK 并打 [OK]（limit=32000）。"""
        self.make_live_docs()
        self.write_tasks([self.task_row()])
        (self.docs / "ADR-0001-项目启动与技术栈裁决.md").write_text(
            "x" * 25000, encoding="utf-8"
        )
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 0, stdout)
        self.assertIn("[OK] ADR-0001-项目启动与技术栈裁决.md：25000 / 32000 bytes", stdout)
        self.assertNotIn("[FAIL] ADR-0001", stdout)

    def test_duplicate_block_id_fails(self):
        self.make_live_docs()
        self.write_tasks([self.task_row()])
        (self.docs / "04-M1-架构与计划.md").write_text(
            "# 架构\n\n^acc-g1 第一处\n", encoding="utf-8"
        )
        (self.docs / "05-M1-接口契约.md").write_text(
            "# 接口\n\n^acc-g1 第二处\n", encoding="utf-8"
        )
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 1)
        self.assertIn("acc-g1", stdout)
        self.assertIn("重复定义", stdout)

    def test_block_reference_is_not_definition(self):
        self.make_live_docs()
        self.write_tasks([self.task_row()])
        (self.docs / "ADR-0001-项目启动与技术栈裁决.md").write_text(
            "# ADR\n\n^dec-t2 定义\n", encoding="utf-8"
        )
        (self.docs / "04-M1-架构与计划.md").write_text(
            "# 架构\n\n引用 [[ADR-0001-项目启动与技术栈裁决#^dec-t2]]\n", encoding="utf-8"
        )
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 0, stdout)

    def test_dependency_cycle_fails(self):
        self.make_live_docs()
        self.write_tasks(
            [
                self.task_row(task_id="1", deps="2", evidence="—"),
                self.task_row(task_id="2", deps="1", evidence="—"),
            ]
        )
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 1)
        self.assertIn("成环", stdout)

    def test_missing_live_doc_fails(self):
        self.make_live_docs()
        self.write_tasks([self.task_row()])
        (self.docs / "11-术语索引.md").unlink()
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 1)
        self.assertIn("缺少活文档", stdout)

    def test_diamond_dependency_is_not_a_cycle(self):
        self.make_live_docs()
        self.write_tasks(
            [
                self.task_row(task_id="1", deps="2、3", evidence="—"),
                self.task_row(task_id="2", deps="4", evidence="—"),
                self.task_row(task_id="3", deps="4", evidence="—"),
                self.task_row(task_id="4", deps="—", evidence="—"),
            ]
        )
        code, stdout, _ = self.run_lint()
        self.assertEqual(code, 0, stdout)

    def test_json_output(self):
        self.make_live_docs()
        self.write_tasks([self.task_row()])
        out = self.tmp / "out" / "lint.json"
        code, _, _ = self.run_lint(["--json", "--out", str(out)])
        self.assertEqual(code, 0)
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(report["passed"])
        self.assertEqual(len(report["sizes"]), 12)


# ==========================================================================
# 干净失败
# ==========================================================================


@unittest.skipUnless(GIT, "需要 git")
class TestCleanFailures(Base):
    def test_missing_tasks_file_exit_2(self):
        repo, head = self.make_repo()
        code, _, err = self.run_main(
            [
                "check",
                "--repo",
                str(repo),
                "--docs",
                str(self.docs),
                "--tasks",
                str(self.tmp / "missing.md"),
                "--evidence-dir",
                str(self.tmp / "evidence"),
                "--out",
                str(self.tmp / "out" / "r.json"),
            ]
        )
        self.assertEqual(code, 2)
        self.assertIn("错误", err)
        self.assertNotIn("Traceback", err)

    def test_bad_task_header_exit_2(self):
        repo, _ = self.make_repo()
        tasks = self.docs / "M1-任务表.md"
        tasks.write_text("# 没有任务表\n", encoding="utf-8")
        code, _, _, err = self.run_check(tasks, repo)
        self.assertEqual(code, 2)
        self.assertIn("错误", err)
        self.assertNotIn("Traceback", err)

    def test_check_out_under_repo_exit_2(self):
        repo, head = self.make_repo()
        self.make_evidence(commit=head, baseline=self.baseline_id())
        tasks = self.write_tasks([self.task_row()])
        code, _, err = self.run_main(
            [
                "check",
                "--repo",
                str(repo),
                "--docs",
                str(self.docs),
                "--tasks",
                str(tasks),
                "--evidence-dir",
                str(self.tmp / "evidence"),
                "--out",
                str(repo / "report.json"),
            ]
        )
        self.assertEqual(code, 2)
        self.assertIn("--out", err)

    def test_lint_missing_docs_dir_exit_2(self):
        code, _, err = self.run_main(["lint", "--docs", str(self.tmp / "nope")])
        self.assertEqual(code, 2)
        self.assertNotIn("Traceback", err)

    def test_subprocess_no_traceback(self):
        script = Path(doc_status.__file__).resolve()
        proc = subprocess.run(
            [
                sys.executable,
                str(script),
                "check",
                "--repo",
                str(self.tmp / "repo"),
                "--docs",
                str(self.docs),
                "--tasks",
                str(self.tmp / "missing.md"),
                "--evidence-dir",
                str(self.tmp / "evidence"),
                "--out",
                str(self.tmp / "out" / "r.json"),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self.assertEqual(proc.returncode, 2)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertIn("错误", proc.stderr)

    def test_unknown_subcommand_exits_2(self):
        with self.assertRaises(SystemExit) as ctx:
            with contextlib.redirect_stderr(io.StringIO()):
                doc_status.main(["nope"])
        self.assertEqual(ctx.exception.code, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
