import test from 'node:test';
import assert from 'node:assert/strict';
import { testing } from '../src/usage.js';

const now = Date.parse('2026-01-03T00:00:00Z');
const fromLogs = {
  id: 'codex', name: 'Codex', installed: true, available: true, updatedAt: '2026-01-01T00:00:00Z',
  windows: [
    { id: 'primary', label: '5 小時額度', usedPercent: 47, remainingPercent: 53, resetsAt: '2026-01-01T05:00:00Z' },
    { id: 'secondary', label: '每週 · 所有模型', usedPercent: 35, remainingPercent: 65, resetsAt: '2026-01-07T00:00:00Z' }
  ]
};

test('憑證過期：標成舊資料並說明怎麼恢復', () => {
  const result = testing.codexLogFallback(fromLogs, Object.assign(new Error('401'), { status: 401 }), now);
  assert.equal(result.stale, true);
  assert.equal(result.source, 'logs');
  assert.match(result.message, /登入憑證已過期/);
  assert.match(result.message, /開啟 Codex/);
  // 有提醒但不跳通知：不用登入，下次開 Codex 就會自己恢復
  assert.deepEqual([result.attention.action, result.attention.notify], ['open-codex', false]);
  assert.equal(testing.codexLogFallback(fromLogs, new Error('network'), now).attention, undefined);
});

test('已過重置時間的額度以 0% 顯示，還沒重置的保留原值', () => {
  const [fiveHour, weekly] = testing.codexLogFallback(fromLogs, null, now).windows;
  assert.deepEqual([fiveHour.usedPercent, fiveHour.remainingPercent, fiveHour.resetPassed, fiveHour.resetsAt], [0, 100, true, null]);
  assert.deepEqual([weekly.usedPercent, weekly.resetsAt], [35, '2026-01-07T00:00:00Z']);
});

test('沒有紀錄可用時原樣回傳', () => {
  const missing = { id: 'codex', name: 'Codex', installed: true, available: false, windows: [] };
  assert.equal(testing.codexLogFallback(missing, null, now), missing);
});
