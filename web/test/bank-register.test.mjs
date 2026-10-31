// Tests for scripts/load-bank-register.mjs (the monthly bank register loader). Sample files are made up.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { parseCsv, readXlsx, nzRows, auRows, auNames, toCsv } from '../../scripts/load-bank-register.mjs';

const dir = new URL('../../scripts/fixtures/bank-register/', import.meta.url);
const read = (f) => fs.readFileSync(new URL(f, dir));

test('reads the Payments NZ register from .xlsx', () => {
  const rows = nzRows(readXlsx(read('nz-register-sample.xlsx')), 'L1');
  assert.equal(rows.length, 3, 'blank and total rows are skipped');
  assert.deepEqual(rows[0], { Name: 'NZ-12-3140', Key__c: 'NZ-12-3140', Country__c: 'NZ', Bank_Code__c: '12', Bank_Name__c: 'Example Bank NZ', Branch_Name__c: 'Example Branch & Co', Load__c: 'L1' });
  assert.equal(rows[1].Branch_Name__c, 'Second Branch', 'spaces tidied');
  assert.equal(rows[2].Key__c, 'NZ-02-0242', 'bank and branch numbers zero-padded');
  assert.equal(rows[2].Branch_Name__c, 'Sample "Central"');
});

test('reads the NZ register from a .csv saved from it', () => {
  const rows = nzRows(parseCsv('Bank Number,Bank Name,Branch Number,Branch Information\r\n1,"Bank, One",1,Head Office\r\n'), 'L1');
  assert.equal(rows[0].Key__c, 'NZ-01-0001');
  assert.equal(rows[0].Bank_Name__c, 'Bank, One');
});

test('a register without the expected columns is refused', () => {
  assert.throws(() => nzRows([['Bank', 'Name']], 'L1'), /bank_number/);
});

test('reads the AusPayNet BSB directory, fixed-width and CSV', () => {
  const names = auNames(parseCsv(read('au-key-sample.csv').toString()));
  for (const [file, csv] of [['au-bsb-sample.txt', false], ['au-bsb-sample.csv', true]]) {
    const rows = auRows(read(file).toString(), csv, names, 'L1');
    assert.equal(rows.length, 2, file);
    assert.equal(rows[0].Key__c, 'AU-062-000');
    assert.equal(rows[0].Bank_Name__c, 'Example Bank of Australia', 'full name from the key file');
    assert.equal(rows[0].Payments__c, 'PEH');
    assert.equal(rows[1].Payments__c, 'P', 'no electronic payments');
    assert.equal(rows[1].Suburb__c, 'Parramatta');
  }
  assert.equal(auRows(read('au-bsb-sample.txt').toString(), false, new Map(), 'L1')[0].Bank_Name__c, 'EXB', 'mnemonic when there is no key file');
});

test('upload file quotes and trims to field lengths', () => {
  const csv = toCsv([{ Name: 'AU-062-000', Key__c: 'AU-062-000', Country__c: 'AU', Bank_Name__c: 'x'.repeat(100), Branch_Name__c: 'A, "B"', Load__c: 'L1' }]);
  const [header, line] = csv.trim().split('\n');
  assert.equal(header, 'Name,Key__c,Country__c,Bank_Code__c,Bank_Name__c,Branch_Name__c,Suburb__c,State__c,Payments__c,Load__c');
  assert.ok(line.includes('x'.repeat(80) + ','), 'bank name cut to 80');
  assert.ok(!line.includes('x'.repeat(81)));
  assert.ok(line.includes('"A, ""B"""'));
});
