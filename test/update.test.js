import test from 'node:test';
import assert from 'node:assert/strict';
import { compareVersions } from '../src/update.js';

test('版本比較：逐段比數字，不是比字串', () => {
  assert.equal(compareVersions('1.0.18', '1.0.17'), 1);
  assert.equal(compareVersions('1.0.10', '1.0.9'), 1);    // 字串比較會錯在這裡
  assert.equal(compareVersions('v1.0.17', '1.0.17'), 0);  // GitHub tag 有 v 前綴
  assert.equal(compareVersions('1.0.16', '1.0.17'), -1);  // 舊版不能被當成新版
  assert.equal(compareVersions('1.1', '1.0.99'), 1);
  assert.equal(compareVersions('1.0', '1.0.0'), 0);
});
