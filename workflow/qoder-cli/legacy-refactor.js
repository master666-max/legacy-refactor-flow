// legacy-refactor —— Qoder CLI 动态工作流壳（profile 由 args 决定）
//
// 放在项目 `.qoder/workflows/` 或用户级 `~/.qoder/workflows/` 下，然后说一句
//   "用 legacy-refactor 动态工作流重构 <某仓>"
//
// ★ 这层的定位要说清楚：**它不判门，它只是派工**。
//   真正的判据在 workflow/workflow-run.ps1 里（22 道门 + 密封产物 + 退出码口径）。
//   动态工作流脚本按官方文档**不能直接碰 shell / 文件系统 / 网络**，所有副作用都得经子 agent；
//   所以本文件的每个阶段都是"派一个子 agent 去跑执行器的那一段，并把 rc 与失败门的证据带回来"。
//   这样做的代价：门判强度没有因为这层壳而变高；好处是用户能一句话点单，并在运行前看到计划再放行。
//
// 未验证声明（2026-09-28 更新，剩最后一格）：本文件**没有被真正执行过**——名字能被解析到，
//   但"运行工作流"这道授权只能由在场的人点允许，非交互通路给不出（下面四条实测）。
//   语法照 CLI 自带契约写：脚本须以 `export const meta = { name, description, phases }` 起头（纯字面量），
//   正文用 agent()/parallel()/pipeline()/phase()/log()。★ 但**meta 前面有注释不影响解析**（实测过）。
//
// 装出来的实况（2026-09-28 在 qodercli 1.1.64 上逐条实测，命令与回执都可复跑）：
//   · 命令名是 qodercli（文档写 qoder）；装在 ~/.qoder/bin/qodercli/，**该目录在 PATH 上但 exe 在子目录里**
//     ⇒ 直接敲 qodercli 不响。修法：往 PATH 上已有的可写目录放一个 qodercli.cmd 转发，不动注册表。
//   · `qodercli --help` 的 Commands 面里**没有** workflows 子命令（97 行帮助，清掉开关后仍 97 行、仍无）
//     ——但这不等于不支持：二进制里有 `commands.builtin.workflows.description`、`createWorkflowRegistryFromConfig`，
//     且 Workflow 工具的入参说明写着 "Name of a predefined workflow from the built-in, plugin, project, or user workflow registry"。
//   · 关掉它的是一把环境变量：**宿主 app 会注入 `QODER_FEATURE_WORKFLOWS_DISABLE=1`**（实测值就是 1）。
//     所以"在 Qoder 里跑子进程 qodercli"必然看不见工作流；把这三个变量清掉再起，CLI 就承认
//     "我持有名为 Workflow 的工具，另有 /workflows 内置命令（用于查看进度，不是触发入口）"。
//   · 非交互 `-p` 必须配 `--input-format stream-json --output-format stream-json`，否则报
//     `sdk_invalid_args: Agent SDK entrypoint env is set but required flags are missing`（因为宿主注入了
//     `QODER_AGENT_SDK_ENTRYPOINT=sdk-ts`；清掉该变量后 `-p --output-format text` 可直接用）。
//   · 触发实测（两个只差"meta 前有没有注释"的玩具工作流，同一权限档）：
//     默认档 ⇒ 两个都回 `Error: Run workflow lrfpinga?` / `…lrfpingb?`（**弹窗文本带各自名字 ⇒ 名字解析成功**，卡在授权）；
//     `--allowed-tools Workflow` ⇒ 仍拒（这道门不在工具白名单里）；
//     `--permission-mode dont_ask` ⇒ `This action needs approval, and the "Don't ask" permission mode does not prompt`；
//     `--permission-mode bypass_permissions` / `--dangerously-skip-permissions` **没试**：那等于把工作流里的
//     每个子 agent 全免授权，代价与这条待验格不成比例。要真跑通请在 TUI 里点允许。
//   ⇒ 结论：**平台支持动态工作流，但这层壳在本机仍是"未执行过"**；权威判据仍在 workflow-run.ps1。

export const meta = {
  name: "legacy-refactor",
  description: "遗留系统重构：立界→测绘→定活→造裁判→小步改→强制拆除，每步出口是可执行、可密封的门",
  whenToUse: "面对一个没人懂、缺测试、可能是 AI 写的代码库，需要安全改造；或用户要求按重构流程接手一个仓",
  phases: [
    { title: "立界 A", detail: "写 SCOPE.md（in-scope / read-only / DoD），确认可判真假的完成定义，留退路" },
    { title: "测绘 B", detail: "跑 phase0-recon：语言/体量/热点/测试设施三态/入口点候选" },
    { title: "定活 C", detail: "入口点逐个打 LIVE/DEAD/UNKNOWN，写 TRIAGE.csv，带观测窗口与触达画像" },
    { title: "造裁判 D", detail: "基线跑绿 + mutation-probe 量裁判强度，报 MUT score 与漏放清单" },
    { title: "小步改 E", detail: "一个 PR 一个意图，每步都有探测器看着；行为差异全部登记" },
    { title: "拆除 T", detail: "台账 -Verify 全清 + -Sweep 无硬残留 + 孤儿按租约收走" },
  ],
};

// args：{ repo: "<目标仓绝对路径>", test: "<该仓跑测试的命令>", profile: "full" | "gate", confirm: "A,B,..." }
const repo = (args && args.repo) || ".";
const test = (args && args.test) || "";
const profile = (args && args.profile) || "full";
const confirm = (args && args.confirm) || "";

// 一次阶段 = 派一个子 agent 前台跑执行器的一段，并把 rc / failAt / 失败门的 detail 原样带回
function step(phaseId, goal) {
  return agent(
    [
      `在仓库 ${repo} 上执行重构工作流阶段 ${phaseId}（${goal}）。`,
      "命令（前台执行，工作目录切到技能仓）：",
      `powershell -NoProfile -ExecutionPolicy Bypass -File workflow/workflow-run.ps1 -RepoPath "${repo}" -TestCmd "${test}" -Profile ${profile} -FromPhase ${phaseId}` +
        (confirm ? ` -Confirm ${confirm}` : ""),
      "只报事实，不许替用户判断：",
      "1) 退出码原样报（0 complete / 1 failed / 2 安装或用法故障 / 3 partial-INCONCLUSIVE）；",
      "2) 停在哪个门：读该 run 目录 run-manifest.json 的 failAt，并把 gates.json 里那条的 detail（含输出尾部）逐字贴出来；",
      "3) coverage.json 里的 unknown 与 notChecked 必须原样转述，缺席不等于已解决；",
      "4) 遇到 op=human 的门只许停下报'等用户放行'，**不许自行加 -Confirm**，也不许把'用户大概会同意'当放行；",
      "5) rc 非 0 时交付措辞受限：只能写'跑到哪停住'，不许写'基本完成'。",
    ].join("\n"),
    { label: `wf-${phaseId}` }
  );
}

const results = [];
for (const ph of meta.phases) {
  const id = ph.title.split(" ")[0];
  // profile=gate 时跳过 A 与 C（轻量档：B/D/E/T）
  if (profile === "gate" && (id === "A" || id === "C")) {
    log(`跳过阶段 ${id}（profile=gate 不含它；全量结论请用 profile=full）`);
    continue;
  }
  phase(ph.title);
  results.push({ phase: id, outcome: await step(id, ph.detail) });
}

return {
  profile,
  repo,
  阶段读数: results,
  口径: "本壳不判门；门与密封在 workflow/workflow-run.ps1。任何 rc≠0 ⇒ 交付只能写'跑到哪停住'。",
};
