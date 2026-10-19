const dashboard = document.querySelector('#dashboard');
const login = document.querySelector('#login');
const loginForm = document.querySelector('#login-form');
const loginError = document.querySelector('#login-error');
const status = document.querySelector('#status');
const updated = document.querySelector('#updated');
const nextRefresh = document.querySelector('#next-refresh');
const title = document.querySelector('#title');
let accessKey = sessionStorage.getItem('usage-access-key') || '';
let timer;
let countdownTimer;
let refreshMilliseconds = 60_000;
let nextRefreshAt = null;

function updateCountdown() {
  if (!nextRefreshAt) { nextRefresh.textContent = '下次更新 —'; return; }
  const seconds = Math.max(0, Math.ceil((nextRefreshAt - Date.now()) / 1000));
  nextRefresh.textContent = `下次更新 ${seconds} 秒`;
}

function scheduleRefresh() {
  clearTimeout(timer);
  nextRefreshAt = Date.now() + refreshMilliseconds;
  updateCountdown();
  timer = setTimeout(refresh, refreshMilliseconds);
}

const formatTime = (iso) => iso ? new Intl.DateTimeFormat('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date(iso)) : '未知';
const formatReset = (iso) => {
  if (!iso) return '重設時間未知';
  const diff = new Date(iso).getTime() - Date.now();
  if (diff <= 0) return '即將重設';
  const hours = Math.floor(diff / 3_600_000);
  const minutes = Math.floor((diff % 3_600_000) / 60_000);
  const relative = hours >= 24 ? `${Math.floor(hours / 24)} 天 ${hours % 24} 小時` : hours ? `${hours} 小時 ${minutes} 分` : `${Math.max(1, minutes)} 分`;
  return `${relative}後重設`;
};

const compactNumber = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return '—';
  if (number >= 1_000_000) return `${(number / 1_000_000).toFixed(number % 1_000_000 ? 1 : 0)}M`;
  if (number >= 1_000) return `${(number / 1_000).toFixed(1)}k`;
  return String(Math.round(number));
};

// 吉祥物：依額度變表情。Codex=雲朵終端機、Claude=像素螃蟹。
// ponytail: 全部內嵌 SVG，不依賴任何圖檔——複製 app.js + styles.css 到別台就完整呈現
// 雲朵外框：7 顆圓瓣 + 中心圓的聯集輪廓，轉成單一平滑路徑（一條 path 才能讓漸層連續流過整朵雲）
const CLOUD_D = 'M44.0 24.0C44.3 25.0 44.5 26.1 44.5 27.1C44.5 28.1 44.4 29.2 44.1 30.2C43.8 31.2 43.3 32.2 42.7 33.0C42.1 33.8 41.3 34.6 40.5 35.3C39.7 35.9 38.4 36.0 37.7 36.7C37.0 37.4 37.0 38.7 36.4 39.6C35.9 40.5 35.2 41.3 34.4 42.0C33.6 42.6 32.6 43.2 31.7 43.5C30.7 43.9 29.6 44.2 28.6 44.2C27.6 44.3 26.5 44.2 25.5 43.9C24.5 43.7 23.6 42.7 22.6 42.7C21.6 42.6 20.6 43.4 19.6 43.5C18.5 43.6 17.4 43.5 16.4 43.3C15.4 43.1 14.4 42.7 13.5 42.2C12.6 41.7 11.8 41.0 11.1 40.2C10.4 39.5 9.8 38.5 9.4 37.6C8.9 36.6 9.1 35.4 8.5 34.5C8.0 33.7 6.7 33.4 6.0 32.7C5.3 31.9 4.6 31.0 4.2 30.1C3.7 29.2 3.4 28.1 3.2 27.1C3.1 26.1 3.1 25.0 3.3 24.0C3.4 23.0 3.8 21.9 4.2 21.0C4.7 20.1 5.8 19.4 6.1 18.5C6.4 17.5 5.9 16.4 6.0 15.3C6.1 14.3 6.4 13.3 6.9 12.3C7.3 11.4 7.9 10.5 8.6 9.7C9.3 9.0 10.2 8.3 11.1 7.8C12.0 7.3 13.0 6.9 14.0 6.7C15.0 6.5 16.2 6.9 17.2 6.6C18.1 6.2 18.7 5.1 19.6 4.5C20.4 4.0 21.4 3.6 22.5 3.3C23.5 3.1 24.5 3.0 25.6 3.1C26.6 3.1 27.7 3.4 28.6 3.8C29.6 4.2 30.5 4.7 31.3 5.4C32.1 6.1 32.5 7.3 33.4 7.8C34.2 8.3 35.5 8.0 36.4 8.4C37.4 8.7 38.4 9.3 39.2 9.9C40.0 10.5 40.8 11.3 41.4 12.2C41.9 13.0 42.4 14.0 42.7 15.0C43.0 16.0 43.1 17.1 43.1 18.1C43.1 19.1 42.4 20.2 42.5 21.2C42.6 22.2 43.6 23.0 44.0 24.0Z';

const MOODS = {
  happy: '額度充足，心情很好',
  worried: '額度過半了，省著點用',
  panic: '額度快見底，牠開始發抖',
  idle: '還沒有額度資料，睡著了'
};

function moodOf(provider) {
  if (!provider.available || !provider.windows?.length) return 'idle';
  const used = provider.windows.reduce((max, w) => Math.max(max, w.usedPercent ?? 0), 0);
  return used >= 90 ? 'panic' : used >= 75 ? 'worried' : 'happy';  // 與長條四段一致：橘起擔心、紅起驚慌
}

function mascot(id, mood) {
  {
    const title = `<title>${MOODS[mood]}</title>`;
    if (id === 'codex') {
      const eyes = {
        happy: '<circle cx="18.5" cy="14.6" r="2.7"/><circle cx="29.5" cy="14.6" r="2.7"/>',
        worried: '<ellipse cx="18.5" cy="15.2" rx="2.7" ry="1.6"/><ellipse cx="29.5" cy="15.2" rx="2.7" ry="1.6"/>',
        panic: '<circle cx="18.5" cy="14.2" r="3.5"/><circle cx="29.5" cy="14.2" r="3.5"/><circle cx="18.5" cy="14.2" r="1.5" fill="#5a66f2"/><circle cx="29.5" cy="14.2" r="1.5" fill="#5a66f2"/>',
        idle: '<rect x="15.7" y="14.2" width="5.6" height="2" rx="1"/><rect x="26.7" y="14.2" width="5.6" height="2" rx="1"/>'
      }[mood];
      const sweat = mood === 'panic' ? '<ellipse class="sweat" cx="35.7" cy="10.9" rx="1.7" ry="2.4" fill="#fff" opacity=".9"/>' : '';
      return `<div class="mark mark-mascot"><svg class="mascot mascot-term" data-mood="${mood}" viewBox="0 0 48 48" role="img">${title}
        <defs><linearGradient id="cx-grad" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#a6a9f7"/><stop offset="1" stop-color="#4b5bf2"/></linearGradient></defs>
        <path fill="url(#cx-grad)" d="${CLOUD_D}"/>
        <g class="mascot-eye" fill="#fff">${eyes}</g>
        <path d="M17.8 21.5 L22 26.5 L17.8 31.5" fill="none" stroke="#fff" stroke-width="3.3" stroke-linecap="round" stroke-linejoin="round"/>
        <rect x="25" y="28" width="8" height="3.2" rx="1.6" fill="#fff"/>
        ${sweat}
      </svg></div>`;
    }
    if (id !== 'claude') return '';  // ponytail: Antigravity 還沒有吉祥物，需要時再畫
    const eyes = {
      happy: '<rect x="9.5" y="5" width="1.5" height="3.5"/><rect x="13" y="5" width="1.5" height="3.5"/>',
      worried: '<rect x="9.5" y="6.2" width="1.5" height="1.6"/><rect x="13" y="6.2" width="1.5" height="1.6"/>',
      panic: '<rect x="9" y="4.6" width="2.4" height="4.4"/><rect x="12.8" y="4.6" width="2.4" height="4.4"/>',
      idle: '<rect x="9" y="6.6" width="2.5" height="1"/><rect x="12.8" y="6.6" width="2.5" height="1"/>'
    }[mood];
    const sweat = mood === 'panic' ? '<rect class="sweat" x="19.5" y="2" width="1.6" height="2.2" fill="#8fd3f4"/>' : '';
    return `<div class="mark mark-mascot"><svg class="mascot mascot-crab" data-mood="${mood}" viewBox="0 0 24 16" shape-rendering="crispEdges" role="img">${title}
        <g fill="#d2794f">
          <rect x="6" y="3" width="12" height="9"/><rect x="3" y="6" width="3" height="2"/><rect x="18" y="6" width="3" height="2"/>
          <rect x="7" y="12" width="1.5" height="2.4"/><rect x="10" y="12" width="1.5" height="2.4"/><rect x="12.5" y="12" width="1.5" height="2.4"/><rect x="15.5" y="12" width="1.5" height="2.4"/>
        </g>
        <g class="mascot-eye" fill="#0e1011">${eyes}</g>
        ${sweat}
      </svg></div>`;
  }
}

function providerCard(provider) {
  const staleBadge = provider.stale ? '<span class="stale-badge">舊資料</span>' : '';
  const context = provider.context ? `<div class="context-window">
    <div class="window-top"><span class="window-title">Context window</span><span class="context-value">${compactNumber(provider.context.usedTokens)} / ${compactNumber(provider.context.limitTokens)} (${Math.round(provider.context.usedPercent)}%)</span></div>
    <div class="bar context-bar"><span style="width:${provider.context.usedPercent}%"></span></div>
  </div>` : '';
  const windows = provider.windows?.map((window) => {
    const used = Math.min(100, Math.max(0, window.usedPercent ?? 0));
    // 四段：綠 <50、黃 50–74、橘 75–89、紅 ≥90（與桌面小工具相同）
    const tone = used >= 90 ? 'danger' : used >= 75 ? 'warn' : used >= 50 ? 'half' : '';
    return `<div class="window">
      <div class="window-top"><span class="window-title">${escapeHtml(window.label)}</span><span class="percent">${Math.round(used)}%<small>已使用</small></span></div>
      <div class="bar ${tone}"><span style="width:${used}%"></span></div>
      <div class="window-bottom"><span>剩餘 ${Math.round(window.remainingPercent ?? 100)}%</span><span>${escapeHtml(formatReset(window.resetsAt))}</span></div>
    </div>`;
  }).join('') || '';
  // ponytail: credits-based Codex 帳號的 primary 會是 null，額度改放 credits.balance；沒補這塊就會整格空白
  const credits = provider.credits?.has_credits ? `<div class="window">
      <div class="window-top"><span class="window-title">購買額度 (Credits)</span><span class="percent">${provider.credits.unlimited ? '無限' : escapeHtml(String(provider.credits.balance ?? '—'))}<small>${provider.credits.unlimited ? '' : '餘額'}</small></span></div>
    </div>` : '';
  const body = context + windows + credits || `<div class="empty">${escapeHtml(provider.message || '目前沒有可顯示的額度資料')}</div>`;
  return `<article class="provider">
    <div class="provider-head"><div><span class="label">PROVIDER</span><h2>${escapeHtml(provider.name)}</h2><div class="plan">${escapeHtml(provider.plan || (provider.available ? 'CONNECTED' : 'WAITING FOR DATA'))} · 資料 ${escapeHtml(provider.updatedAt ? formatTime(provider.updatedAt) : '尚未取得')} ${staleBadge}</div></div>${mascot(provider.id, moodOf(provider))}</div>
    <div>${body}</div>
  </article>`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[character]);
}

async function refresh() {
  clearTimeout(timer);
  nextRefreshAt = null;
  nextRefresh.textContent = '正在更新…';
  try {
    const response = await fetch('/api/usage', { headers: accessKey ? { 'X-Access-Key': accessKey } : {}, cache: 'no-store' });
    if (response.status === 401) {
      login.classList.remove('hidden'); dashboard.classList.add('hidden'); status.textContent = '需要驗證'; status.classList.remove('online'); nextRefresh.textContent = '等待驗證'; return;
    }
    if (!response.ok) throw new Error((await response.json()).error || '連線失敗');
    const data = await response.json();
    login.classList.add('hidden'); dashboard.classList.remove('hidden');
    dashboard.innerHTML = data.providers.map(providerCard).join('');
    const setupRequired = data.providers.some((provider) => provider.setupRequired);
    const hasUnavailableData = data.providers.some((provider) => !provider.available);
    const hasStaleData = data.providers.some((provider) => provider.stale);
    const needsAttention = setupRequired || hasUnavailableData || hasStaleData;
    status.textContent = setupRequired ? '需要設定' : hasUnavailableData ? '部分資料無法取得' : hasStaleData ? '含舊資料' : '即時連線';
    status.classList.toggle('online', !needsAttention); status.classList.toggle('warning', needsAttention);
    updated.textContent = `更新於 ${formatTime(data.generatedAt)}`;
  } catch (error) {
    status.textContent = '連線中斷'; status.classList.remove('online');
    updated.textContent = error.message;
  }
  scheduleRefresh();
}

loginForm.addEventListener('submit', (event) => {
  event.preventDefault();
  accessKey = document.querySelector('#access-key').value;
  sessionStorage.setItem('usage-access-key', accessKey);
  loginError.textContent = '';
  refresh().then(() => { if (!login.classList.contains('hidden')) loginError.textContent = '密碼不正確，請再試一次。'; });
});

fetch('/api/config').then((response) => response.json()).then((config) => {
  title.textContent = config.displayName;
  document.title = config.displayName;
  refreshMilliseconds = Math.max(10, Number(config.refreshSeconds) || 60) * 1000;
  if (config.requiresAccessKey && !accessKey) { login.classList.remove('hidden'); dashboard.classList.add('hidden'); status.textContent = '需要驗證'; }
  else refresh();
}).catch(() => refresh());

countdownTimer = setInterval(updateCountdown, 1000);
