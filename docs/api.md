# Claim hub API

There are two layers:
- **Browser → web app:** `/api/*`, implemented in `web/app/api`.
- **Web app → Salesforce:** `/services/apexrest/claimhub/v1/*`, implemented in `ClaimHubApi`.

Only the web app can call Salesforce. It signs in as the integration user, whose only permission is access to `ClaimHubApi`.

All bodies are JSON. Errors are always `{"error": "<plain English, safe to show the claimant>"}`, with these statuses. A refusal the web app acts on, not just shows, also carries a `code`: today only `"duplicate_email"` (409 on lodge), which makes the claim form offer the claim's link in one tap.

| Status | Meaning |
|---|---|
| 400 | The request is invalid, or the claim does not meet the terms (the message says why). |
| 401 | Wrong or expired security code. |
| 404 | Unknown promotion, unknown or expired claim link. |
| 409 | Conflict: a claim already exists for the email, a duplicate serial, the claim is with the team, or a payment is in progress. |
| 413 | Request or file too large. |
| 415 | Unsupported file type. |
| 429 | A per-claim or per-connection daily limit was reached. |
| 500 | Unexpected. The body adds `"ref"`, the Nebula Logger transaction id. |
| 503 | Salesforce unreachable. Returned by the web app only. |

`{token}` is the claimant's 43-character link code (`[A-Za-z0-9_-]`). It is the only credential a claimant has.

## Routes

| Browser route | Salesforce route | Purpose |
|---|---|---|
| `GET /api/campaign/{slug}` | `GET campaigns/{slug}` | Public promotion details: products, tiers, dates, rules. |
| `POST /api/campaign/{slug}/claim` | `POST campaigns/{slug}/claims` | Lodge a claim. Returns `{token}`. |
| `POST /api/campaign/{slug}/chat` | `POST campaigns/{slug}/chat` | Help assistant, before a claim exists. |
| `GET /api/claim/{token}` | `GET claims/{token}` | The claimant's view of their claim. On success the web app sets the `hub_claim_<slug>` cookie, so this phone remembers the claim (decisions.md #12). Lodging sets it too. |
| `POST /api/claim/{token}/serial` | `POST claims/{token}/serial` | `{productId, serial, pnc?}` |
| `POST /api/claim/{token}/receipt` | `POST claims/{token}/receipt` | `{base64, contentType, fileName}`. The web app stores the file and adds `fileKey`. |
| `POST /api/claim/{token}/plate` | `POST claims/{token}/plate` | `{base64, contentType}`. Returns `{serial, pnc, model, readable}` or `{error}`. |
| `POST /api/claim/{token}/code` | `POST claims/{token}/code` | Emails a 6-digit bank-change code. |
| `POST /api/claim/{token}/bank` | `POST claims/{token}/bank` | `{code, name, bsb?, account}` |
| `POST /api/claim/{token}/chat` | `POST claims/{token}/chat` | `{messages:[{role, content}]}`, with the claim as context. |
| `GET /api/bank/{NZ\|AU}/{6 digits}` | `GET banks/{country}/{code}` | Bank and branch for an NZ bank-and-branch prefix or an AU BSB, from the registers. `{found, bankName?, branchName?, electronic?, registerLoaded?}`. No personal data in or out. Cached 12 hours per server instance. |
| `POST /api/resend` | `POST resend` | `{slug, email}`. Always `{sent:true}`, so it can't be used to test which emails have claims. Issues a new link code; the old link stops working. |
| `GET /api/file?t=` | `GET files/{ticket}` | Staff only, by ticket. Streams the invoice from private storage. |
| `GET /api/health` | `GET health` | 200 or 503 with counts. No personal data. |

## Lodge request

```json
{
  "firstName": "Sam", "lastName": "Tester", "email": "sam@example.com", "mobile": "021 555 0142", "acceptedTerms": true,
  "products": [
    { "promoProductId": "a0B...", "price": "4299", "serial": "61234567", "pnc": "949597455" }
  ],
  "bank": { "name": "S Tester", "account": "12-3140-0234566-00" },
  "invoice": { "number": "HN-1", "date": "2026-11-02", "store": "Harvey Norman Auburn" }
}
```

- `serial`, `pnc`, `bank` and `invoice` are optional at lodge.
- `address` and `store` are required when the campaign response has `collectAddress` or `collectStore` true, and ignored otherwise (decisions.md #13):

  ```json
  "address": { "unit": "4", "streetNumber": "12", "street": "Example Street", "suburb": "Testville", "postcode": "2000", "state": "NSW" },
  "store": { "retailer": "Harvey Norman", "name": "", "suburb": "Testville", "state": "NSW" }
  ```

  - `state` is a value from the campaign's `regions` (AU state codes, NZ region names). `unit` is optional.
  - `retailer` is one of the campaign's `stores`. `name` is needed when it is `Other`, or when `stores` is empty. `state` applies to AU stores only.
  - They are saved to the fields the Electrolux C4C feed reads: the `Consumer_*` address fields on the Entry, and `Retailer__c`, `Store_Name__c`, `Retailer_Suburb__c`, `Retailer_State__c` on the claim's one receipt. A later invoice upload fills the same receipt.
  - The address also goes on the Lead, in the fields the old forms use (`Unit_No__c`, `Street_Number__c`, `Street__c`, `Suburb__c`, `Postal_Code__c`, `Country__c`, and `State_Territory__c` for an AU state or `Town_City__c` for an NZ region). The legacy `EntryCreation` trigger copies Lead fields onto the Entry when it is created, through `Lead_To_Entry_Mapping__mdt`. Two Lead fields map to `Consumer_State_Stamp__c`, so the hub checks the saved stamps and puts them right if needed.
- AU bank details are `{name, bsb, account}`. NZ bank details are `{name, account}`: 15 or 16 digits with a valid bank code.
- Prices are required when the payout or eligibility depends on spend. In that case `needsPrices` is true in the campaign response.

## Checks on lodge, in order

Each check refuses with a 4xx before anything is saved.

1. The promotion is open.
2. Name, email and mobile are present and valid.
3. No claim exists with this email on this promotion. The database enforces this too, through the unique `Hub_Dedupe_Key__c`.
4. The connection is under its daily limit.
5. `acceptedTerms` is true. (It comes after the email and connection checks, so a duplicate-email answer can be had without ticking the terms: audit, 1 Nov 2026.)
6. The number of products is within the promotion's minimum and maximum.
7. Each product belongs to the promotion.
8. A price is given for each product where spend matters.
9. The minimum spend is met.
10. The serial format is valid, the serial does not start with an excluded prefix, and no serial is entered twice on the form.
11. The basket reaches a cashback tier.
12. The bank format is right for the country, and an NZ account number passes its bank's check digit (decisions.md #11).
13. When the campaign asks: street number, street, suburb, a 4-digit postcode and a state or region from the list; a store from the list (or a name for `Other`), its suburb, and in Australia its state.

After saving, these are flagged for the team but not refused:
- a third or later claim from one connection in 24 hours;
- a bank account already on another claim in the promotion;
- a mobile already on another claim in the promotion, matched on its last 8 digits (usually a mistyped email on the first claim).
- bank details the registers can't confirm: a bank, branch or BSB they don't list, or a BSB that takes no electronic payments.

## Claim view

The claim view (`GET claims/{token}`) returns:
- `stage`, `checklist` and `outstanding` (for example `["invoice", "serial:EOB9956XAX", "bank"]`);
- `products`, `receipts` and `timeline`. The timeline never includes `Needs review:` or `Internal:` events.
- masked contact and bank details: the email masked, the last three digits of the mobile and account;
- deadlines, the payment promise and the country.
