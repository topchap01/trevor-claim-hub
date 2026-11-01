// Server-only: invoice files kept outside Salesforce, whose file storage is full (decisions.md #6).
//
// Where files go, first match wins:
//   1. Amazon S3, when S3_BUCKET_NAME, S3_REGION and AWS_ROLE_ARN are set. The web app signs in to AWS through
//      Vercel's OIDC federation, so no AWS key is stored anywhere (runbook: "Invoice storage on S3").
//   2. Vercel Blob, when BLOB_READ_WRITE_TOKEN is set (the sandbox until S3 is switched on).
//   3. Neither: the claim route sends the file to Salesforce Files as before.
//
// Salesforce only ever sees the key `invoices/<first 24 hex of sha256(link code)>/<name>`. ClaimHubService refuses
// any other shape, so the key layout must not change. S3_KEY_PREFIX (for example `sandbox/`) is added in front of
// the key inside the bucket only, so test files and real ones can share a bucket and still be kept apart by IAM
// and by lifecycle rules.
import crypto from 'node:crypto';
import { put, get, del } from '@vercel/blob';
import {
  S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand, DeleteObjectsCommand, ListObjectsV2Command, PutObjectTaggingCommand,
} from '@aws-sdk/client-s3';
import { awsCredentialsProvider } from '@vercel/oidc-aws-credentials-provider';

const TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' }; // what Claude can read

const env = () => process.env;
export const s3Enabled = () => !!(env().S3_BUCKET_NAME && env().S3_REGION && env().AWS_ROLE_ARN);
const blobConfigured = () => !!env().BLOB_READ_WRITE_TOKEN;
/** True when invoices are kept outside Salesforce (S3 or Blob). */
export const fileStoreEnabled = () => s3Enabled() || blobConfigured();
/** Which store new invoices go to: 's3', 'blob' or 'salesforce'. */
export const fileStore = () => (s3Enabled() ? 's3' : blobConfigured() ? 'blob' : 'salesforce');

/** The folder for a claim's files. Holds a hash of the claim link, never the link itself. */
export const invoiceFolder = (token) => `invoices/${crypto.createHash('sha256').update(token).digest('hex').slice(0, 24)}/`;

/** The object's name inside the bucket: the optional prefix plus the key Salesforce stores. */
export function objectKey(key) {
  const prefix = (env().S3_KEY_PREFIX || '').replace(/^\/+/, '');
  return prefix && !prefix.endsWith('/') ? `${prefix}/${key}` : `${prefix}${key}`;
}

let s3Client;
let s3ClientFor;
function s3() {
  const { S3_REGION: region, AWS_ROLE_ARN: roleArn } = env();
  const id = `${region}|${roleArn}`;
  if (!s3Client || s3ClientFor !== id) {
    s3Client = new S3Client({
      region,
      maxAttempts: 3,
      credentials: awsCredentialsProvider({ roleArn, roleSessionName: 'trevor-claim-hub', clientConfig: { region } }),
    });
    s3ClientFor = id;
  }
  return s3Client;
}

/** Tests only: replace the S3 client. Pass null to go back to the real one. */
export function setS3ClientForTests(client) {
  s3Client = client;
  s3ClientFor = client ? `${env().S3_REGION}|${env().AWS_ROLE_ARN}` : undefined;
}

const isNotFound = (err) => err?.name === 'NoSuchKey' || err?.name === 'NotFound' || err?.$metadata?.httpStatusCode === 404;

// S3 files are named <uuid>.<ext>; Blob files were invoice-<random>.<ext>. The name says which store holds a file,
// so invoices uploaded to Blob before S3 was switched on (sandbox only) still open, and no error is ever read as
// "try the other store". S3 also answers 403, not 404, for a missing file unless the role may list the bucket.
const S3_NAME = /\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z]+$/;
/** Which store holds an existing file: 's3' or 'blob'. */
export const storeOf = (key) => (S3_NAME.test(key) ? 's3' : 'blob');

/** Stores the file privately and returns the key Salesforce keeps. */
export async function storeInvoice(token, base64, contentType) {
  const ext = TYPES[contentType];
  if (!ext) throw Object.assign(new Error('Please upload a photo (JPEG or PNG) or a PDF.'), { status: 415 });
  const body = Buffer.from(base64, 'base64');
  if (s3Enabled()) {
    const key = `${invoiceFolder(token)}${crypto.randomUUID()}.${ext}`;
    await s3().send(new PutObjectCommand({
      Bucket: env().S3_BUCKET_NAME,
      Key: objectKey(key),
      Body: body,
      ContentType: contentType,
      CacheControl: 'private, no-store',
      // The SDK adds a CRC32 checksum by default, so S3 refuses a file damaged on the way
    }));
    return key;
  }
  const blob = await put(`${invoiceFolder(token)}invoice.${ext}`, body, { access: 'private', contentType, addRandomSuffix: true });
  return blob.pathname;
}

/** Removes a file just stored, when Salesforce refused the claim step. Never throws. */
export async function removeFile(key) {
  try {
    if (storeOf(key) === 's3') { if (s3Enabled()) await s3().send(new DeleteObjectCommand({ Bucket: env().S3_BUCKET_NAME, Key: objectKey(key) })); }
    else if (blobConfigured()) await del(key);
  } catch (err) { console.error('invoice delete failed', err.name || err.message); }
}

/** Opens a stored file for the staff viewer. Returns { stream, contentType }, or null when there is no such file. */
export async function readFile(key) {
  if (storeOf(key) === 's3') {
    if (!s3Enabled()) return null;
    try {
      const r = await s3().send(new GetObjectCommand({ Bucket: env().S3_BUCKET_NAME, Key: objectKey(key) }));
      return { stream: r.Body.transformToWebStream(), contentType: r.ContentType };
    } catch (err) {
      if (isNotFound(err)) return null;
      throw err;
    }
  }
  if (!blobConfigured()) return null;
  const file = await get(key, { access: 'private' });
  if (!file || file.statusCode !== 200) return null;
  return { stream: file.stream, contentType: file.blob?.contentType };
}

// ------------------------------------------------------------------ storage management (decisions.md #17)

/** Where the invoice files are, for the nightly check's record: bucket/prefix/invoices/. */
export const storeName = () => `${env().S3_BUCKET_NAME}/${objectKey('invoices/')}`;

/**
 * Labels a stored file with its campaign, once Salesforce has accepted it, so the bucket describes itself without
 * Salesforce. A campaign slug only, never personal data. Best effort: a missing label never fails a claim.
 */
export async function labelCampaign(key, slug) {
  if (!s3Enabled() || storeOf(key) !== 's3' || !/^[a-z0-9-]{3,80}$/.test(slug || '')) return false;
  try {
    await s3().send(new PutObjectTaggingCommand({
      Bucket: env().S3_BUCKET_NAME, Key: objectKey(key), Tagging: { TagSet: [{ Key: 'campaign', Value: slug }] },
    }));
    return true;
  } catch (err) { console.error('invoice label failed', err.name || err.message); return false; }
}

/** Every stored invoice file in S3: { key (as Salesforce holds it), size, at }. Pages through the bucket 1,000 at a time. */
export async function* listStored() {
  const prefix = objectKey('invoices/');
  const strip = prefix.length - 'invoices/'.length;
  let token;
  do {
    const r = await s3().send(new ListObjectsV2Command({ Bucket: env().S3_BUCKET_NAME, Prefix: prefix, ContinuationToken: token }));
    for (const o of r.Contents || []) yield { key: o.Key.slice(strip), size: o.Size || 0, at: o.LastModified ? new Date(o.LastModified) : null };
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token);
}

/** Deletes S3 files by key, 1,000 per request. Returns the keys deleted and the keys S3 refused. */
export async function deleteStored(keys) {
  const deleted = [], failed = [];
  const list = keys.filter((k) => storeOf(k) === 's3');
  for (let i = 0; i < list.length; i += 1000) {
    const batch = list.slice(i, i + 1000);
    const r = await s3().send(new DeleteObjectsCommand({
      Bucket: env().S3_BUCKET_NAME, Delete: { Objects: batch.map((k) => ({ Key: objectKey(k) })), Quiet: true },
    }));
    const bad = new Set((r.Errors || []).map((e) => e.Key));
    for (const k of batch) (bad.has(objectKey(k)) ? failed : deleted).push(k);
  }
  return { deleted, failed };
}
