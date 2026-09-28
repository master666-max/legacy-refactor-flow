#!/usr/bin/env node
// 预注册 R5（崩溃注入测残留与误删）的可复跑夹具。用法：
//   node tests/r5-crash-inject.js <技能仓路径> <ledger|lease> <次数> [沙箱目录]
// arm=ledger 只登记不给租约；arm=lease 给 -TTLHours 0.001（约 3.6 秒后过期）。
// 判据（跑前钉死）：崩溃组残留中位 >= 1；加收集器后降到 0；误删 > 0 即判该补丁不合格。
// 已知测不到：夹具是 scratch 配置文件，daemon / crontab / 跨仓 / 跨主机的残留结构上不在射程内。
// R5 崩溃注入夹具（预注册 §4 R5）：执行体"登记之后、拆除之前"被硬杀，看残留与误删。
// 两臂：arm=ledger（只登记，不给租约）/ arm=lease（带 owner + TTL=0 ⇒ 立即可被收集器接管）
// 用法：node r5-crash.js <技能仓绝对路径> <ledger|lease> <次数> [沙箱目录]
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const SKILL = path.resolve(process.argv[2]);
const arm = process.argv[3];
const runs = Number(process.argv[4] || 20);
const base = path.resolve(process.argv[5] || path.join(process.env.TEMP || '/tmp', 'lrf-r5-' + arm));
const LEDGER = path.join(base, 'hooks.json');
const PS = path.join(SKILL, 'scripts', 'hooks-ledger.ps1');

function readJson(p) { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); }
function w(p, s) { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s, 'utf8'); }
function sh(args) {
  const r = spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', PS, ...args], { encoding: 'utf8' });
  return { rc: r.status, out: (r.stdout || '') + (r.stderr || '') };
}
function sleep(ms) { const e = Date.now() + ms; while (Date.now() < e) {} }

fs.rmSync(base, { recursive: true, force: true });
fs.mkdirSync(base, { recursive: true });
w(LEDGER, JSON.stringify({ entries: [] }, null, 2));

let landed = 0, killedOk = 0, neverLanded = 0;
for (let i = 1; i <= runs; i++) {
  const hook = path.join(base, 'cfg' + i + '.json');
  w(hook, JSON.stringify({ marker: 'original-' + i }, null, 2));
  const reg = ['-Ledger', LEDGER, '-Register', '-Kind', 'config', '-Path', hook, '-Action', 'created', '-Owner', 'r5-' + arm];
  if (arm === 'lease') { reg.push('-TTLHours', '0.001'); }   // ≈3.6 秒后过期；-TTLHours 0 是"不过期"，别当"立即过期"用
  // 执行体 = 登记完再"继续干活"60 秒（收尾本会在这之后跑）；我们在这 60 秒里把它杀掉
  const inner = '& "' + PS.replace(/"/g, '\\"') + '" ' + ['-Ledger', '"' + LEDGER + '"', '-Register', '-Kind', 'config',
    '-Path', '"' + hook + '"', '-Action', 'created', '-Owner', 'r5-' + arm].join(' ') +
    (arm === 'lease' ? ' -TTLHours 0.001' : '') + '; Start-Sleep -Seconds 60';
  const child = spawn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', inner], { stdio: 'ignore' });
  const pid = child.pid;
  // 等登记落进台账（最多 20 秒），确保崩溃点在"之后"
  let ok = false;
  for (let t = 0; t < 40 && !ok; t++) {
    sleep(500);
    try { ok = hookList().some(e => String(e.path).endsWith('cfg' + i + '.json')); } catch (e) { ok = false; }
  }
  if (!ok) { neverLanded++; try { child.kill('SIGKILL'); } catch (e) {} continue; }
  landed++;
  try { process.kill(pid, 'SIGKILL'); killedOk++; } catch (e) { killedOk++; }
  sleep(300);
}

// ★ 误删对照：一条带 24h 租约（仍在用）+ 一个不在台账里的用户自有件
const keepHook = path.join(base, 'keep.json');
w(keepHook, JSON.stringify({ marker: 'user-owned-in-use' }, null, 2));
sh(['-Ledger', LEDGER, '-Register', '-Kind', 'config', '-Path', keepHook, '-Action', 'created', '-Owner', 'r5-keep', '-TTLHours', '24']);
const userOwn = path.join(base, 'user-own.txt');
w(userOwn, 'mine\n');

function hookList() { try { return readJson(LEDGER).hooks || []; } catch (e) { return []; } }
function filesLeft() { return fs.readdirSync(base).filter(f => /^cfg\d+\.json$/.test(f)).length; }
function countLive() { return hookList().filter(h => !h.removed).length; }
if (arm === 'lease') { sleep(12000); }   // 等租约过期，否则收集器看不见孤儿
const before = countLive();
const filesBefore = filesLeft();
const verify1 = sh(['-Ledger', LEDGER, '-Verify']);
const collectDry = sh(['-Ledger', LEDGER, '-Collect']);
const collectApply = sh(['-Ledger', LEDGER, '-Collect', '-Apply']);
const after = countLive();
const filesAfter = filesLeft();
const verify2 = sh(['-Ledger', LEDGER, '-Verify']);
const sweep = sh(['-Sweep', '-Repo', base]);

const res = {
  arm, runs, landed_before_kill: landed, killed_after_landing: killedOk, never_landed: neverLanded,
  residue_before_collect: before, residue_after_collect: after,
  files_before_collect: filesBefore, files_after_collect: filesAfter,
  verify_rc_before: verify1.rc, verify_rc_after: verify2.rc,
  keep_survived: fs.existsSync(keepHook), user_file_untouched: fs.existsSync(userOwn),
  collect_dry_rc: collectDry.rc, collect_apply_rc: collectApply.rc, sweep_rc: sweep.rc,
  sweep_counters: (sweep.out.match(/HARD=\d+ CHECK=\d+ UNCOVERED=\d+/) || ['(没打到计数行)'])[0],
  collect_dry_expired_line: (collectDry.out.match(/EXPIRED=\d+|过期 \d+|\d+ 条/g) || []).slice(0, 3),
  // 崩溃必须先"落在登记之后"才叫崩溃注入；一条都没落地时，残留=0 是仪器坏了，不是补丁有效
  injection_valid: (landed === runs && killedOk === runs && neverLanded === 0)
};
w(path.join(base, 'r5-result.json'), JSON.stringify(res, null, 2));
console.log(JSON.stringify(res, null, 2));
