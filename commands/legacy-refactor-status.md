---
description: 读一次既有工作流 run 的密封产物：结论、停在哪个门、哪些是 unknown；并核对密封有没有被改过。
argument-hint: "[run 目录 | run directory]"
---

这是**只读观察者**。不重跑任何阶段，不改任何文件。

```
# 1) 核对密封（三份语义文档是否仍是当时那三份）
powershell -NoProfile -ExecutionPolicy Bypass -File workflow/workflow-run.ps1 -VerifySeal -RunDir "<run 目录>"

# 2) 读结论与逐阶段状态
powershell -NoProfile -ExecutionPolicy Bypass -File workflow/workflow-run.ps1 -RunDir "<run 目录>"
```

用户没给目录时，列 `~/.legacy-refactor-flow/runs/<projectId>/` 下的时间戳目录让他挑，**不要猜哪个是"最新那次"**——
同一仓可能有多个并发的 run，认错了目录就是把别人的结论安在这次上。

要报的内容，按这个次序，且只报文件里有的：

- `run-manifest.json`：目标仓、profile、`confirmed`（哪些人工门被放行了）、`outcome`、`failAt`、三个脚本的 sha256。
- `coverage.json`：逐阶段状态、`unknown`、`notChecked`。
- `gates.json`：停在 `failAt` 那条门的 `detail`（含输出尾部）。

三条口径：

1. **`-VerifySeal` rc=1 ⇒ 这份 run 的语义文档被事后改过**，它的任何结论都不能引用；改 `report.md` 不会让它变红（投影故意不入密封），
   所以"投影还能读"不等于"结论可信"。
2. **人工门放行不等于机器验证过**：`confirmed` 里有 `A` 只说明用户点了头，说明这一点时要用"用户确认"而不是"已验证"。
3. **`unknown` / `notChecked` 原样转述**，不许折合成"应该没问题"。daemon / crontab / 用户级环境变量 / 常驻端口 / 跨仓写入这几类是工具判不了，不是判过没问题。

本执行器是单进程前台跑的，**没有活着的 job 可查**：上面第 2 条命令（只给 `-RunDir`、不给 `-RepoPath`）
读的是已落盘的产物，不是进度条。不要向用户承诺"正在跑""可以取消"——两样都没有（见 `workflow/contract.md` §6）。
