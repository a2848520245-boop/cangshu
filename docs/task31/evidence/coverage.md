# 任务31矩阵脚本实现覆盖（2026-09-26）

状态：**代码路径已接齐；正式 VM/数据库中断矩阵未运行，ACC-G4 仍未验。** 本页是实现覆盖清单，不是验收结论。

| 格子 | 代码注入/取证点 | 本轮验证 |
|---|---|---|
| 1-1 | 新建上传：业务 data-root/tmp 未写完 + 自启 JVM `FileStore.stage` 栈 | AST/控制流；VM 未跑 |
| 1-2 | 复用上传：既有正式键 + 新业务 tmp 未写完 + JVM 栈 | AST/控制流；VM 未跑 |
| 2-1 | `content` 表 EXCLUSIVE 锁阻断 `SELECT ... FOR UPDATE`，移动前 tmp 在 | AST/控制流；VM 未跑 |
| 3-1 | 普通 BEFORE `content INSERT` 触发器，移动已发生而首 INSERT 未执行 | AST/控制流；VM 未跑 |
| 4-1 | `resource INSERT` 延迟约束触发器卡 COMMIT 前 | 既有 runner 修安全边界；VM 未跑 |
| 4-2 | 复用 `resource INSERT` 延迟约束触发器卡 COMMIT 前 | AST/控制流；VM 未跑 |
| 4-3 | 软删 `resource UPDATE` 延迟约束触发器卡 COMMIT 前 | AST/控制流；VM 未跑 |
| 4-4 | GC 段一普通 AFTER `content UPDATE` 触发器，事务未提交 | AST/控制流；VM 未跑 |
| 5-1 | 201 响应后强杀，重启读回；追加库内关联/身份断言 | 既有 runner 修响应契约；VM 未跑 |
| 5-2 | `deduplicated=true` 响应后强杀，两引用同内容/位置及字节未重写 | AST/控制流；VM 未跑 |
| 5-3 | 软删 204 响应后强杀，DELETED/回收站/字节在 | AST/控制流；VM 未跑 |
| 5-4 | GC 段一提交后、位置已删、原位字节仍在轮询 | AST/控制流；VM 未跑 |
| 6-4 | GC 段二自启 JVM `GcService.deleteBytes → FileStore.sha256Hex` 线程栈 | AST/控制流；VM 未跑 |
| 7-4 | GC 段二删字节后，段三普通 AFTER `content UPDATE` 卡 COMMIT 前 | AST/控制流；VM 未跑 |

12 个不适用格保留逐格理由：1-3、1-4、2-2、2-3、2-4、3-2、3-3、3-4、6-2、6-3、7-2、7-3。6-1 引用 6-4 三次证据，7-1 引用 7-4 三次证据；引用只有源格有效时才被汇总判定接受。

三类负对照由独立模块在完整 `-Cells all -Runs 3` 中执行：`missing_bytes` 下载失败/告警、`corrupt_bytes` GC `BYTE_MISMATCH` 停删/告警、`orphan` 对账隔离。模块 mock 证明控制流及失败证据写入；真实数据库效果未验证。

安全与证据约束：每次调用唯一 invocationId；窗口未命中最多重试 3 次，每次新库/根/端口且 miss 不计有效运行；真断言失败与执行异常不重试。仅删除本次确权创建的隔离库，检查 drop 退出码；仅按自启进程句柄 finally 收束。运行前要求干净 HEAD；默认 Maven 打包并记录 jar SHA-256/HEAD，`-SkipBuild` 需匹配清单；运行后复核 jar SHA-256。普通 GC 触发器不进入 `pg_constraint`。点1/2/4-2 的业务 tmp 在杀后原始快照之外单独加龄，再断言启动对账 `tempDeleted>=1` 且文件消失。

静态/合成验证原始日志：`ast.log`、`upload-contract.log`、`retry.log`、`summary.log`（47例）、`negative-controls.log`、`diffcheck.log`；文件摘要见 `file-hashes.txt`。这些不替代正式 VM 运行、42 次真实独立结果、三类真实负对照或项目任务表核验。
