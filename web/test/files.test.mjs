// Unit tests for invoice storage outside Salesforce (decisions.md #6). S3 is replaced by a fake; nothing leaves the machine.
// Run: npm test
import { test, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {
  storeInvoice, readFile, removeFile, objectKey, invoiceFolder, storeOf, fileStore, fileStoreEnabled, s3Enabled, setS3ClientForTests,
  labelCampaign, listStored, deleteStored, storeName,
} from '../lib/files.js';

const TOKEN = 'B'.repeat(43);
const FOLDER = `invoices/${crypto.createHash('sha256').update(TOKEN).digest('hex').slice(0, 24)}/`;
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString('base64');
const KEYS = ['S3_BUCKET_NAME', 'S3_REGION', 'AWS_ROLE_ARN', 'S3_KEY_PREFIX', 'BLOB_READ_WRITE_TOKEN'];
const saved = Object.fromEntries(KEYS.map((k) => [k, process.env[k]]));

// A stand-in for S3 that keeps objects in memory and records each call.
function fakeS3() {
  const objects = new Map();
  const calls = [];
  return {
    objects, calls,
    async send(cmd) {
      const op = cmd.constructor.name;
      calls.push({ op, input: cmd.input });
      if (op === 'PutObjectCommand') { objects.set(cmd.input.Key, { body: cmd.input.Body, type: cmd.input.ContentType, at: new Date() }); return {}; }
      if (op === 'PutObjectTaggingCommand') { objects.get(cmd.input.Key).tags = cmd.input.Tagging.TagSet; return {}; }
      if (op === 'DeleteObjectsCommand') {
        const Errors = [];
        for (const { Key } of cmd.input.Delete.Objects) { if (Key.includes('dead')) Errors.push({ Key, Code: 'AccessDenied' }); else objects.delete(Key); }
        return { Errors };
      }
      if (op === 'ListObjectsV2Command') {
        // Two keys per page, to exercise paging
        const all = [...objects.keys()].filter((k) => k.startsWith(cmd.input.Prefix)).sort();
        const start = Number(cmd.input.ContinuationToken || 0);
        const page = all.slice(start, start + 2);
        return { Contents: page.map((Key) => ({ Key, Size: objects.get(Key).body.length, LastModified: objects.get(Key).at })),
          IsTruncated: start + 2 < all.length, NextContinuationToken: String(start + 2) };
      }
      if (op === 'DeleteObjectCommand') { objects.delete(cmd.input.Key); return {}; }
      if (op === 'GetObjectCommand') {
        const o = objects.get(cmd.input.Key);
        if (!o) throw Object.assign(new Error('The specified key does not exist.'), { name: 'NoSuchKey', $metadata: { httpStatusCode: 404 } });
        return { ContentType: o.type, Body: { transformToWebStream: () => new Response(o.body).body } };
      }
      throw new Error(`unexpected ${op}`);
    },
  };
}

const withS3 = (prefix) => {
  Object.assign(process.env, { S3_BUCKET_NAME: 'trevor-claim-hub', S3_REGION: 'ap-southeast-2', AWS_ROLE_ARN: 'arn:aws:iam::000000000000:role/test' });
  if (prefix === undefined) delete process.env.S3_KEY_PREFIX; else process.env.S3_KEY_PREFIX = prefix;
  const s3 = fakeS3();
  setS3ClientForTests(s3);
  return s3;
};

beforeEach(() => { for (const k of KEYS) delete process.env[k]; setS3ClientForTests(null); });
after(() => { for (const k of KEYS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; } setS3ClientForTests(null); });

test('store choice: S3 needs bucket, region and role; Blob is next; otherwise Salesforce', () => {
  assert.equal(fileStore(), 'salesforce');
  assert.equal(fileStoreEnabled(), false);
  process.env.BLOB_READ_WRITE_TOKEN = 'x';
  assert.equal(fileStore(), 'blob');
  process.env.S3_BUCKET_NAME = 'trevor-claim-hub';
  process.env.S3_REGION = 'ap-southeast-2';
  assert.equal(s3Enabled(), false, 'no role, no S3: a half-set S3 must not take over from Blob');
  process.env.AWS_ROLE_ARN = 'arn:aws:iam::000000000000:role/test';
  assert.equal(fileStore(), 's3');
  assert.equal(fileStoreEnabled(), true);
});

test('the key Salesforce keeps is in the claim\'s own folder and never holds the link code', async () => {
  const s3 = withS3();
  const key = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  assert.ok(key.startsWith(FOLDER), 'ClaimHubService refuses keys outside invoices/<hash>/');
  assert.equal(key.startsWith(invoiceFolder(TOKEN)), true);
  assert.match(key, /^invoices\/[0-9a-f]{24}\/[0-9a-f-]{36}\.jpg$/);
  assert.ok(!key.includes(TOKEN));
  const put = s3.calls[0];
  assert.equal(put.op, 'PutObjectCommand');
  assert.equal(put.input.Bucket, 'trevor-claim-hub');
  assert.equal(put.input.Key, key, 'no prefix set: object name is the key');
  assert.equal(put.input.ContentType, 'image/jpeg');
  assert.deepEqual(put.input.Body, Buffer.from(JPEG, 'base64'));
});

test('two uploads on one claim never overwrite each other', async () => {
  withS3();
  const a = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  const b = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  assert.notEqual(a, b);
});

test('prefix goes on the object name only, with or without its slash', async () => {
  for (const prefix of ['sandbox/', 'sandbox', '/sandbox/']) {
    const s3 = withS3(prefix);
    const key = await storeInvoice(TOKEN, JPEG, 'application/pdf');
    assert.ok(key.startsWith(FOLDER), 'Salesforce still gets the bare key');
    assert.equal(s3.calls[0].input.Key, `sandbox/${key}`);
    assert.equal(objectKey(key), `sandbox/${key}`);
  }
});

test('refuses file types Claude cannot read, before anything is stored', async () => {
  const s3 = withS3();
  await assert.rejects(storeInvoice(TOKEN, JPEG, 'text/html'), (e) => e.status === 415);
  await assert.rejects(storeInvoice(TOKEN, JPEG, 'image/svg+xml'), (e) => e.status === 415);
  assert.equal(s3.calls.length, 0);
});

test('read: returns the file and its type; a missing file is null, not an error', async () => {
  withS3('sandbox/');
  const key = await storeInvoice(TOKEN, JPEG, 'image/png');
  const file = await readFile(key);
  assert.equal(file.contentType, 'image/png');
  const bytes = Buffer.from(await new Response(file.stream).arrayBuffer());
  assert.deepEqual(bytes, Buffer.from(JPEG, 'base64'));
  assert.equal(await readFile(`${FOLDER}${crypto.randomUUID()}.jpg`), null);
});

test('read: S3 faults other than not-found are not hidden as a missing file', async () => {
  withS3();
  setS3ClientForTests({ send: async () => { throw Object.assign(new Error('Access Denied'), { name: 'AccessDenied', $metadata: { httpStatusCode: 403 } }); } });
  await assert.rejects(readFile(`${FOLDER}${crypto.randomUUID()}.jpg`), /Access Denied/);
});

test('remove: deletes the object under its prefix, and never throws', async () => {
  const s3 = withS3('sandbox/');
  const key = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  await removeFile(key);
  assert.equal(s3.objects.size, 0);
  assert.equal(s3.calls.at(-1).input.Key, `sandbox/${key}`);
  setS3ClientForTests({ send: async () => { throw new Error('network down'); } });
  await assert.doesNotReject(removeFile(key));
});

test('read with no store configured finds nothing', async () => {
  assert.equal(await readFile(`${FOLDER}x.jpg`), null);
});

test('the file name says which store holds it, so older Blob files never go to S3', async () => {
  const blobKey = `${FOLDER}invoice-AbC123xYz.jpg`;
  assert.equal(storeOf(blobKey), 'blob');
  const s3 = withS3();
  const key = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  assert.equal(storeOf(key), 's3');
  s3.calls.length = 0;
  assert.equal(await readFile(blobKey), null, 'no Blob token: nothing to read');
  await removeFile(blobKey);
  assert.equal(s3.calls.length, 0, 'S3 is never asked for a Blob file');
});

test('an S3 file with S3 switched off reads as missing', async () => {
  assert.equal(await readFile(`${FOLDER}${crypto.randomUUID()}.pdf`), null);
});

test('label: tags an S3 file with its campaign, and only a real slug on an S3 file', async () => {
  const s3 = withS3('sandbox/');
  const key = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  assert.equal(await labelCampaign(key, 'aeg-nz-cashback'), true);
  assert.deepEqual(s3.objects.get(`sandbox/${key}`).tags, [{ Key: 'campaign', Value: 'aeg-nz-cashback' }]);
  assert.equal(await labelCampaign(key, 'Bad Slug!'), false, 'never anything but a slug');
  assert.equal(await labelCampaign(`${FOLDER}invoice-AbC.jpg`, 'aeg-nz-cashback'), false, 'Blob files are left alone');
  setS3ClientForTests({ send: async () => { throw new Error('denied'); } });
  assert.equal(await labelCampaign(key, 'aeg-nz-cashback'), false, 'a failed label never throws');
});

test('list: every file under the prefix, as Salesforce knows the key, across pages', async () => {
  const s3 = withS3('sandbox/');
  const keys = [];
  for (let i = 0; i < 5; i++) keys.push(await storeInvoice(TOKEN, JPEG, 'image/jpeg'));
  s3.objects.set('other/invoices/x.jpg', { body: Buffer.from('x'), at: new Date() });
  const listed = [];
  for await (const f of listStored()) listed.push(f);
  assert.deepEqual(listed.map((f) => f.key).sort(), keys.sort());
  assert.equal(listed[0].size, Buffer.from(JPEG, 'base64').length);
  assert.ok(listed[0].at instanceof Date);
  assert.equal(storeName(), 'trevor-claim-hub/sandbox/invoices/');
});

test('bulk delete: removes S3 files, reports refusals, never touches Blob keys', async () => {
  const s3 = withS3('sandbox/');
  const a = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  const b = await storeInvoice(TOKEN, JPEG, 'image/jpeg');
  const refused = `${FOLDER}00000000-0000-4000-8000-dead00000000.jpg`; // the fake S3 refuses this one
  const r = await deleteStored([a, b, refused, `${FOLDER}invoice-AbC.jpg`]);
  assert.deepEqual(r.deleted.sort(), [a, b].sort());
  assert.deepEqual(r.failed, [refused]);
  assert.equal(s3.objects.size, 0);
  assert.ok(!s3.calls.at(-1).input.Delete.Objects.some((o) => o.Key.includes('invoice-AbC')), 'Blob keys never sent to S3');
});
