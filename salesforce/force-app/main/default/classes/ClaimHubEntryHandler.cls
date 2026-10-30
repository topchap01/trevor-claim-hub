/**
 * Emails claimants when the team changes a claim (approve, reject, pay, payment failed). Hub campaigns only.
 * Bulk-safe: a payment file that marks hundreds of claims Fulfilled in one update costs one query and two inserts.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubEntryHandler {
    public static Boolean suppress = false;
    static Set<String> done = new Set<String>();

    public static void afterUpdate(List<Entry__c> news, Map<Id, Entry__c> olds) {
        if (suppress) return;
        Set<Id> campaignIds = new Set<Id>();
        for (Entry__c e : news) campaignIds.add(e.Promotional_Campaign__c);
        Map<Id, Promotional_Campaign__c> hub = new Map<Id, Promotional_Campaign__c>(
            [SELECT Id FROM Promotional_Campaign__c WHERE Id IN :campaignIds AND Hub_Enabled__c = true]);
        if (hub.isEmpty()) return;
        List<Claim_Event__c> events = new List<Claim_Event__c>();
        Map<Id, String> emails = new Map<Id, String>();
        for (Entry__c e : news) {
            if (!hub.containsKey(e.Promotional_Campaign__c)) continue;
            String key = keyFor(e, olds.get(e.Id));
            if (key == null || done.contains(e.Id + key)) continue;
            done.add(e.Id + key);
            events.add(ClaimHubLog.build(e.Id, 'Team', LABELS.get(key), e.Invalid_Reason__c));
            emails.put(e.Id, key);
        }
        if (!events.isEmpty()) insert events;
        ClaimHubNotifier.enqueueMany(emails);
    }

    static final Map<String, String> LABELS = new Map<String, String>{ 'PAID' => 'Paid', 'EFT_FAILED' => 'Payment failed', 'VALID' => 'Approved', 'INVALID' => 'Not approved' };

    @TestVisible
    static String keyFor(Entry__c e, Entry__c o) {
        if (e.EFT_Status__c != o.EFT_Status__c && e.EFT_Status__c == 'Fulfilled') return 'PAID';
        if (e.EFT_Status__c != o.EFT_Status__c && (e.EFT_Status__c == 'EFT Failed' || e.EFT_Status__c == 'EFT Fail')) return 'EFT_FAILED';
        if (e.Entry_Status__c != o.Entry_Status__c && e.Entry_Status__c == 'Valid') return 'VALID';
        if (e.Entry_Status__c != o.Entry_Status__c && e.Entry_Status__c == 'Invalid') return 'INVALID';
        return null;
    }
}
