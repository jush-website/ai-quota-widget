import test from 'node:test';
import assert from 'node:assert/strict';
import { testing } from '../src/usage.js';

const status = (configs) => ({ cascadeModelConfigData: { clientModelConfigs: configs } });

test('同一模型的 High/Medium/Low 合併成一列，取用得最多的', () => {
  const windows = testing.antigravityWindows(status([
    { label: 'Gemini 4 Argon (High)', quotaInfo: { remainingFraction: 0.9, resetTime: '2026-01-08T00:00:00Z' } },
    { label: 'Gemini 4 Argon (Low)', quotaInfo: { remainingFraction: 0.6, resetTime: '2026-01-08T00:00:00Z' } },
    { label: 'Claude Opus 5.5 (Medium)', quotaInfo: { remainingFraction: 1, resetTime: '2026-01-01T05:00:00Z' } }
  ]));
  assert.deepEqual(windows.map((w) => [w.label, w.usedPercent, w.remainingPercent]), [
    ['Claude Opus 5.5', 0, 100],
    ['Gemini 4 Argon', 40, 60]
  ]);
  assert.equal(windows[1].resetsAt, '2026-01-08T00:00:00.000Z');
});

test('protobuf 省略 0：有 quotaInfo 但沒有 remainingFraction 視為用完', () => {
  const [window] = testing.antigravityWindows(status([{ label: 'Gemini 3.8 Flash (High)', quotaInfo: { resetTime: '2026-01-01T05:00:00Z' } }]));
  assert.equal(window.usedPercent, 100);
});

test('沒有 quotaInfo 的模型略過；沒有資料回傳空陣列', () => {
  assert.deepEqual(testing.antigravityWindows(status([{ label: 'Some Model' }])), []);
  assert.deepEqual(testing.antigravityWindows(undefined), []);
});
