// Unit tests for the cashback maths and formatting the claim form shows as people type.
// Run: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { money, tierAmount, bestTier, when } from '../lib/client.js';

test('money: whole dollars without cents, cents when needed, NZ prefix', () => {
  assert.equal(money(1000, 'AU'), '$1,000');
  assert.equal(money(659.7, 'NZ'), 'NZ$659.70');
  assert.equal(money(null), '');
});

test('tierAmount: fixed amounts, percentages and the cap', () => {
  assert.equal(tierAmount({ amount: 250 }, 9999), 250);
  assert.equal(tierAmount({ percent: 15 }, 4398), 659.7);
  assert.equal(tierAmount({ percent: 20 }, 5697), 1139.4);
  assert.equal(tierAmount({ percent: 20 }, 10000, 1500), 1500);
});

test('bestTier: picks the best tier the basket qualifies for', () => {
  const tiers = [
    { minQty: 2, maxQty: 2, percent: 15 },
    { minQty: 3, percent: 20 },
  ];
  assert.equal(bestTier(tiers, 1, 2000, 2), undefined, 'one appliance does not qualify');
  assert.equal(bestTier(tiers, 2, 4398, 2).pays, 659.7);
  assert.equal(bestTier(tiers, 3, 5697, 2).pays, 1139.4);
  const bySpend = [{ minSpend: 5000, amount: 500 }, { minSpend: 10000, amount: 1000 }];
  assert.equal(bestTier(bySpend, 3, 4999, 1), undefined, 'under the minimum spend');
  assert.equal(bestTier(bySpend, 3, 10096, 1).pays, 1000);
});

test('when: dates in the promotion time zone', () => {
  assert.equal(when('2027-01-31T10:59:00Z', 'Pacific/Auckland'), '11:59pm 31 January 2027');
  assert.equal(when('2027-01-31T10:59:00Z', 'Pacific/Auckland', false), '31 January 2027');
});

test('bankPrefix: six digits from the NZ account or the AU BSB', async () => {
  const { bankPrefix } = await import('../lib/client.js');
  assert.equal(bankPrefix('NZ', { account: '12-3140-02' }), '123140');
  assert.equal(bankPrefix('NZ', { account: '12-314' }), null);
  assert.equal(bankPrefix('AU', { bsb: '062-000', account: '' }), '062000');
  assert.equal(bankPrefix('AU', { bsb: '06200' }), null);
  assert.equal(bankPrefix('AU', {}), null);
});

test('bankLine: names the bank, warns when it is unknown, quiet without a register', async () => {
  const { bankLine } = await import('../lib/client.js');
  assert.deepEqual(bankLine('NZ', { found: true, bankName: 'ASB Bank', branchName: 'Queen Street', electronic: true }), { ok: true, text: 'ASB Bank, Queen Street' });
  assert.equal(bankLine('AU', { found: true, bankName: 'Example Bank', branchName: 'Paper', electronic: false }).ok, false);
  assert.equal(bankLine('NZ', { found: false, registerLoaded: true }).ok, false);
  const closed = bankLine('AU', { found: true, bankName: 'CBA', branchName: 'Closed', electronic: true, closed: true });
  assert.equal(closed.ok, false);
  assert.match(closed.text, /listed as closed/);
  assert.equal(bankLine('NZ', { found: false, registerLoaded: false }), null);
  assert.equal(bankLine('AU', null), null);
});

test('splitStreet: street number and name, as C4C takes them', async () => {
  const { splitStreet } = await import('../lib/client.js');
  assert.deepEqual(splitStreet('12 Example Street'), { unit: '', streetNumber: '12', street: 'Example Street' });
  assert.deepEqual(splitStreet('  12A   Example  St '), { unit: '', streetNumber: '12A', street: 'Example St' });
  assert.deepEqual(splitStreet('12 - 14 Example Road'), { unit: '', streetNumber: '12-14', street: 'Example Road' });
  assert.deepEqual(splitStreet('4/12 Example Street'), { unit: '4', streetNumber: '12', street: 'Example Street' });
  assert.deepEqual(splitStreet('G02 / 7 Example Lane'), { unit: 'G02', streetNumber: '7', street: 'Example Lane' });
  assert.deepEqual(splitStreet('Lot 5 Example Road'), { unit: '', streetNumber: 'Lot 5', street: 'Example Road' });
  assert.deepEqual(splitStreet('12, Example Street'), { unit: '', streetNumber: '12', street: 'Example Street' });
  assert.equal(splitStreet('Example Street'), null, 'no street number');
  assert.equal(splitStreet('12'), null, 'no street name');
  assert.equal(splitStreet(''), null);
});

test('addressFor: checks the address before it is sent', async () => {
  const { addressFor } = await import('../lib/client.js');
  const regions = [{ value: 'NSW', label: 'New South Wales' }];
  const ok = { line: '4/12 Example Street', unit: '', suburb: 'Testville ', postcode: '2000', state: 'NSW' };
  assert.deepEqual(addressFor(ok, regions).address, { unit: '4', streetNumber: '12', street: 'Example Street', suburb: 'Testville', postcode: '2000', state: 'NSW' });
  assert.equal(addressFor({ ...ok, unit: 'Unit 9' }, regions).address.unit, 'Unit 9', 'the unit field wins');
  assert.match(addressFor({ ...ok, line: '' }, regions).error, /street address/);
  assert.match(addressFor({ ...ok, line: 'Example Street' }, regions).error, /street number/);
  assert.match(addressFor({ ...ok, suburb: ' ' }, regions).error, /suburb/);
  assert.match(addressFor({ ...ok, postcode: '200' }, regions).error, /4 digits/);
  assert.match(addressFor({ ...ok, state: 'VIC' }, regions).error, /state/);
});
