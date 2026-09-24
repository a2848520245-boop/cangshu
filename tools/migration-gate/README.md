# 迁移启动门（任务 30）工具入口

本目录只放说明；可执行脚本在仓库 `scripts/` 下，基线制品与运行期对照逻辑分别在
`src/main/resources/db/schema-manifest-v1.json` 与 `src/main/java/com/cangshu/migration/`。
启动只读核对的口径见 [[07-M1-运行手册]] §7（不符即退出码 3，无降级开关）。

## 1 重新生成 schema 基线清单（需要隔离 PG17 实例）

清单记录的是「某个 PG17 实例上由 `pg_get_constraintdef` / `pg_get_indexdef` 反编译出来的结构」，
因此生成源必须是**事前核验的可销毁 VM 中的合成 PG17 实例**；生成器会建库和删库，不能在宿主 C:／E: 演练。
不要把 `cangshu`、`cangshu_test`、`cangshu_m1demo`
这类既有库当生成源。生成器会自建随机命名的临时库、按序执行 `db/migration` 脚本、反编译后删除该库，
应用启动绝不会调用它。

```powershell
# 1) 构建打包 jar（生成器用 jar 内的类与依赖运行）
mvn -B -DskipTests package

# 2) 生成到 target/schema-manifest-generated.json 并与制品清单比较（默认不覆盖制品）
pwsh -File scripts/generate-schema-manifest.ps1 -DatabasePort <isolated-port>

# 3) 差异确认无误后落地到制品
pwsh -File scripts/generate-schema-manifest.ps1 -DatabasePort <isolated-port> -Apply
```

- 默认只生成到 `target/` 并打印两份 SHA-256：一致时退出码 0，不一致且未加 `-Apply` 时退出码 1。
- `-Build` 先跑一次 `mvn -B -DskipTests package`；`-PostgresBin` 覆盖 PG 客户端目录（默认 `E:\PostgreSQL\17\bin`）。
- 覆盖制品清单后，启动门基线与 `SchemaVerifierTests` 正例都要重新取证。

## 2 复现启动门取证（真实 PostgreSQL ＋ 打包 jar）

仅在事前完成隔离核验的可销毁 VM 中运行；先确认本机 PostgreSQL 17 合成实例的身份与非 5432 端口。

```powershell
pwsh -File scripts/verify-task30-migration-gate.ps1 -DatabasePort <isolated-port> -VmFixtureId <vm-fixture-id> -DisposableVmConfirmed
```

脚本生成唯一 `runId`，为正常启动和四类漂移分别创建全新的隔离库，并人工执行 `db/migration` 全部脚本。
正常启动须有 `CANGSHU|migration|verified`、健康检查 UP、退出码 0；台账缺行、删除 CHECK、删除索引、
未登记脚本四类漂移均须有对应拒绝日志和退出码 3。任一用例失败即停止后续用例。
原始日志和本轮库清单留在 `target/task30-migration-gate/<runId>/`；脚本不覆盖旧目录或已有库，也不自动删库。
核对证据后，仅在该可销毁 VM 内按清单人工清理本轮库。
凭据取自 `src/main/resources/application.yml` 的既有默认值，可被 `CANGSHU_DB_USER` / `CANGSHU_DB_PASSWORD` 覆盖。

## 3 人工迁移锁

人工迁移（开发态 `scripts/migrate.sh`／交付态 `scripts/compose-migrate.sh`）与 serve 遵循**同一锁协议**
（[[07-M1-运行手册]] §1 锁键纪律：「CLI、serve、人工迁移必须遵循同一锁协议；迁移操作需确保业务写者已退出」）。
协议实现在 `scripts/lib/migration-lock.sh` 一处，两个传输（本机 psql／容器内 psql）共用同一实现。

| 锁 | 键（07 §1 登记值） | 谁持有 | 迁移时怎么用 |
| --- | --- | --- | --- |
| 迁移锁 | `20260918` | 人工迁移会话 | 改动目标库**之前**取；取到才继续执行迁移脚本 |
| 写者锁 | `20260919` | serve／CLI 的 `WriterGate` | 迁移期间由迁移会话一并持有；取不到＝写者还在跑 |

**取得与释放时机**：一次迁移就是一条 psql 会话——先取迁移锁（键 20260918），再取写者锁（键 20260919），
两把都是 `pg_try_advisory_lock`（会话级、非阻塞，不等待）；两把都拿到后才按序执行 `db/migration/V*.sql`。
迁移脚本各自 `BEGIN/COMMIT`，DDL 与 `schema_version` 记账在同一事务里，因此**不用事务级锁**：
`pg_advisory_xact_lock` 会在 V1 提交那一刻释放，既盖不住后续脚本，也保不住「迁移期间持有写者锁」。
会话收尾显式释放两把锁并打印 `CANGSHU|migration|lock-released`；会话异常结束（报错、被强杀）时
由 PostgreSQL 随会话销毁自动释放，不留死锁。

**锁键是协议常量**：`cangshu.migration.lock-key`／`cangshu.writer.lock-key` 不支持普通环境变量或
运行配置覆盖（07 §1），`scripts/lib/migration-lock.sh` 里也是硬编码常量。

**失败退出码**（07 §7：「未拿到 DB 会话锁或数据根文件锁 → 停写，退出码 2，不写任何字节」）：

| 退出码 | 情形 | 行为 |
| --- | --- | --- |
| 0 | 迁移成功 | 台账打印完毕，两把锁已释放 |
| 1 | 迁移失败 | 脚本报错，该脚本的 DDL 与记账整体回滚；锁随会话结束释放 |
| 2 | 未拿锁 | 不执行任何 DDL、不写任何字节；`reason=migration-lock`（迁移锁被持有＝已有迁移在执行）／`reason=writer-lock`（写者锁被活跃写者持有＝serve 或 CLI 实例在跑，先停掉 serve 实例） |
| 1 | 预检拒绝 | 盘上脚本与 `cangshu_m1.schema_version` 台账不一致（缺脚本／换名／改字节／台账异常）：只读预检在任何新增 DDL 之前就停，不执行任何新增 DDL、不写任何字节；日志带 `CANGSHU\|migration\|preflight-denied\|reason=...` |

### 3.1 执行器语义：只追加、可复跑（P0-3① Q4 裁决）

一次迁移就是一条 psql 会话，会话内顺序固定为「取迁移锁 → 取写者锁 → **只读预检** → 执行／跳过新增脚本 → 打印台账 → 释放两把锁」。
启动 psql **之前**，宿主侧先把 `db/migration` 冻结成清单（版本＋脚本名＋整文件 SHA-256）；进会话后不再重扫那个可能变化的目录，
预检用的就是这份清单里的摘要。

| 库状态 | 执行器行为 |
| --- | --- |
| 全新库（无 `cangshu_m1` 对象） | 按版本顺序执行全部脚本；**空库首个迁移必须是 `V1`** |
| 台账已有该版本，且版本＋脚本名＋摘要三者一致 | **跳过**：只打 `CANGSHU\|migration\|script\|...\|action=skip`，脚本不再 `cat` 给 psql |
| 台账是已登记版本的连续前缀，本地还有更高版本 | 只执行缺失的连续后缀（`action=run`），顺序仍是版本升序 |
| 盘上缺已登记版本、同版本换脚本名、同版本改字节、台账重复／跳号／多于盘上脚本、命名空间存在但台账缺失 | **拒绝**：退出码 1、`preflight-denied`，不执行任何新增 DDL |

`preflight-denied` 的 `reason` 取值：`digest-drift`（摘要不一致）、`script-name-drift`（脚本名不一致）、
`ledger-script-missing`（台账有、盘上没有）、`ledger-duplicate-version`、`ledger-prefix-gap`、`ledger-not-prefix`、
`ledger-extra-row`、`ledger-missing`（schema 在、台账不在）、`ledger-kind`（`schema_version` 不是普通表）、
`bootstrap-version`（空库首个迁移不是 `V1`）。人工修复口径：恢复正确的旧脚本／台账，或新增更高版本；
禁止改已发布 SQL、删台账、清库绕过（ADR-0001 §七 ^dec-t3）。

新增脚本失败仍在脚本自己的事务里回滚（DDL 与它那条台账 INSERT 一起），已完成的前缀保留，重跑只从失败版本继续。
容器传输 `scripts/compose-migrate.sh` 不需要改接口：它只注入 `CANGSHU_MIGRATE_PSQL`，预检与执行仍在同一条
`docker compose exec -T db psql` 会话里（本机 Docker 引擎未运行，容器形态本轮未验证）。

**与 serve 侧写者锁的关系**：serve 的 `WriterGate` 启动时以 `pg_try_advisory_lock(20260919)`（＋数据根
文件锁）拒绝第二写者，失锁即停写、退出码 2（ADR-0001 §四 ^dec-t2）。迁移会话取的是**同一个键 20260919**，
两边天然互斥：serve 在跑时迁移被拒（并提示停掉 serve），迁移进行中 serve 也起不来。这里选择**拒绝**而不是
阻塞等写者退出，依据是 07 §1「迁移操作需确保业务写者已退出」——迁移前要先确认写者已退出，而不是边等边迁；
同时沿用 07 §7 与 ^dec-t2 的「失锁即退、退出码 2」口径（07 §6 的「等锁超 30 秒返回 503」说的是 HTTP 请求
等分段锁，不是迁移门）。

**取证**（不依赖 Docker，隔离库自建自删）：

```powershell
pwsh -File scripts/verify-migration-lock.ps1
```

五类情形：① 正常迁移（取锁先于脚本、台账摘要与宿主文件一致、结构正确）② 并发第二次迁移被拒
（退出码 2、`reason=migration-lock`、台账未变）③ 写者持锁时被拒（退出码 2、`reason=writer-lock`、
连 `cangshu_m1` 都没建）④ 失败回滚（退出码 1、台账与结构无残留、锁已释放且可再次取得）
⑤ 交付态包装脚本冒烟（容器传输未执行时用 `CANGSHU_MIGRATE_PSQL` 替换传输）。原始输出留在
`target/migration-lock-evidence/`；`-OutputDirectory` 可改输出目录，`-KeepDatabase` 可保留隔离库，
凭据取自 `application.yml` 默认值，可被 `CANGSHU_DB_USER` / `CANGSHU_DB_PASSWORD` 覆盖。

## 4 换行与字节级摘要（P0-3 收尾补丁）

台账 `cangshu_m1.schema_version.script_sha256` 记录的是**盘上文件的原始字节**摘要
（`scripts/lib/migration-lock.sh` 的 `migration_script_sha256` 直接对宿主文件算 SHA-256，psql 变量
`script_sha256` 与它同源），因此迁移脚本的**行尾是摘要的一部分**。

- 仓库根 `.gitattributes` 已把 `db/migration/*.sql`、`scripts/**`、`*.sh` 钉成 `text eol=lf`：
  这些文件在仓库内与工作树里都必须是 LF（`git check-attr eol db/migration/V1__init.sql` 应输出 `eol: lf`）。
- 若 `core.autocrlf=true` 而 `.gitattributes` 缺失（更早的 clone／检出，或被本地 `git config` 改回去），
  新 clone 出来的 `V1__init.sql` 会带 CRLF：文件「看起来没变」、`git status` 也可能照样干净（autocrlf 会在
  比较前把 CRLF 归一化回 LF），但盘上字节的 SHA-256 已经变了——预检会以
  `preflight-denied|reason=digest-drift` 拒绝迁移，形成死锁：不改文件过不去，改文件又违反「脚本只增不改」。
- 正确恢复办法：**恢复 LF 字节**。先确认 attributes 生效（`git check-attr eol db/migration/V1__init.sql`
  → `eol: lf`），再按属性重新检出这两个目录（`git checkout -- db/migration scripts` 或
  `git restore db/migration scripts`），并核对 `sha256sum db/migration/V1__init.sql` 与台账行一致；
  一致即可直接重跑 `scripts/migrate.sh`。
- **禁止**为了绕过 `digest-drift` 去改已发布的 `V*.sql`、删 `schema_version` 台账或清库重来
  （ADR-0001 §七 ^dec-t3「脚本只增不改」；07-运行手册 §4）。

## 5 目标库名门与锁释放结果（P0-3 收尾补丁）

- `scripts/migrate.sh` 在启动 psql **之前**执行目标库名门：库名必须匹配 `^[a-z_][a-z0-9_]*$`
  （空值、空白、通配符、引号／分号、大写一律拒绝），显式拒绝系统库 `postgres`／`template0`／`template1`，
  并要求**生效传输**里的 `-d`／`--dbname` 与 `CANGSHU_DB_URL` 的库名都等于 `CANGSHU_DB_NAME`；
  不一致即拒绝。拒绝时打印 `CANGSHU|migration|denied|reason=db-name-gate|...`，不启动 psql、不写任何字节，
  退出码 2（与「未拿锁＝2」同属「什么都没写」的拒绝路径；07 §7 的口径是「不写任何字节」）。命中的目标库名
  会显著打印在开头，且取自**生效传输／URL**，不是环境变量原值。`cangshu`／`cangshu_test` 等不是系统库、
  也不是被拒目标：本脚本正是它们唯一的迁移入口；演示脚本（demo-u1／u2／u3）另有更严的「只允许自己的演示库」门。
- 会话收尾的释放结果按 `pg_advisory_unlock` 的**实际返回值**打印：
  `CANGSHU|migration|lock-released|migrationKey=20260918|writerKey=20260919|released=<true|false>`
  （另附 `migrationLockReleased`／`writerLockReleased` 与 `migration_lock_released=...|writer_lock_released=...`）。
  `released=false` 说明本会话当时并不持有它声称持有的锁，是要人工核查的异常信号；迁移本身仍按成功计数
  （07 §7 的退出码 2 只覆盖「没拿到锁」，不覆盖收尾释放返回 false），由收尾提示要求核查
  `SELECT locktype, objid, pid FROM pg_locks WHERE locktype='advisory'`。
