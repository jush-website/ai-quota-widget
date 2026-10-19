import { promises as fs, createWriteStream } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

// 檢查 GitHub 最新版本；使用者在小工具按「更新」才下載 MSI 並在背景安裝。
// 下載網址只來自這個 repo 的 Release 資料，不接受外部傳入。AI_QUOTA_UPDATE_FEED 只供測試改用本機假資料。
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FEED = process.env.AI_QUOTA_UPDATE_FEED || 'https://api.github.com/repos/jush-website/ai-quota-widget/releases/latest';
const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
const MSI_NAME = /^ai-quota-widget-v[\d.]+-windows\.msi$/;

export function compareVersions(a, b) {
  const pa = String(a).replace(/^v/, '').split('.').map(Number);
  const pb = String(b).replace(/^v/, '').split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff) return Math.sign(diff);
  }
  return 0;
}

const state = { current: null, latest: null, newer: false, managed: false, pageUrl: null, status: 'idle', error: null, checkedAt: null };
let msiUrl = null;

// 只有 MSI 安裝版（裝在 %LocalAppData%\Programs\ai-quota-widget）能直接換新；可攜版只提示去下載
function isMsiInstall() {
  const base = process.env.LOCALAPPDATA;
  return Boolean(base) && ROOT.toLowerCase() === path.join(base, 'Programs', 'ai-quota-widget').toLowerCase();
}

export function updateStatus() { return { ...state }; }

export async function checkForUpdate() {
  try { state.current = (await fs.readFile(path.join(ROOT, 'VERSION.txt'), 'utf8')).trim(); } catch { state.current = null; }
  state.managed = isMsiInstall();
  try {
    const response = await fetch(FEED, { headers: { 'User-Agent': 'ai-quota-widget', Accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`GitHub 回應 ${response.status}`);
    const release = await response.json();
    const latest = String(release.tag_name || '').replace(/^v/, '');
    const asset = (release.assets || []).find((item) => MSI_NAME.test(item.name || ''));
    msiUrl = asset?.browser_download_url ?? null;
    Object.assign(state, {
      latest: latest || null,
      newer: Boolean(latest && state.current) && compareVersions(latest, state.current) > 0,
      pageUrl: release.html_url ?? null,
      error: state.status === 'error' ? state.error : null
    });
  } catch (error) {
    if (state.status !== 'error') state.error = error.message || String(error);
  }
  state.checkedAt = new Date().toISOString();
  return updateStatus();
}

export function startUpdateChecks() {
  checkForUpdate();
  setInterval(checkForUpdate, CHECK_INTERVAL_MS).unref();
}

// 立刻回應，下載與安裝在背景進行；小工具之後輪詢狀態
export function installUpdate() {
  if (!state.managed) throw new Error('只有 MSI 安裝版能直接更新，請到 GitHub 下載新版。');
  if (!state.newer || !msiUrl) throw new Error('目前沒有可以安裝的新版。');
  if (state.status === 'downloading' || state.status === 'installing') return updateStatus();
  Object.assign(state, { status: 'downloading', error: null });
  (async () => {
    const dir = path.join(os.tmpdir(), 'ai-quota-widget-update');
    await fs.mkdir(dir, { recursive: true });
    const file = path.join(dir, `ai-quota-widget-v${state.latest}-windows.msi`);
    const response = await fetch(msiUrl, { headers: { 'User-Agent': 'ai-quota-widget' }, signal: AbortSignal.timeout(5 * 60 * 1000) });
    if (!response.ok) throw new Error(`下載失敗（${response.status}）`);
    await pipeline(Readable.fromWeb(response.body), createWriteStream(file));
    // MSI 是 OLE 複合檔，開頭固定是 D0 CF 11 E0；不是就不執行
    const handle = await fs.open(file);
    const head = Buffer.alloc(4);
    await handle.read(head, 0, 4, 0);
    await handle.close();
    if (head.toString('hex') !== 'd0cf11e0') throw new Error('下載的檔案不是安裝程式。');
    state.status = 'installing';
    // detached：安裝程式會先關掉這個伺服器，msiexec 不能被一起收掉；裝完由安裝程式重新開啟小工具
    spawn('msiexec.exe', ['/i', file, '/qn', '/l*v', path.join(dir, 'install.log')], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  })().catch((error) => Object.assign(state, { status: 'error', error: error.message || String(error) }));
  return updateStatus();
}
