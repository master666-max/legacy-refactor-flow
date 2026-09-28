---
description: 用五步流程接手一个遗留仓：立界→测绘→定活→造裁判→小步改→强制拆除，每步出口是可执行、可密封的门。
argument-hint: "[项目路径 | project path]"
---

这是用户明确请求的**完整**遗留重构工作流（`profile=full`，六个阶段 22 条门）。

调用本技能自带的前台执行器（PowerShell 5.1 / pwsh 7 皆可）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File workflow/workflow-run.ps1 \
  -RepoPath "${ARGUMENTS:-.}" -TestCmd "<该仓跑测试的命令>"
```

它会一路判到**第一道过不去的门**就停，并把这次跑的东西密封到 `~/.legacy-refactor-flow/runs/<projectId>/<runId>/`。

阶段 A/B/C/D 的人工门要用户本人放行，**不许我自己替他确认**：把停在哪个门、那条门的判据与实测证据念给用户，
拿到用户明确的答复后再补 `-Confirm A,B,C,D,E,T` 里的对应字母重跑。`-TestCmd` 缺失或清单文件不在位 ⇒ rc=2，
那是安装故障，不是流程失败，照实说。

按退出码说话，措辞受限（见 `workflow/contract.md` §3）：

- **rc=0**（`complete`）：可以按 `SCOPE.md` 的 DoD 交付，并附上密封目录路径与核对命令。
- **rc=3**（`partial/INCONCLUSIVE`）：只报"跑到哪、还差哪个人工确认"，**不许**说"基本改好了"。
- **rc=1**（`failed`）：把 `gates.json` 里那条失败门的 `detail`（含输出尾部）原样贴出来，说清缺什么。
- **rc=2**：安装/用法故障，停止，不要绕过去手工模拟门。

`coverage.json` 里的 `unknown` 与 `notChecked` 必须原样转述——尤其"变异得分是抽样分"和
"daemon/crontab/用户级环境变量/端口/跨仓写入这几类本工具判不了"。缺席不等于已解决。

需要权限、业务语义或跨仓信任关系的判断，交回用户；本命令不改代码、不建常驻钩子（建的一律登记并带租约）。
只想改一小步、不需要测绘时用 `/legacy-refactor-gate`；查历史某次 run 用 `/legacy-refactor-status`。
