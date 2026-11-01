// Tests for scripts/wizard.mjs argument handling (the command chats use to reach the Wizard sandbox).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from '../../scripts/wizard.mjs';

test('query, tooling-query and describe take the rest of the line as the body', () => {
  assert.deepEqual(parseArgs(['query', 'SELECT Id FROM Entry__c', 'LIMIT 5']), { kind: 'query', body: 'SELECT Id FROM Entry__c LIMIT 5' });
  assert.deepEqual(parseArgs(['tooling-query', 'SELECT Name FROM ApexClass']), { kind: 'tooling-query', body: 'SELECT Name FROM ApexClass' });
  assert.deepEqual(parseArgs(['describe', 'Entry__c']), { kind: 'describe', body: 'Entry__c' });
});

test('apex reads a file when given one, otherwise runs the text', () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wiz-')), 'x.apex');
  fs.writeFileSync(file, 'System.debug(42);');
  assert.equal(parseArgs(['apex', file]).body, 'System.debug(42);');
  assert.equal(parseArgs(['apex', 'System.debug(1);']).body, 'System.debug(1);');
});

test('unknown kinds and missing bodies are refused', () => {
  assert.equal(parseArgs(['delete', 'everything']), null);
  assert.equal(parseArgs(['query']), null);
  assert.equal(parseArgs([]), null);
});
