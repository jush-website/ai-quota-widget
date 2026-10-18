import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import https from 'node:https';
import http from 'node:http';

const HOME = os.homedir();
const CLAUDE_LIVE_CACHE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'logs', 'claude-live-cache.json');
const CLAUDE_FETCH_INTERVAL_MS = 60 * 1000;
let lastClaudeLiveResult = null;
let nextClaudeFetchAt = 0;
let claudeCliPathPromise = null;

async function firstExistingPath(candidates) {
  for (const candidate of candidates.filter(Boolean)) {
    try {
      await fs.access(candidate);
      return candidate;
    } catch { /* keep looking */ }
  }
  return null;
}

async function desktopClaudeCliCandidates() {
  if (process.platform !== 'win32' || !process.env.LOCALAPPDATA) return [];
  const packagesRoot = path.join(process.env.LOCALAPPDATA, 'Packages');
  const candidates = [];
  let packages = [];
  try { packages = await fs.readdir(packagesRoot, { withFileTypes: true }); } catch { return candidates; }
  for (const item of packages) {
    if (!item.isDirectory() || !/^Claude_/i.test(item.name)) continue;
    const versionsRoot = path.join(packagesRoot, item.name, 'LocalCache', 'Roaming', 'Claude', 'claude-code');
    let versions = [];
    try { versions = await fs.readdir(versionsRoot, { withFileTypes: true }); } catch { continue; }
    for (const version of versions) {
      if (version.isDirectory()) candidates.push(path.join(versionsRoot, version.name, 'claude.exe'));
    }
  }
  return candidates.sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
}

async function findClaudeCli() {
  if (claudeCliPathPromise) {
    const cached = await claudeCliPathPromise;
    if (cached && await fs.access(cached).then(() => true).catch(() => false)) return cached;
    claudeCliPathPromise = null;
  }
  claudeCliPathPromise = (async () => {
    const direct = await firstExistingPath([
      process.env.CLAUDE_CLI_PATH,
      process.platform === 'win32' ? path.join(HOME, '.local', 'bin', 'claude.exe') : null,
      process.platform === 'win32' && process.env.APPDATA ? path.join(process.env.APPDATA, 'npm', 'claude.cmd') : null
    ]);
    if (direct) return direct;

    const lookup = process.platform === 'win32'
      ? spawnSync('where.exe', ['claude'], { windowsHide: true, encoding: 'utf8' })
      : spawnSync('which', ['claude'], { encoding: 'utf8' });
    if (lookup.status === 0) {
      const found = String(lookup.stdout || '').split(/\r?\n/).find(Boolean);
      if (found) return found.trim();
    }
    return firstExistingPath(await desktopClaudeCliCandidates());
  })();
  const result = await claudeCliPathPromise;
  if (!result) claudeCliPathPromise = null;
  return result;
}

async function providerInstalled(command, dataHome) {
  try {
    await fs.access(dataHome);
    return true;
  } catch { /* try executable lookup */ }
  const lookup = process.platform === 'win32'
    ? spawnSync('where.exe', [command], { windowsHide: true, stdio: 'ignore' })
    : spawnSync('which', [command], { stdio: 'ignore' });
  return lookup.status === 0;
}

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function isoFromUnix(value) {
  const number = numberOrNull(value);
  if (number === null) return null;
  const milliseconds = number > 10_000_000_000 ? number : number * 1000;
  return new Date(milliseconds).toISOString();
}

function isoFromValue(value) {
  if (typeof value === 'string' && Number.isFinite(Date.parse(value))) return new Date(value).toISOString();
  return isoFromUnix(value);
}

function codexWindowLabel(name, value, modelName = null) {
  if (modelName) return `每週 · ${modelName}`;
  const minutes = numberOrNull(value?.window_minutes);
  if (minutes === 300) return '5 小時額度';
  if (minutes === 10080) return '每週 · 所有模型';
  if (minutes && minutes % 1440 === 0) return `${minutes / 1440} 天額度`;
  return name === 'primary' ? '主要額度' : '次要額度';
}

function windowFromCodex(name, value, modelName = null) {
  if (!value) return null;
  const used = numberOrNull(value.used_percent);
  return {
    id: name,
    label: codexWindowLabel(name, value, modelName),
    usedPercent: used,
    remainingPercent: used === null ? null : Math.max(0, 100 - used),
    windowMinutes: numberOrNull(value.window_minutes),
    resetsAt: isoFromUnix(value.resets_at)
  };
}

function individualCodexWindows(individual) {
  if (!individual) return [];
  const modelName = individual.limit_name ?? individual.name ?? individual.model_name ?? individual.limit_id ?? '特定模型';
  if (individual.primary || individual.secondary) {
    return [
      windowFromCodex('individual-primary', individual.primary, modelName),
      windowFromCodex('individual-secondary', individual.secondary, modelName)
    ].filter(Boolean);
  }
  return [windowFromCodex('individual', individual, modelName)].filter(Boolean);
}

function windowFromClaude(id, value) {
  if (!value) return null;
  const used = numberOrNull(value.used_percentage ?? value.utilization ?? value.percent);
  const labels = { five_hour: '5 小時額度', seven_day: '7 天額度', seven_day_opus: 'Opus 7 天額度', seven_day_sonnet: 'Sonnet 7 天額度' };
  return {
    id,
    label: labels[id] ?? id.replaceAll('_', ' '),
    usedPercent: used,
    remainingPercent: used === null ? null : Math.max(0, 100 - used),
    windowMinutes: null,
    resetsAt: isoFromValue(value.resets_at)
  };
}

function liveClaudeWindows(usage) {
  if (Array.isArray(usage?.limits) && usage.limits.length) {
    return usage.limits.map((limit, index) => {
      const modelName = limit?.scope?.model?.display_name;
      const labels = {
        session: '5 小時額度',
        weekly_all: '每週 · 所有模型',
        weekly_scoped: modelName ? `每週 · ${modelName}` : '每週 · 特定模型'
      };
      const window = windowFromClaude(`limit-${index}`, limit);
      if (window) window.label = labels[limit.kind] ?? limit.kind ?? window.label;
      return window;
    }).filter(Boolean);
  }
  return Object.entries({ five_hour: usage?.five_hour, seven_day: usage?.seven_day, seven_day_opus: usage?.seven_day_opus, seven_day_sonnet: usage?.seven_day_sonnet })
    .map(([id, value]) => windowFromClaude(id, value)).filter(Boolean);
}

let credentialRefreshPromise = null;
async function refreshClaudeCredentialsWithCli() {
  if (credentialRefreshPromise) return credentialRefreshPromise;
  credentialRefreshPromise = (async () => {
    const cliPath = await findClaudeCli();
    if (!cliPath) throw new Error('Claude Code CLI not found');
    return new Promise((resolve, reject) => {
    const child = spawn(cliPath, [], { windowsHide: true, shell: /\.(cmd|bat)$/i.test(cliPath), stdio: ['pipe', 'ignore', 'ignore'] });
    const timer = setTimeout(() => { child.kill(); reject(new Error('Claude CLI refresh timed out')); }, 15000);
    child.once('error', (error) => { clearTimeout(timer); reject(error); });
    child.once('exit', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`Claude CLI refresh exited with code ${code}`));
    });
    child.stdin.end('/usage\n/exit\n');
    });
  })().finally(() => { credentialRefreshPromise = null; });
  return credentialRefreshPromise;
}

async function claudeCredentials(claudeHome) {
  const credentials = JSON.parse(await fs.readFile(path.join(claudeHome, '.credentials.json'), 'utf8'))?.claudeAiOauth;
  if (!credentials?.accessToken) throw new Error('Claude OAuth credentials not found');
  return credentials;
}

async function fetchClaudeOAuthUsage(claudeHome) {
  let credentials = await claudeCredentials(claudeHome);
  if (numberOrNull(credentials.expiresAt) !== null && Number(credentials.expiresAt) <= Date.now() + 30_000) {
    await refreshClaudeCredentialsWithCli();
    credentials = await claudeCredentials(claudeHome);
  }
  const request = async () => fetch('https://api.anthropic.com/api/oauth/usage', {
    headers: {
      Authorization: `Bearer ${credentials.accessToken}`,
      'anthropic-beta': 'oauth-2025-04-20',
      'Content-Type': 'application/json'
    },
    signal: AbortSignal.timeout(7000)
  });
  let response = await request();
  if (response.status === 401) {
    await refreshClaudeCredentialsWithCli();
    credentials = await claudeCredentials(claudeHome);
    response = await request();
  }
  if (!response.ok) {
    const error = new Error(`Claude usage API returned ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return { usage: await response.json(), credentials };
}

async function saveClaudeLiveResult(result) {
  lastClaudeLiveResult = result;
  try {
    await fs.mkdir(path.dirname(CLAUDE_LIVE_CACHE), { recursive: true });
    await fs.writeFile(CLAUDE_LIVE_CACHE, JSON.stringify(result), { encoding: 'utf8', mode: 0o600 });
  } catch { /* memory cache is still usable */ }
}

async function cachedClaudeLiveResult() {
  if (lastClaudeLiveResult) return lastClaudeLiveResult;
  try {
    const result = JSON.parse(await fs.readFile(CLAUDE_LIVE_CACHE, 'utf8'));
    if (result?.source === 'live' && result?.updatedAt) lastClaudeLiveResult = result;
    return lastClaudeLiveResult;
  } catch { return null; }
}

async function newestJsonlFiles(root, limit = 40) {
  const files = [];
  async function walk(directory) {
    let entries;
    try {
      entries = await fs.readdir(directory, { withFileTypes: true });
    } catch {
      return;
    }
    await Promise.all(entries.map(async (entry) => {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) return walk(fullPath);
      if (!entry.isFile() || !entry.name.endsWith('.jsonl')) return;
      try {
        const stat = await fs.stat(fullPath);
        files.push({ fullPath, mtimeMs: stat.mtimeMs });
      } catch { /* file may be rotating */ }
    }));
  }
  await walk(root);
  return files.sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, limit);
}

async function readTail(filePath, maxBytes = 1024 * 1024) {
  const handle = await fs.open(filePath, 'r');
  try {
    const stat = await handle.stat();
    const length = Math.min(stat.size, maxBytes);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, stat.size - length);
    let text = buffer.toString('utf8');
    if (stat.size > length) text = text.slice(text.indexOf('\n') + 1);
    return text;
  } finally {
    await handle.close();
  }
}

function codexWindowFromWham(name, window) {
  if (!window) return null;
  const seconds = numberOrNull(window.limit_window_seconds);
  return windowFromCodex(name, {
    used_percent: window.used_percent,
    window_minutes: seconds === null ? null : seconds / 60,
    resets_at: window.reset_at
  });
}

async function fetchCodexLiveUsage(codexHome) {
  const auth = JSON.parse(await fs.readFile(path.join(codexHome, 'auth.json'), 'utf8'));
  const token = auth?.tokens?.access_token;
  if (!token) throw new Error('Codex access token not found');
  const response = await fetch('https://chatgpt.com/backend-api/wham/usage', {
    headers: {
      Authorization: `Bearer ${token}`,
      'ChatGPT-Account-Id': auth?.tokens?.account_id ?? '',
      'Content-Type': 'application/json'
    },
    signal: AbortSignal.timeout(7000)
  });
  if (!response.ok) {
    const error = new Error(`Codex usage API returned ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

export async function readCodexUsage(codexHome = process.env.CODEX_HOME || path.join(HOME, '.codex')) {
  if (!await providerInstalled('codex', codexHome)) {
    return { id: 'codex', name: 'Codex', installed: false, available: false, message: '這台電腦尚未安裝 Codex。', windows: [] };
  }
  const fromLogs = await readCodexLogUsage(codexHome);
  // ponytail: 直接查官方額度端點，跟 Codex /status 一致；access_token 由 Codex CLI 自己刷新，過期(401/失敗)就退回讀本機紀錄
  try {
    const live = await fetchCodexLiveUsage(codexHome);
    const rateLimit = live?.rate_limit ?? {};
    const windows = [
      codexWindowFromWham('primary', rateLimit.primary_window),
      codexWindowFromWham('secondary', rateLimit.secondary_window)
    ].filter(Boolean);
    if (windows.length) {
      return {
        ...fromLogs,
        id: 'codex',
        name: 'Codex',
        installed: true,
        available: true,
        updatedAt: new Date().toISOString(),
        plan: live.plan_type ?? fromLogs.plan ?? null,
        source: 'live',
        windows,
        credits: live.credits ?? fromLogs.credits ?? null
      };
    }
  } catch { /* 即時查詢失敗，退回本機紀錄 */ }
  return fromLogs;
}

async function readCodexLogUsage(codexHome) {
  const sessionsRoot = path.join(codexHome, 'sessions');
  const files = await newestJsonlFiles(sessionsRoot);
  let newest = null;

  for (const file of files) {
    let text;
    try { text = await readTail(file.fullPath); } catch { continue; }
    const lines = text.split(/\r?\n/);
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      if (!lines[index].includes('"rate_limits"')) continue;
      try {
        const event = JSON.parse(lines[index]);
        const rateLimits = event?.payload?.rate_limits;
        if (!rateLimits) continue;
        const timestamp = Date.parse(event.timestamp || '') || file.mtimeMs;
        if (!newest || timestamp > newest.timestamp) {
          newest = { timestamp, rateLimits, info: event?.payload?.info ?? null };
        }
        break;
      } catch { /* ignore a partially written line */ }
    }
  }

  if (!newest) {
    return { id: 'codex', name: 'Codex', installed: true, available: false, message: '已安裝 Codex，但尚未找到用量資料；請先執行一次 Codex。', windows: [] };
  }

  const { rateLimits, info } = newest;
  const windows = [
    windowFromCodex('primary', rateLimits.primary),
    windowFromCodex('secondary', rateLimits.secondary),
    ...individualCodexWindows(rateLimits.individual_limit)
  ].filter(Boolean);
  const usedContextTokens = numberOrNull(info?.last_token_usage?.total_tokens ?? info?.last_token_usage?.input_tokens);
  const contextWindow = numberOrNull(info?.model_context_window);
  return {
    id: 'codex',
    name: 'Codex',
    installed: true,
    available: true,
    updatedAt: new Date(newest.timestamp).toISOString(),
    plan: rateLimits.plan_type ?? null,
    windows,
    credits: rateLimits.credits ?? null,
    sessionTokens: info?.total_token_usage?.total_tokens ?? null,
    contextWindow,
    context: contextWindow && usedContextTokens !== null ? {
      usedTokens: usedContextTokens,
      limitTokens: contextWindow,
      usedPercent: Math.min(100, Math.max(0, usedContextTokens / contextWindow * 100))
    } : null
  };
}

export async function readClaudeUsage(claudeHome = process.env.CLAUDE_HOME || path.join(HOME, '.claude')) {
  const cliPath = await findClaudeCli();
  if (!cliPath && !await providerInstalled('claude', claudeHome)) {
    return { id: 'claude', name: 'Claude', installed: false, available: false, source: 'unavailable', stale: false, message: '這台電腦尚未安裝 Claude Code。', windows: [] };
  }
  const cachePath = path.join(claudeHome, 'usage-cache.json');
  const recentLive = await cachedClaudeLiveResult();
  const recentAge = recentLive?.updatedAt ? Date.now() - Date.parse(recentLive.updatedAt) : Infinity;
  if (recentLive && (recentAge < CLAUDE_FETCH_INTERVAL_MS || Date.now() < nextClaudeFetchAt)) return recentLive;

  if (Date.now() >= nextClaudeFetchAt) {
    try {
      const { usage, credentials } = await fetchClaudeOAuthUsage(claudeHome);
      const windows = liveClaudeWindows(usage);
      if (windows.length) {
        const result = {
          id: 'claude',
          name: 'Claude',
          installed: true,
          available: true,
          updatedAt: new Date().toISOString(),
          plan: credentials.subscriptionType ?? null,
          source: 'live',
          stale: false,
          windows,
          message: null
        };
        nextClaudeFetchAt = Date.now() + CLAUDE_FETCH_INTERVAL_MS;
        await saveClaudeLiveResult(result);
        return result;
      }
    } catch (error) {
      nextClaudeFetchAt = Date.now() + (error?.status === 429 ? 5 * 60 * 1000 : CLAUDE_FETCH_INTERVAL_MS);
    }
  }

  if (recentLive) {
    return {
      ...recentLive,
      source: 'recent-live-cache',
      stale: recentAge > CLAUDE_FETCH_INTERVAL_MS,
      message: '即時端點暫時無法更新，保留最後一次成功資料。'
    };
  }

  let cache;
  try {
    cache = JSON.parse(await fs.readFile(cachePath, 'utf8'));
  } catch {
    const credentialsPresent = await fs.access(path.join(claudeHome, '.credentials.json')).then(() => true).catch(() => false);
    return {
      id: 'claude',
      name: 'Claude',
      installed: Boolean(cliPath),
      available: false,
      source: 'unavailable',
      stale: false,
      setupRequired: Boolean(cliPath && !credentialsPresent),
      message: !cliPath && !credentialsPresent
        ? '這台電腦尚未安裝 Claude Code；若已安裝 Claude 桌面版，請先更新至含 Claude Code 的版本。'
        : cliPath && !credentialsPresent
          ? '已找到 Claude 桌面版／Claude Code，但尚未連結 Claude Code 帳號。請重新執行「啟動儀表板.bat」，並依提示完成授權。'
          : 'Claude Code 已登入，但暫時無法取得即時用量，也沒有可用的本機快取。',
      windows: []
    };
  }

  const rateLimits = cache.rate_limits ?? cache.rateLimits ?? {};
  return {
    id: 'claude',
    name: 'Claude',
    installed: true,
    available: Object.keys(rateLimits).length > 0,
    updatedAt: isoFromUnix(cache.fetchedAt ?? cache.fetched_at),
    plan: cache.plan ?? null,
    source: 'cache',
    stale: true,
    windows: Object.entries(rateLimits).map(([id, value]) => windowFromClaude(id, value)).filter(Boolean),
    message: Object.keys(rateLimits).length ? '即時查詢失敗，目前顯示本機舊快取。' : 'Claude 快取中還沒有額度資料。'
  };
}

// Antigravity：額度由執行中的 language_server 本機 API 提供（與 Antigravity 介面顯示同一來源）。
// 連接埠是隨機的、驗證碼在啟動參數裡，所以要先找到該程序；找到後快取，失敗才重找。
let antigravityConnection = null;
let nextAntigravityDiscoveryAt = 0;
let lastAntigravityResult = null;

function runPowerShell(script, timeoutMs = 15000) {
  return new Promise((resolve) => {
    const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { windowsHide: true });
    let output = '';
    const timer = setTimeout(() => child.kill(), timeoutMs);
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.on('error', () => { clearTimeout(timer); resolve(''); });
    child.on('close', () => { clearTimeout(timer); resolve(output); });
  });
}

// 程式名稱依版本可能是 language_server.exe 或 language_server_windows_x64.exe，用開頭比對
async function findAntigravityServer() {
  if (process.platform !== 'win32') return { found: false };
  const output = await runPowerShell(`
    $p = Get-CimInstance Win32_Process -Filter "Name LIKE 'language_server%'" | Where-Object { $_.CommandLine -match 'antigravity' } | Select-Object -First 1
    if ($p) { [pscustomobject]@{ cmd = $p.CommandLine; ports = @(Get-NetTCPConnection -State Listen -OwningProcess $p.ProcessId -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort) } | ConvertTo-Json -Compress }`);
  try {
    const found = JSON.parse(output);
    const token = String(found.cmd || '').match(/--csrf_token[= ](\S+)/)?.[1];
    return { found: true, token, ports: [].concat(found.ports ?? []).map(Number).filter(Boolean) };
  } catch { return { found: false }; }
}

function antigravityStatusRequest(port, token, secure = true) {
  const body = JSON.stringify({ metadata: { ideName: 'antigravity', extensionName: 'antigravity', locale: 'en' } });
  return new Promise((resolve, reject) => {
    // 只連 127.0.0.1；language_server 用自簽憑證，所以這一個請求不驗證憑證
    const request = (secure ? https : http).request({
      host: '127.0.0.1', port, method: 'POST', rejectUnauthorized: false, timeout: 5000,
      path: '/exa.language_server_pb.LanguageServerService/GetUserStatus',
      headers: { 'Content-Type': 'application/json', 'Connect-Protocol-Version': '1', 'X-Codeium-Csrf-Token': token, 'Content-Length': Buffer.byteLength(body) }
    }, (response) => {
      let data = '';
      response.on('data', (chunk) => { data += chunk; });
      response.on('end', () => {
        if (response.statusCode !== 200) return reject(new Error(`Antigravity status ${response.statusCode}`));
        try { resolve(JSON.parse(data)); } catch (error) { reject(error); }
      });
    });
    request.on('timeout', () => request.destroy(new Error('Antigravity timeout')));
    request.on('error', reject);
    request.end(body);
  });
}

// 最後一次失敗卡在哪一步，給畫面顯示：not-running／no-token／request-failed
let antigravityProblem = { kind: 'not-running', detail: '' };

async function fetchAntigravityStatus() {
  if (antigravityConnection) {
    try { return await antigravityStatusRequest(antigravityConnection.port, antigravityConnection.token, antigravityConnection.secure); }
    catch { antigravityConnection = null; }
  }
  // ponytail: 找程序要開 PowerShell（約 1 秒），Antigravity 沒開時最多每 30 秒找一次
  if (Date.now() < nextAntigravityDiscoveryAt) return null;
  nextAntigravityDiscoveryAt = Date.now() + 30 * 1000;
  const server = await findAntigravityServer();
  if (!server.found) { antigravityProblem = { kind: 'not-running', detail: '' }; return null; }
  if (!server.token) { antigravityProblem = { kind: 'no-token', detail: '' }; return null; }
  let lastError = server.ports.length ? '' : '沒有開啟任何連接埠';
  for (const port of server.ports) {
    for (const secure of [true, false]) {   // 通常是 HTTPS；不同版本可能是 HTTP
      try {
        const status = await antigravityStatusRequest(port, server.token, secure);
        antigravityConnection = { port, token: server.token, secure };
        return status;
      } catch (error) { lastError = error.message || String(error); }
    }
  }
  antigravityProblem = { kind: 'request-failed', detail: lastError };
  return null;
}

// 同一模型的 High/Medium/Low 共用額度，合併成一列，取用得最多的那個
export function antigravityWindows(userStatus) {
  const families = new Map();
  for (const config of userStatus?.cascadeModelConfigData?.clientModelConfigs ?? []) {
    const quota = config?.quotaInfo;
    if (!quota || !config.label) continue;
    // protobuf JSON 會省略 0：有 quotaInfo 卻沒有 remainingFraction 代表已用完
    const remaining = Math.min(1, Math.max(0, numberOrNull(quota.remainingFraction) ?? 0));
    const family = config.label.replace(/\s*\((?:high|medium|low|thinking)\)\s*$/i, '').trim();
    const previous = families.get(family);
    if (!previous || remaining < previous.remaining) families.set(family, { remaining, resetsAt: isoFromValue(quota.resetTime) });
  }
  return [...families.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([family, { remaining, resetsAt }]) => ({
      id: `ag-${family.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`,
      label: family,
      usedPercent: Math.round((1 - remaining) * 1000) / 10,
      remainingPercent: Math.round(remaining * 1000) / 10,
      windowMinutes: null,
      resetsAt
    }));
}

export async function readAntigravityUsage() {
  const base = { id: 'antigravity', name: 'Antigravity' };
  const installDir = await firstExistingPath([
    process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'Programs', 'antigravity') : null,
    process.env.ProgramFiles ? path.join(process.env.ProgramFiles, 'Antigravity') : null,
    process.env['ProgramFiles(x86)'] ? path.join(process.env['ProgramFiles(x86)'], 'Antigravity') : null,
    path.join(HOME, '.antigravity')
  ]);

  let status = null;
  try { status = await fetchAntigravityStatus(); } catch { /* 下面處理 */ }
  // 裝在不認得的位置也沒關係：只要找到執行中的 Antigravity 就算已安裝
  if (!installDir && !status && !lastAntigravityResult && antigravityProblem.kind === 'not-running') {
    return { ...base, installed: false, available: false, message: '這台電腦尚未安裝 Antigravity。', windows: [] };
  }
  const windows = antigravityWindows(status?.userStatus);
  if (windows.length) {
    lastAntigravityResult = {
      ...base, installed: true, available: true, source: 'live', stale: false, message: null,
      updatedAt: new Date().toISOString(),
      plan: status.userStatus?.planStatus?.planInfo?.planName ?? status.userStatus?.userTier?.name ?? null,
      windows
    };
    return lastAntigravityResult;
  }
  const problem = status ? '已連上 Antigravity，但它沒有回傳任何模型額度。' : {
    'not-running': '請先開啟 Antigravity；額度由執行中的 Antigravity 提供。',
    'no-token': '找到執行中的 Antigravity，但讀不到它的連線驗證資訊（可能是 Antigravity 版本不同）。',
    'request-failed': `找到 Antigravity 的背景服務，但查詢額度失敗（${antigravityProblem.detail}）。`
  }[antigravityProblem.kind];
  if (lastAntigravityResult) {
    return { ...lastAntigravityResult, source: 'recent-live-cache', stale: true, message: `${problem} 目前顯示最後一次取得的資料。` };
  }
  return { ...base, installed: true, available: false, message: problem, windows: [] };
}

export async function readAllUsage() {
  const [codex, claude, antigravity] = await Promise.allSettled([readCodexUsage(), readClaudeUsage(), readAntigravityUsage()]);
  const failure = (id, name, reason) => ({ id, name, available: false, windows: [], message: reason?.message || '讀取失敗' });
  return {
    generatedAt: new Date().toISOString(),
    providers: [
      codex.status === 'fulfilled' ? codex.value : failure('codex', 'Codex', codex.reason),
      claude.status === 'fulfilled' ? claude.value : failure('claude', 'Claude', claude.reason),
      antigravity.status === 'fulfilled' ? antigravity.value : failure('antigravity', 'Antigravity', antigravity.reason)
    ]
  };
}

export const testing = { isoFromUnix, windowFromCodex, windowFromClaude, individualCodexWindows, liveClaudeWindows, findClaudeCli, antigravityWindows };
