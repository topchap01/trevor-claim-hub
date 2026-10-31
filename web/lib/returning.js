// Coming back to a claim. The claim link is the only credential a claimant has, and people lose emails,
// so the hub remembers the claim on the phone it was made or opened on, in a secure cookie per promotion.
// The promotion page then shows "Welcome back" with a button to the claim, instead of the claim form alone.
// No server or framework imports here, so the rules are unit-tested on their own (test/returning.test.mjs).

export const CLAIM_COOKIE_DAYS = 180;

const TOKEN = /^[A-Za-z0-9_-]{40,64}$/;
const SLUG = /^[a-z0-9-]{3,80}$/;

export const claimCookieName = (slug) => `hub_claim_${slug}`;

/** The Set-Cookie value that remembers this claim on this device, or null if either part is malformed. */
export function claimCookie(slug, token) {
  if (!SLUG.test(slug || '') || !TOKEN.test(token || '')) return null;
  // HttpOnly: page scripts can't read it. SameSite=Lax: sent when the claimant arrives from an email or a search.
  return `${claimCookieName(slug)}=${token}; Path=/; Max-Age=${CLAIM_COOKIE_DAYS * 86400}; HttpOnly; Secure; SameSite=Lax`;
}

/** Adds the remember-this-claim cookie to a response. Returns the response. */
export function remember(res, slug, token) {
  const cookie = claimCookie(slug, token);
  if (cookie) res.headers.append('Set-Cookie', cookie);
  return res;
}

/** One line for the "Welcome back" bar: where the claim is up to, in plain words. */
export function welcomeBackLine(claim) {
  const left = Array.isArray(claim?.outstanding) ? claim.outstanding.length : 0;
  switch (claim?.stage) {
    case 'awaiting':
      return left ? `Your claim needs ${left} more thing${left === 1 ? '' : 's'} from you.` : 'Your claim is nearly done.';
    case 'review': return 'Everything is in. Our team is checking your claim.';
    case 'approved': return 'Your claim is approved and your cashback is on its way.';
    case 'paid': return 'Your cashback has been paid.';
    case 'payment_failed': return 'Your bank rejected the payment. Please update your bank details.';
    case 'not_approved': return 'Your claim wasn\'t approved.';
    default: return 'You have a claim on this promotion.';
  }
}
