---
description: 改一小步之前的一次性闸门：跑测绘、造裁判并量强度、改完复跑、强制拆除。快，不写全量结论。
argument-hint: "[项目路径 | project path]"
---

这是用户明确请求的**轻量闸门**（`profile=gate`：阶段 B、D、E、T，不跑 A 立界、不跑 C 定活）。
用在"我已经知道要改哪一行，只需要一个改之前/改之后的裁判"。默认从本档的第一个阶段 **B 测绘** 起跑。

```
powershell -NoProfile -ExecutionPolicy Bypass -File workflow/workflow-run.ps1 \
  -RepoPath "${ARGUMENTS:-.}" -Profile gate -TestCmd "<跑测试的命令>"
```

三条不许：

1. **不许用 `-DryRun` 的绿当过关**。dry-run 下机器门一律记 `planned`、不落任何产物；实测：
   不给 `-Confirm` 时它照样 rc=3（人工门仍要放行），给满 `-Confirm B,D,E,T` 才 rc=0 —— 那个 0 只代表
   "阶段与判据都接得上"，不代表任何一条机器判据真的跑过。
2. **不许在这个 profile 下声称"接手完成"**。它不含 A/C，压根没确认 DoD 与存活分诊；
   全量结论要用 `/legacy-refactor-full`。
3. **D 阶段的强度读数照原样报**：`MUT score=…`，并说明采到多少候选点（`avail/uncov`）。
   采不满就是抽样分，不许外推成"全仓裁判可靠"。

T 阶段（拆除）在两个档里都**不可跳过**：`-Sweep` 见硬残留（HARD>0）就 rc=1 ⇒ 整体判失败，
不能用"这次只是小改"来豁免。（清单里标的 `onFail=fail-closed` 目前只是注记 —— 执行器对所有阶段都是"不过就停"，
见 `workflow/contract.md` §7。）`[?]` 类（例如 `git status` 里的未跟踪件）由人工门 T-g3 确认，不由机器代答。
