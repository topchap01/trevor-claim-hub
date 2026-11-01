/**
 * Invoice files kept outside Salesforce (decisions.md #6 and #17). Salesforce is the index: each receipt holds its file's key.
 * The web app's nightly storage check compares the store with this index, deletes what should go, and reports back here.
 *   GET  /claimhub/v1/storage/keys[/{after receipt Id}]   keys Salesforce points to, PAGE at a time, in Id order
 *   GET  /claimhub/v1/storage/due                         keys whose retention period has ended (none while no period is set)
 *   POST /claimhub/v1/storage/report                      what the check found and deleted
 *
 * Retention (Claim_Hub_Settings__c.Invoice_Retention_Months__c, blank keeps everything): a file is due when its claim was
 * paid or not approved that many months ago, or, for a claim never completed, that many months after claims closed.
 * Claims still being worked on (with the team, approved, payment failed) are never due.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubStorage {

    public static final Integer PAGE = 2000;
    /** Most keys the check sends back in one report (deleted or missing). */
    public static final Integer MAX_REPORTED = 2000;
    public static final String MISSING_ACTION = 'Needs review: invoice file missing';
    static final Set<String> SETTLED_ACTIONS = new Set<String>{ 'Paid', 'Not approved' };

    // ------------------------------------------------------------------ the index

    /** Keys of files Salesforce points to and has not deleted, in receipt Id order. next is the cursor for the following page. */
    public static Map<String, Object> keys(String after) {
        Id afterId = toId(after);
        List<Entry_Receipt__c> rs = afterId == null
            ? [SELECT Id, Hub_File_Key__c FROM Entry_Receipt__c WHERE Hub_File_Key__c != null AND Hub_File_Removed__c = null ORDER BY Id LIMIT :PAGE]
            : [SELECT Id, Hub_File_Key__c FROM Entry_Receipt__c WHERE Hub_File_Key__c != null AND Hub_File_Removed__c = null AND Id > :afterId ORDER BY Id LIMIT :PAGE];
        List<String> out = new List<String>();
        for (Entry_Receipt__c r : rs) out.add(r.Hub_File_Key__c);
        return new Map<String, Object>{ 'keys' => out, 'next' => rs.size() == PAGE ? (Object) rs[rs.size() - 1].Id : null };
    }

    // ------------------------------------------------------------------ retention

    /** Keys whose retention period has ended, at most PAGE a night (the rest go the next night). */
    public static Map<String, Object> due() {
        Integer months = ClaimHubSettings.retentionMonths();
        List<String> out = new List<String>();
        if (months != null) {
            for (Entry_Receipt__c r : dueBy(null, Datetime.now().addMonths(-months), PAGE)) out.add(r.Hub_File_Key__c);
        }
        return new Map<String, Object>{ 'months' => months, 'keys' => out };
    }

    /**
     * Receipts whose file is due for deletion if the retention period ends on or before cutoff + months: the claim was settled
     * (paid or not approved) before cutoff, or it was never completed and claims closed before cutoff.
     */
    public static List<Entry_Receipt__c> dueBy(Id campaignId, Datetime cutoff, Integer max) {
        List<Entry_Receipt__c> candidates = campaignId == null
            ? [SELECT Id, Entry__c, Hub_File_Key__c, Entry__r.Entry_Status__c, Entry__r.EFT_Status__c, Entry__r.Promotional_Campaign__r.Date_end__c
               FROM Entry_Receipt__c WHERE Hub_File_Key__c != null AND Hub_File_Removed__c = null
               AND (Entry__r.EFT_Status__c = 'Fulfilled' OR Entry__r.Entry_Status__c IN ('Invalid', 'Cancelled') OR Entry__r.Promotional_Campaign__r.Date_end__c < :cutoff)
               ORDER BY Id LIMIT 10000]
            : [SELECT Id, Entry__c, Hub_File_Key__c, Entry__r.Entry_Status__c, Entry__r.EFT_Status__c, Entry__r.Promotional_Campaign__r.Date_end__c
               FROM Entry_Receipt__c WHERE Hub_File_Key__c != null AND Hub_File_Removed__c = null AND Entry__r.Promotional_Campaign__c = :campaignId
               AND (Entry__r.EFT_Status__c = 'Fulfilled' OR Entry__r.Entry_Status__c IN ('Invalid', 'Cancelled') OR Entry__r.Promotional_Campaign__r.Date_end__c < :cutoff)
               ORDER BY Id LIMIT 10000];
        if (candidates.isEmpty()) return candidates;
        Set<Id> entryIds = new Set<Id>();
        for (Entry_Receipt__c r : candidates) entryIds.add(r.Entry__c);
        // When each claim was settled: its latest Paid or Not approved event (ClaimHubEntryHandler logs them)
        Map<Id, Datetime> settledAt = new Map<Id, Datetime>();
        for (AggregateResult ar : [SELECT Entry__c e, MAX(CreatedDate) settled FROM Claim_Event__c
                                   WHERE Entry__c IN :entryIds AND Action__c IN :SETTLED_ACTIONS GROUP BY Entry__c]) {
            settledAt.put((Id) ar.get('e'), (Datetime) ar.get('settled'));
        }
        List<Entry_Receipt__c> out = new List<Entry_Receipt__c>();
        for (Entry_Receipt__c r : candidates) {
            if (out.size() >= max) break;
            if (isDue(ClaimHubService.stage(r.Entry__r), settledAt.get(r.Entry__c), r.Entry__r.Promotional_Campaign__r.Date_end__c, cutoff)) out.add(r);
        }
        return out;
    }

    @TestVisible
    static Boolean isDue(String stage, Datetime settled, Datetime claimsClosed, Datetime cutoff) {
        if (stage == 'paid' || stage == 'not_approved') {
            // Settled before the hub logged it: fall back to when claims closed
            Datetime at = settled != null ? settled : claimsClosed;
            return at != null && at < cutoff;
        }
        if (stage == 'awaiting') return claimsClosed != null && claimsClosed < cutoff;
        return false; // with the team, approved or payment failed: a person still needs the invoice
    }

    // ------------------------------------------------------------------ the nightly report

    /**
     * Records a nightly check. body: store, files, bytes, unlinked, unlinkedRemoved, missingCount, problems (list of text),
     * expiredRemoved (keys deleted under retention), missing (keys Salesforce points to that the store lacks).
     * Deleted files are marked on their receipts; each claim missing its file is put in front of a person once.
     */
    public static Map<String, Object> report(Map<String, Object> body) {
        List<String> expired = strings(body.get('expiredRemoved'));
        List<String> missing = strings(body.get('missing'));
        Datetime now = Datetime.now();
        Integer months = ClaimHubSettings.retentionMonths();

        List<Entry_Receipt__c> removed = expired.isEmpty() ? new List<Entry_Receipt__c>()
            : [SELECT Id, Entry__c FROM Entry_Receipt__c WHERE Hub_File_Key__c IN :expired AND Hub_File_Removed__c = null];
        List<Claim_Event__c> events = new List<Claim_Event__c>();
        for (Entry_Receipt__c r : removed) {
            r.Hub_File_Removed__c = now;
            events.add(ClaimHubLog.build(r.Entry__c, 'System', 'Internal: invoice file deleted',
                'Retention period ended' + (months == null ? '' : ' (' + months + ' months)')));
        }

        Integer flagged = 0;
        if (!missing.isEmpty()) {
            Set<Id> entryIds = new Set<Id>();
            for (Entry_Receipt__c r : [SELECT Entry__c FROM Entry_Receipt__c WHERE Hub_File_Key__c IN :missing AND Hub_File_Removed__c = null]) entryIds.add(r.Entry__c);
            Set<Id> already = new Set<Id>();
            for (Claim_Event__c ev : [SELECT Entry__c FROM Claim_Event__c WHERE Entry__c IN :entryIds AND Action__c = :MISSING_ACTION]) already.add(ev.Entry__c);
            for (Id e : entryIds) {
                if (already.contains(e)) continue;
                events.add(ClaimHubLog.build(e, 'System', MISSING_ACTION, 'The nightly storage check could not find the invoice file. Ask the claimant to upload it again.'));
                flagged++;
            }
        }

        List<String> problems = strings(body.get('problems'));
        Hub_Storage_Check__c chk = new Hub_Storage_Check__c(
            Store__c = text(body.get('store'), 255),
            Files__c = num(body.get('files')), Bytes__c = num(body.get('bytes')),
            Unlinked__c = num(body.get('unlinked')), Unlinked_Removed__c = num(body.get('unlinkedRemoved')),
            Missing__c = body.get('missingCount') != null ? num(body.get('missingCount')) : missing.size(),
            Expired_Removed__c = removed.size(),
            Problems__c = problems.isEmpty() ? null : String.join(problems, '\n').left(4000));

        if (!removed.isEmpty()) update removed;
        if (!events.isEmpty()) insert events;
        insert chk;
        return new Map<String, Object>{ 'id' => chk.Id, 'markedRemoved' => removed.size(), 'flaggedMissing' => flagged };
    }

    /** The latest check, or null. */
    public static Hub_Storage_Check__c latest() {
        List<Hub_Storage_Check__c> cs = [SELECT Id, Name, CreatedDate, Store__c, Files__c, Bytes__c, Unlinked__c, Unlinked_Removed__c, Missing__c, Expired_Removed__c, Problems__c
                                         FROM Hub_Storage_Check__c ORDER BY CreatedDate DESC, Id DESC LIMIT 1];
        return cs.isEmpty() ? null : cs[0];
    }

    /**
     * Problems worth an alert email, reported once: a check that ran in the last hour and found something, or no check for
     * 36 hours (reported in the hour it crosses 36). Never part of the uptime check: a storage issue is not an outage.
     */
    public static List<String> alerts() {
        List<String> out = new List<String>();
        Hub_Storage_Check__c c = latest();
        if (c == null) return out;
        Long hours = (Datetime.now().getTime() - c.CreatedDate.getTime()) / 3600000;
        if (hours < 1) {
            if (c.Missing__c != null && c.Missing__c > 0) out.add(c.Missing__c.intValue() + ' claim' + (c.Missing__c == 1 ? '' : 's') + ' point to an invoice file the store does not hold');
            if (String.isNotBlank(c.Problems__c)) out.add('Storage check: ' + c.Problems__c.replace('\n', '; ').left(300));
        }
        if (hours == 36) out.add('The nightly invoice storage check has not run for 36 hours');
        return out;
    }

    // ------------------------------------------------------------------ helpers

    static Id toId(String s) {
        if (String.isBlank(s)) return null;
        try { return Id.valueOf(s); } catch (Exception ex) { throw new ClaimHubService.HubException(400, 'Bad request'); }
    }
    static List<String> strings(Object o) {
        List<String> out = new List<String>();
        if (!(o instanceof List<Object>)) return out;
        for (Object x : (List<Object>) o) {
            if (x != null && out.size() < MAX_REPORTED) out.add(String.valueOf(x).left(255));
        }
        return out;
    }
    static Decimal num(Object o) {
        if (o == null) return null;
        try { return Decimal.valueOf(String.valueOf(o)); } catch (Exception ex) { return null; }
    }
    static String text(Object o, Integer max) { return o == null ? null : String.valueOf(o).left(max); }
}
