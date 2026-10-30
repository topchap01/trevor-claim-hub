/**
 * Claimant link security.
 * Links carry a random 256-bit code stored on Entry__c.Access_Token__c. Codes are never derived
 * from the record Id, so one claimant's link tells you nothing about anyone else's.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimAccessToken {
    public static final Integer MIN_LENGTH = 40;
    /** Lets tests create a claim without a code, to exercise the backfill. */
    public static Boolean suppressAutoStamp = false;
    public static final String MASK = '•••';
    /** Lead fields that are never sent back to a browser in full. */
    public static final Set<String> SENSITIVE_LEAD_FIELDS = new Set<String>{
        'Bank_Account_Number__c', 'Account_Number__c', 'BSB__c'
    };

    public static String newToken() {
        String b64 = EncodingUtil.base64Encode(Crypto.generateAesKey(256));
        return b64.replace('+', '-').replace('/', '_').replace('=', '');
    }

    /** Returns the claim for a link code, or null. Old base64(Id) codes are deliberately not accepted. */
    public static Entry__c resolve(String token) {
        if (String.isBlank(token) || token.length() < MIN_LENGTH || token.length() > 64) return null;
        List<Entry__c> rows = [SELECT Id, Promotional_Campaign__c, Access_Token__c FROM Entry__c WHERE Access_Token__c = :token LIMIT 1];
        // Belt and braces: require an exact, case-sensitive match.
        return (!rows.isEmpty() && token.equals(rows[0].Access_Token__c)) ? rows[0] : null;
    }

    public static Boolean isGuest() {
        return UserInfo.getUserType() == 'Guest';
    }

    public static String mask(String value) {
        if (String.isBlank(value)) return value;
        String digits = value.replaceAll('[^0-9A-Za-z]', '');
        return MASK + (digits.length() > 3 ? digits.right(3) : '');
    }

    public static Boolean isMasked(Object value) {
        return value instanceof String && ((String) value).startsWith(MASK);
    }

    /** Returns the claim's link code, creating one (and its links) if it has none yet. */
    public static String ensureToken(Id entryId) {
        Entry__c e = [SELECT Id, Promotional_Campaign__c, Access_Token__c, Promotional_Campaign__r.Edit_URL__c, Promotional_Campaign__r.Status_URL__c
                      FROM Entry__c WHERE Id = :entryId];
        if (e.Access_Token__c == null) {
            stamp(new List<Entry__c>{ e }, new Map<Id, Promotional_Campaign__c>{ e.Promotional_Campaign__c => e.Promotional_Campaign__r });
            update new Entry__c(Id = e.Id, Access_Token__c = e.Access_Token__c, Resume_Url__c = e.Resume_Url__c, Status_URL__c = e.Status_URL__c);
        }
        return e.Access_Token__c;
    }

    /** Replaces the claim's link code, so every older link stops working. Returns the new code. */
    public static String rotate(Id entryId) {
        Entry__c e = [SELECT Id, Access_Token__c, Promotional_Campaign__c, Promotional_Campaign__r.Edit_URL__c, Promotional_Campaign__r.Status_URL__c
                      FROM Entry__c WHERE Id = :entryId];
        e.Access_Token__c = null;
        stamp(new List<Entry__c>{ e }, new Map<Id, Promotional_Campaign__c>{ e.Promotional_Campaign__c => e.Promotional_Campaign__r });
        update new Entry__c(Id = e.Id, Access_Token__c = e.Access_Token__c, Resume_Url__c = e.Resume_Url__c, Status_URL__c = e.Status_URL__c);
        return e.Access_Token__c;
    }

    /** Assigns codes and rebuilds links for the given claims (no DML). */
    public static void stamp(List<Entry__c> entries, Map<Id, Promotional_Campaign__c> campaigns) {
        for (Entry__c e : entries) {
            if (e.Access_Token__c == null) e.Access_Token__c = newToken();
            Promotional_Campaign__c c = campaigns.get(e.Promotional_Campaign__c);
            String editUrl = c == null ? null : c.Edit_URL__c;
            String statusUrl = c == null ? null : c.Status_URL__c;
            e.Resume_Url__c = editUrl == null ? null : editUrl + '?token=' + e.Access_Token__c;
            e.Status_URL__c = statusUrl == null ? null : statusUrl + '?token=' + e.Access_Token__c;
        }
    }
}
