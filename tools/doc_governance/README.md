# 仓鼠文档体系与状态核验工具（doc_governance）

本目录是「用户授权文档体系和状态核验工具」的交付物：一个只依赖 **Python 3.12 标准库**（git 通过 CLI 子进程调用）的单文件工具 `doc_status.py`、真实运行测试 `test_doc_status.py`，以及本说明。

目标：把「状态是计算结果」落成可执行程序——读取代码仓、文档规范基线和证据清单，推导任务表的**核验**列，并刷新任务表中 `<!-- status:start -->` 与 `<!-- status:end -->` 之间的唯一状态区域。工具**不改代码仓、不改知识库正文**。

---

## 1. 文件与运行环境

| 文件 | 作用 |
|---|---|
| `doc_status.py` | 工具本体，CLI：`snapshot` / `check` / `lint` |
| `test_doc_status.py` | `unittest` 测试（真实临时 git 仓；57 例） |
| `README.md` | 本文档 |

- Python 3.12（测试于 3.12.10 通过）。
- 只用标准库：`argparse`、`hashlib`、`json`、`re`、`shutil`、`subprocess`、`pathlib`、`datetime` 等。
- 需要本机可执行的 `git`（只读调用）。
- 运行测试：在 `doc_governance/` 目录内执行

  ```text
  python -m unittest -v test_doc_status
  ```

  测试临时文件默认落在 `./.test-tmp/`（可用环境变量 `DOC_STATUS_TEST_TMP` 改到别处）。

---

## 2. 命令行

### 2.1 snapshot

```text
python doc_status.py snapshot --repo <代码仓> --docs <活文档目录> --out <快照.json>
```

采集并写出：`generated_at`、仓库 `HEAD`（完整 40 位）、分支、工作树是否脏（**含未跟踪文件**，`git status --porcelain=v1 --untracked-files=all`）、**规范基线**（固定 8 个文件的 SHA-256 与聚合 `baseline_id`）、可观测性。

仓库不可访问（路径不存在、非 git 工作树、无 HEAD、无 git）时 `repo.observable=false` 并记录 `error`，快照照常写出，退出码仍为 0——不可观测是**数据**，不是命令失败。

### 2.2 check

```text
python doc_status.py check --repo <代码仓> --docs <活文档目录> \
  --tasks <任务表.md> --evidence-dir <证据根目录> --out <核验报告.json> [--write-status]
```

输出每个任务的推导核验状态、原因、证据明细、统计行与「远端交付」口径；退出码：全部 `通过` 为 0，否则为 1。

- `--write-status` 时，只替换任务表中 `<!-- status:start -->` 与 `<!-- status:end -->` 之间的区域；区域外正文逐字节保留。缺少标记或存在多个标记时干净失败（退出码 2），不写任何内容。
- 生成的区域包含：生成时间、代码仓 HEAD、工作树、规范基线、**每任务核验结果**、以及**唯一一行统计**。
- 核验列读取的是**计划字段**：「核验」列的手填值只作为 `declared_verification` 记录，**不参与推导**。

### 2.3 lint

```text
python doc_status.py lint --docs <活文档目录> [--tasks <任务表.md>] [--out <lint.json>] [--json]
```

`--tasks` 缺省为 `<docs>/M1-任务表.md`。退出码：无问题 0，有问题 1。

### 2.4 退出码约定

| 码 | 含义 |
|---:|---|
| 0 | 成功（snapshot 写出；check 全部通过；lint 无问题） |
| 1 | 工具正常完成但判定未过（check 有非 `通过` 任务；lint 有问题） |
| 2 | 输入/用法/IO 错误（缺参数、文件不存在、`--out` 在被核验仓内、表头不合规、缺少 status 标记等） |
| 130 | 用户中断 |

所有可预期错误都以 `错误：<中文说明>` 打印到 stderr，绝不输出 traceback。确需堆栈时可加全局 `--debug`。

---

## 3. 规范基线（固定 8 个文件）

`--docs` 目录下必须存在下列 8 个文件，**缺任一个 `complete=false`，任何任务都不能通过**：

```text
01-开发宪章与治理.md
ADR-0001-项目启动与技术栈裁决.md
03-M1-SPEC.md
04-M1-架构与计划.md
05-M1-接口契约.md
06-M1-数据契约.md
07-M1-运行手册.md
08-M1-验收规范.md
```

`baseline_id = "sha256:" + sha256(拼接每个文件的 "文件名\n文件SHA-256\n")`，按上表固定顺序；缺失文件以 `MISSING` 占位。证据清单里的 `docs_baseline` 支持写成该 `baseline_id` 字符串、裸 64 位十六进制，或「文件名 → SHA-256」映射（工具会按同一算法归一化后比较）。

---

## 4. 任务表格式

表头固定 10 列（名称必须齐全，顺序可变；每个数据行必须与表头等宽）：

```text
| 任务号 | 类型 | 里程碑 | 交付物 | 依赖 | 验收ID | 安排 | 核验 | 证据ID | 阻塞ID |
```

- **类型**：全部为 `决策` 或 `文档` 时，任务**绑定文档证据**；否则绑定代码证据。类型可用 `、，,/;` 分隔多值（例如 `决策/文档`）。
- **依赖 / 验收ID / 证据ID**：用 `、，,/;` 或空白分隔；`—`、`-`、`无`、`N/A` 表示空。
- **验收ID**：`check` 要求证据清单覆盖其中每一项。
- **核验**：计划字段，不参与推导；`check` 只在报告的 `declared_verification` 中原样记录。
- 状态区域若紧跟在任务表之后，因列数不同不会混入任务行。

---

## 5. 证据 manifest 格式

证据根目录下每个证据 ID 对应一个子目录，内含 `manifest.json`（也支持 `证据根/<证据ID>.json`）：

```text
<证据根>/
└── EV-2026-09-19-01/
    ├── manifest.json
    └── logs/run.txt          ← artifacts 里的相对路径，相对本证据包根
```

```json
{
  "task_id": "3",
  "kind": "code",
  "commit": "ea0aaeea76f10218f7018b18d57bfeea0a17b5d9",
  "docs_baseline": "sha256:....",
  "checks": [
    { "id": "ACC-G1", "result": "pass" },
    { "id": "ACC-G2", "result": "fail" }
  ],
  "exit_code": 0,
  "artifacts": [
    { "path": "logs/run.txt", "sha256": "...." }
  ]
}
```

| 字段 | 要求 |
|---|---|
| `task_id` | 必填，必须与任务号一致 |
| `kind` | 必填；`code/实现/验证` 与 `doc/decision/文档/决策` 不得跨类冒充 |
| `commit` | 代码任务必填，完整 40 位（或 64 位）十六进制，须**精准等于当前 HEAD** |
| `docs_baseline` | 必填，须解析后等于当前 `baseline_id` |
| `checks` / `acceptance` / `results` | 逐项验收结果；`id` + `result`；`result` 取值 `pass/通过/true` 与 `fail/失败/false`，其余记为不可判定 |
| `exit_code` | 必填整数，**只有 0 通过**；缺省、非整数或非 0 都不通过 |
| `artifacts` | 必填非空列表；每项含 `path`（相对证据包根）与 `sha256` |

### 证据路径安全

- 证据 ID 必须是单个路径分量：拒绝绝对路径、`..`、`/`、`\`、盘符、UNC。
- artifacts 的 `path` 必须是相对路径：拒绝绝对路径、盘符、任何 `..` 分量。
- 解析后（`Path.resolve()`，会展开 symlink）必须落在证据根之内，否则按「路径逃逸」失败。
- 证据根中 symlink 指向根外的目录/文件不会被登记，等同于证据缺失。

---

## 6. 核验状态推导规则

受控状态：`通过`、`失败`、`待重验`、`未验`、`不可观测`。

| 条件 | 结果 |
|---|---|
| 代码绑定任务且**仓库不可访问** | `不可观测` |
| 任务表**未登记证据ID** | `未验` |
| 有证据ID但**清单无法定位**（丢失）、JSON 非法、缺少 `task_id`/`kind` | `失败` |
| 存在失败证据（`exit_code≠0`、任一必需验收项失败或结果不可判定、缺少必需验收项、工件缺失或摘要不符、路径逃逸、kind 跨类） | `失败` |
| 证据本身有效，但工作树脏、commit ≠ 当前 HEAD（**祖先可达不继承结论**）、或规范基线已变 | `待重验` |
| 精准 HEAD、工作区干净、基线匹配、全部所需验收通过、原始证据存在且摘要正确 | `通过` |

补充口径：

- **决策/文档任务绑定文档证据**，只比较规范基线与验收结果，不看代码 HEAD 与工作树；因此代码回滚不会让决策结项失效。
- 「当前通过」与「已交付」分开：报告固定输出 `delivery.state = 未核验`，并说明未查询远端分支/tag。远端交付需另行核验。
- 缺项不算通过：manifest 没有覆盖某个必需验收 ID 时按 `失败` 处理。
- `安排（待办/进行中/阻塞/后置）` 与 `核验` 是两组字段，互不覆盖。

---

## 7. lint 的检查范围与边界

### 已检查（3 类）

1. **篇幅预算**：根目录 12 份活文档存在，且每份 UTF-8 文件字节数不超各自预算：默认 `<= 20000`；例外 `ADR-0001-项目启动与技术栈裁决.md <= 32000`（用户 2026-09-19 授权，见 10-变更记录.md 追加批次 ADR-BUDGET-2026-09-19）。

   ```text
   仓鼠项目-总览.md、01-开发宪章与治理.md、ADR-0001-项目启动与技术栈裁决.md、
   03-M1-SPEC.md、04-M1-架构与计划.md、05-M1-接口契约.md、06-M1-数据契约.md、
   07-M1-运行手册.md、08-M1-验收规范.md、M1-任务表.md、10-变更记录.md、11-术语索引.md
   ```

2. **重复块 ID**：12 份活文档内 `^block-id` **定义**全局唯一；`[[文件#^id]]` 形式的**引用**不算定义。同一定义出现两次及以上即报错。
3. **任务依赖环**：解析任务表「依赖」列，只在**表内存在的任务号**之间建图并检测环；菱形依赖不算环。

### 明确不检查（需人工/语义审核）

lint 是机械检查，**以下均不在此工具范围内**，不要以 lint 通过代替它们：

- 文档之间的**语义冲突**、定稿权重复、需求与排除项矛盾；
- 双链/块引用**是否可解析**、归档旧引用是否有迁移映射（本工具只查块 ID 定义重复，不校验链接目标是否存在）；
- 设计正文是否出现「已实现/已完成」等实施断言、入口是否复制状态散文；
- 任务行 ID 是否被重排、人工总数与筛选统计是否一致、M2 任务是否混入 M1 分母；
- 八端点、错误码、`reason`、状态枚举、配置键与测试清单的一致性；
- 六项门槛/故障矩阵是否缺项；规范变更是否留批次记录；受保护 SQL 或归档原件摘要是否变化；
- 任何「实现是否正确」的判断。

这些按批准设计的机械检查清单与语义审核范围，另由专人按批次执行。

---

## 8. 部署到 cangshu/tools/doc_governance/

交付脚本本体在本目录；部署时**只复制文件**，不改 `cangshu` 的真实代码。目标路径 `cangshu/tools/doc_governance/`：

```powershell
# 1) 建目录（若已存在则复用）
New-Item -ItemType Directory -Force -Path E:\AgentWork\CangShu\cangshu\tools\doc_governance

# 2) 复制交付物
Copy-Item -Force `
  E:\AgentWork\CangShu\_doc-system-20260919\tools\output\doc_status.py, `
  E:\AgentWork\CangShu\_doc-system-20260919\tools\output\test_doc_status.py, `
  E:\AgentWork\CangShu\_doc-system-20260919\tools\output\README.md `
  -Destination E:\AgentWork\CangShu\cangshu\tools\doc_governance\

# 3) 在部署目录自测（不改代码仓，只读）
Set-Location E:\AgentWork\CangShu\cangshu\tools\doc_governance
python -m unittest -v test_doc_status
```

日常用法示例：

```powershell
# 采集快照（--out 必须在被核验仓之外）
python doc_status.py snapshot `
  --repo E:\AgentWork\CangShu\cangshu `
  --docs "E:\詩\Documents\NOTE\obsidian-kb-starter\00-Inbox\仓鼠" `
  --out E:\AgentWork\CangShu\_status\snapshot.json

# 核验并刷新任务表状态区域
python doc_status.py check `
  --repo E:\AgentWork\CangShu\cangshu `
  --docs "E:\詩\Documents\NOTE\obsidian-kb-starter\00-Inbox\仓鼠" `
  --tasks "E:\詩\Documents\NOTE\obsidian-kb-starter\00-Inbox\仓鼠\M1-任务表.md" `
  --evidence-dir "E:\詩\Documents\NOTE\obsidian-kb-starter\00-Inbox\仓鼠\归档\验收证据" `
  --out E:\AgentWork\CangShu\_status\check.json `
  --write-status

# 机械检查
python doc_status.py lint --docs "E:\詩\Documents\NOTE\obsidian-kb-starter\00-Inbox\仓鼠"
```

> `--out` 不得位于被核验的 `--repo` 之下（工具的硬约束），也不要把快照/报告写进知识库活文档区。

---

## 9. 测试覆盖

`test_doc_status.py` 用临时目录 + 真实 `git init` 仓验证：

- 正例（HEAD/工作树/基线/验收全匹配 → 通过）；
- `reset` 旧提交、`dirty` 工作区、规范基线变更 → 待重验；
- 祖先提交可达但非当前 HEAD → 待重验（不继承结论）；
- 证据丢失、工件缺失、摘要不符、`exit_code≠0`、缺 `exit_code`、缺 `task_id`、JSON 损坏 → 失败；
- 漏验收项、验收失败 → 失败；
- 无仓库 / 非 git 目录 → 不可观测；
- 绝对路径、盘符、`../`、证据 ID 逃逸、artifact symlink 逃逸、证据包 symlink 逃逸 → 拒绝并失败；
- 决策/文档任务在代码 reset + dirty 后仍通过，规范基线变更则转待重验；
- 手填「核验」不参与推导；
- `--write-status` 区域替换、区域外保留、缺标记/多标记干净失败、二次运行幂等；
- lint：预算超限、重复块 ID、块引用不算定义、依赖成环、菱形不算环、缺活文档；
- 各类错误输入退出码为 2 且 stderr 无 traceback。
