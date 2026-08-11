import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import assert from 'node:assert/strict';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(
  resolve(here, '../htdocs/luci-static/resources/view/services/istoreos-sms.js'),
  'utf8',
);

new Function(source);

const helperSource = source.split('\nreturn view.extend({', 1)[0];
const helpers = new Function(
  `${helperSource}\nreturn { parseCnmi, parseStatus, parseMessages };`,
)();

assert.deepEqual(helpers.parseCnmi('+CNMI: 2,1,0,0,0\r\nOK'), {
  value: '2,1,0,0,0',
  healthy: true,
  raw: '+CNMI: 2,1,0,0,0\r\nOK',
});
assert.equal(helpers.parseCnmi('+CNMI: 3,2,1,1,1').healthy, false);
assert.deepEqual(helpers.parseStatus('Storage type: SM, used: 1, total: 50'), {
  used: 1,
  total: 50,
  raw: 'Storage type: SM, used: 1, total: 50',
});

const messages = helpers.parseMessages(JSON.stringify({
  msg: [
    { index: 2, sender: '+8613800000000', timestamp: '2026-08-11 10:00:02', reference: 9, part: 2, total: 2, content: '世界' },
    { index: 1, sender: '+8613800000000', timestamp: '2026-08-11 10:00:01', reference: 9, part: 1, total: 2, content: '你好' },
    { index: 3, sender: '10010', timestamp: '2026-08-11 11:00:00', content: '测试短信' },
  ],
}));

assert.equal(messages.length, 2);
assert.equal(messages[0].sender, '10010');
assert.equal(messages[1].content, '你好世界');
assert.equal(messages[1].segments, 2);
assert.equal(messages[1].total, 2);

console.log('LuCI view syntax and helpers: PASS');
