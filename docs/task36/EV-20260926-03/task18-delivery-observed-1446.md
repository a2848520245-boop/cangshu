# 任务 18 活文档单元交付回执（当前仅私仓）

观测时间：2026-09-26 06:43 UTC。任务 18 仍为「进行中／未验」，非 VM 完整任务计数保持 3/4。原仓提交 `24b76dc0f1742e1a0ac752700c3dcff9232e812c`，工作树干净；独立单分支 delivery clone 快进到同提交。此单元 11 文件：`.gitattributes`、Dockerfile/compose 注释、两处 Javadoc、任务 18 报告、四份规范原字节快照及快照索引。规范仍以 vault 为唯一入口，仓内文件是该次固定镜像。未运行构建、DB、Compose 或 VM。

- 私仓 `https://github.com/a2848520245-boop/cangshu-private-backup.git` 的 `refs/heads/delivery/m1-20260926` 只读读回 `24b76dc0f1742e1a0ac752700c3dcff9232e812c`；`refs/heads/project-docs` 为 `ba6c187c680c0b043273186974b1bfcaed1f1588`。manifest `scope=CODE_DOCS_ONLY`、`code_head` 同上、1038 来源文件。四份私仓代码树镜像的远端 API 原字节、vault 原件、私仓 project-docs 原字节及 manifest 长度/SHA 全部逐项一致：01 `b9f02304...`（13782B）、03 `9d00d954...`（15956B）、04 `6b94b533...`（14359B）、07 `18b00d5e...`（19987B）。完整哈希见 `docs/task18/active-doc-snapshots/README.md`。数据库 dump 与上传内容字节未备份。
- `sync-private-backup.py check` 返回 `READY_CODE_DOCS_ONLY`，扫描了已跟踪代码、可达历史和所选文档；随后 `sync` 返回 `CODE_DOCS_ONLY`。快照 `.gitattributes -text`，提交前以 Python 直接比较四个 `git show :path` 的二进制内容与 vault 和工作树，全部相等。`doc_status` 当前 HEAD 快照为干净、规范聚合基线 `sha256:2e7f355fa9b2d9a03c7f2ceb789d026f62a728357bebd3db072ae8af0fd23721`，见 `_status/task18-docs-20260926/delivery-head-snapshot.json`。
- 公开仓 `https://github.com/a2848520245-boop/cangshu.git` 的 `refs/heads/delivery/m1-20260926` 在推送前读回仍为 `7af8aee9f3d0f18d401a58e01fdac46ac035663f`。本次公开推送命令被自动审批拒绝，**未执行**。审批认为当前记录不足以证明用户授权导出这次具体 payload 至公开目的地，并明确要求不要绕过。主代理已就该明确范围向用户求证；收到可信明确回复前不重试。因此本单元不是双仓完成，不能记为完整第四项。
- 私仓新提交的自动 Actions [run 36224533048](https://github.com/a2848520245-boop/cangshu-private-backup/actions/runs/36224533048) 独立读回 `completed/success`，`pr-gate=success`、`real-e2e=skipped`；公开仓没有这次提交的 run。自动无 DB 门通过不等于正式 18.4 真实演示或 VM 验收通过，二者仍未运行。


