/**
 * Staff console for claim hub campaigns: one screen per campaign with dates, rules, claim counts and the work that needs a person.
 * Runs in user mode (sharing, object and field permissions of the signed-in staff member).
 */
public with sharing class ClaimHubConsole {

    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> campaigns() {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Promotional_Campaign__c c : [SELECT Id, Name, Hub_Slug__c, Hub_Enabled__c, Date_start__c, Date_end__c FROM Promotional_Campaign__c
                                          WHERE Hub_Slug__c != null WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 100]) {
            out.add(new Map<String, Object>{ 'label' => c.Name + (c.Hub_Enabled__c ? '' : ' (switched off)'), 'value' => c.Id });
        }
        return out;
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> summary(Id campaignId) {
        Promotional_Campaign__c c = [SELECT Id, Name, Hub_Slug__c, Hub_Enabled__c, Hub_Base_URL__c, Hub_Country__c, Hub_Timezone__c, Hub_Brand_Name__c,
                                            Hub_Retailers__c, Hub_Min_Spend__c, Hub_Single_Transaction__c, Hub_Excluded_Serial_Prefixes__c, Hub_Sender_Address__c,
                                            Hub_Serial_Deadline__c, Hub_Bank_Deadline__c, Hub_Terms_Issues__c, Hub_Payment_Promise__c,
                                            Sales_From__c, Sales_To__c, Date_start__c, Date_end__c, Minimum_Number_Of_Products__c
                                     FROM Promotional_Campaign__c WHERE Id = :campaignId WITH USER_MODE];
        String tz = String.isBlank(c.Hub_Timezone__c) ? 'Australia/Sydney' : c.Hub_Timezone__c;
        String cc = ClaimHubService.country(c.Hub_Country__c);

        // Claim counts by the stage the claimant sees
        Map<String, Integer> n = new Map<String, Integer>{ 'awaiting' => 0, 'review' => 0, 'approved' => 0, 'paid' => 0, 'payment_failed' => 0, 'not_approved' => 0 };
        Map<String, Decimal> v = new Map<String, Decimal>{ 'awaiting' => 0, 'review' => 0, 'approved' => 0, 'paid' => 0, 'payment_failed' => 0, 'not_approved' => 0 };
        for (AggregateResult ar : [SELECT Entry_Status__c st, EFT_Status__c eft, COUNT(Id) k, SUM(Cashback_Amount__c) amt FROM Entry__c
                                   WHERE Promotional_Campaign__c = :c.Id WITH USER_MODE GROUP BY Entry_Status__c, EFT_Status__c]) {
            String stage = ClaimHubService.stage(new Entry__c(Entry_Status__c = (String) ar.get('st'), EFT_Status__c = (String) ar.get('eft')));
            n.put(stage, n.get(stage) + (Integer) ar.get('k'));
            v.put(stage, v.get(stage) + (ar.get('amt') == null ? 0 : (Decimal) ar.get('amt')));
        }

        // Work that needs a person
        List<Map<String, Object>> queue = new List<Map<String, Object>>();
        for (Claim_Event__c ev : [SELECT Entry__c, Entry__r.Name, Entry__r.Consumer_First_Name_Stamp__c, Entry__r.Consumer_Last_Name_Stamp__c, Action__c, Detail__c, CreatedDate
                                  FROM Claim_Event__c WHERE Entry__r.Promotional_Campaign__c = :c.Id AND Action__c LIKE 'Needs review%'
                                  WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 50]) {
            queue.add(row(ev.Entry__c, ev.Entry__r.Name, name(ev.Entry__r.Consumer_First_Name_Stamp__c, ev.Entry__r.Consumer_Last_Name_Stamp__c),
                ev.Action__c.removeStart('Needs review: '), ev.Detail__c, ev.CreatedDate, tz));
        }
        for (Entry_Receipt__c r : [SELECT Entry__c, Entry__r.Name, Entry__r.Consumer_First_Name_Stamp__c, Entry__r.Consumer_Last_Name_Stamp__c, OCR_Status__c, LastModifiedDate
                                   FROM Entry_Receipt__c WHERE Entry__r.Promotional_Campaign__c = :c.Id AND (OCR_Status__c LIKE 'Check:%' OR OCR_Status__c = 'Not read')
                                   WITH USER_MODE ORDER BY LastModifiedDate DESC LIMIT 50]) {
            queue.add(row(r.Entry__c, r.Entry__r.Name, name(r.Entry__r.Consumer_First_Name_Stamp__c, r.Entry__r.Consumer_Last_Name_Stamp__c),
                'Invoice check', r.OCR_Status__c.removeStart('Check: '), r.LastModifiedDate, tz));
        }

        // Ready to validate: complete claims whose invoice passed
        List<Map<String, Object>> ready = new List<Map<String, Object>>();
        for (Entry__c e : [SELECT Id, Name, Consumer_First_Name_Stamp__c, Consumer_Last_Name_Stamp__c, Cashback_Amount__c, Purchase_Price__c, LastModifiedDate,
                                  (SELECT OCR_Status__c FROM Entry_Receipts__r LIMIT 1)
                           FROM Entry__c WHERE Promotional_Campaign__c = :c.Id AND Entry_Status__c = :ClaimHubService.STATUS_COMPLETE
                           WITH USER_MODE ORDER BY LastModifiedDate ASC LIMIT 50]) {
            String check = e.Entry_Receipts__r.isEmpty() ? null : e.Entry_Receipts__r[0].OCR_Status__c;
            ready.add(new Map<String, Object>{ 'id' => e.Id, 'claim' => e.Name, 'who' => name(e.Consumer_First_Name_Stamp__c, e.Consumer_Last_Name_Stamp__c),
                'cashback' => ClaimHubService.money(e.Cashback_Amount__c, cc), 'spend' => ClaimHubService.money(e.Purchase_Price__c, cc),
                'invoice' => check == 'Passed' ? 'Passed' : (check == null ? 'Not read' : 'Check'), 'clean' => check == 'Passed',
                'waiting' => e.LastModifiedDate.format('d MMM, h:mma', tz) });
        }

        // Email outbox
        Map<String, Integer> outbox = new Map<String, Integer>{ 'Sent' => 0, 'Queued' => 0, 'Failed' => 0 };
        for (AggregateResult ar : [SELECT Status__c s, COUNT(Id) k FROM Claim_Notification__c WHERE Entry__r.Promotional_Campaign__c = :c.Id WITH USER_MODE GROUP BY Status__c]) {
            String s = (String) ar.get('s');
            if (outbox.containsKey(s)) outbox.put(s, (Integer) ar.get('k'));
        }

        List<String> rules = new List<String>();
        if (c.Minimum_Number_Of_Products__c != null) rules.add(c.Minimum_Number_Of_Products__c.intValue() + '+ appliances');
        if (c.Hub_Min_Spend__c != null) rules.add('Min spend ' + ClaimHubService.money(c.Hub_Min_Spend__c, cc));
        if (c.Hub_Single_Transaction__c) rules.add('One invoice');
        if (String.isNotBlank(c.Hub_Retailers__c)) rules.add(c.Hub_Retailers__c + ' only');
        if (String.isNotBlank(c.Hub_Excluded_Serial_Prefixes__c)) rules.add('No serials starting ' + c.Hub_Excluded_Serial_Prefixes__c.replace(',', ', '));
        rules.add(cc == 'NZ' ? 'NZ bank accounts' : 'AU bank accounts (BSB)');

        Datetime now = Datetime.now();
        String state = !c.Hub_Enabled__c ? 'Switched off' : (c.Date_start__c != null && c.Date_start__c > now) ? 'Not open yet'
                     : (c.Date_end__c != null && c.Date_end__c < now) ? 'Closed to new claims' : 'Open for claims';

        List<String> issues = String.isBlank(c.Hub_Terms_Issues__c) ? new List<String>() : c.Hub_Terms_Issues__c.split('\n');
        List<Map<String, Object>> issueRows = new List<Map<String, Object>>();
        Integer i = 0;
        for (String s : issues) {
            String sev = s.startsWith('[HIGH]') ? 'high' : s.startsWith('[MEDIUM]') ? 'medium' : 'low';
            issueRows.add(new Map<String, Object>{ 'key' => i++, 'sev' => sev.toUpperCase(), 'cls' => 'issue ' + sev, 'text' => s.replaceFirst('^\\[[A-Z]+\\]\\s*', '') });
        }

        return new Map<String, Object>{
            'id' => c.Id, 'name' => c.Name, 'state' => state, 'brand' => c.Hub_Brand_Name__c, 'sender' => c.Hub_Sender_Address__c,
            'liveUrl' => ClaimHubSettings.pageUrl(c.Hub_Base_URL__c, c.Hub_Slug__c),
            'dates' => new List<Object>{
                dateRow('Purchases', fmtDay(c.Sales_From__c) + ' to ' + fmtDay(c.Sales_To__c)),
                dateRow('Claims open', fmt(c.Date_start__c, tz)), dateRow('Claims close', fmt(c.Date_end__c, tz)),
                dateRow('Serial numbers by', fmt(c.Hub_Serial_Deadline__c, tz)), dateRow('Bank details fixed by', fmt(c.Hub_Bank_Deadline__c, tz)) },
            'timezone' => tz, 'rules' => rules,
            'counts' => new List<Object>{
                tile('Awaiting details', n.get('awaiting'), v.get('awaiting'), cc, 'Claimant still adding invoice, serials or bank'),
                tile('With team', n.get('review'), v.get('review'), cc, 'Complete, ready to validate'),
                tile('Approved', n.get('approved'), v.get('approved'), cc, 'Queued for payment'),
                tile('Paid', n.get('paid'), v.get('paid'), cc, ''),
                tile('Payment failed', n.get('payment_failed'), v.get('payment_failed'), cc, 'Claimant asked to fix bank details'),
                tile('Not approved', n.get('not_approved'), v.get('not_approved'), cc, '') },
            'queue' => queue, 'ready' => ready, 'issues' => issueRows,
            'outbox' => outbox, 'storage' => storage(c.Id, tz) };
    }

    /**
     * Invoice files for the campaign (decisions.md #17): what is held, what retention has removed or will remove in the
     * next 30 days, and the latest nightly storage check. Counts only; files open from a claim, one at a time.
     */
    @TestVisible
    static Map<String, Object> storage(Id campaignId, String tz) {
        AggregateResult held = [SELECT COUNT(Id) k, SUM(Hub_File_Size__c) b, MIN(CreatedDate) first FROM Entry_Receipt__c
                                WHERE Entry__r.Promotional_Campaign__c = :campaignId AND Hub_File_Key__c != null AND Hub_File_Removed__c = null WITH USER_MODE];
        Integer removed = [SELECT COUNT() FROM Entry_Receipt__c WHERE Entry__r.Promotional_Campaign__c = :campaignId AND Hub_File_Removed__c != null WITH USER_MODE];
        Integer months = ClaimHubSettings.retentionMonths();
        Integer files = (Integer) held.get('k');
        List<Object> rows = new List<Object>{
            dateRow('Files held', String.valueOf(files)),
            dateRow('Space used', size((Decimal) held.get('b'))),
            dateRow('First received', held.get('first') == null ? 'None yet' : ((Datetime) held.get('first')).format('d MMM yyyy', tz)),
            dateRow('Kept for', months == null ? 'Every file (no retention period set)' : months + ' months after the claim is settled'),
            dateRow('Deleted under retention', String.valueOf(removed)) };
        if (months != null) {
            Integer soon = ClaimHubStorage.dueBy(campaignId, Datetime.now().addDays(30).addMonths(-months), 10000).size();
            rows.add(dateRow('Due for deletion in 30 days', String.valueOf(soon)));
        }
        List<Hub_Storage_Check__c> cs = [SELECT CreatedDate, Store__c, Files__c, Unlinked__c, Unlinked_Removed__c, Missing__c, Expired_Removed__c, Problems__c
                                         FROM Hub_Storage_Check__c WITH USER_MODE ORDER BY CreatedDate DESC, Id DESC LIMIT 1];
        Map<String, Object> check = null;
        if (!cs.isEmpty()) {
            Hub_Storage_Check__c k = cs[0];
            Boolean ok = String.isBlank(k.Problems__c) && (k.Missing__c == null || k.Missing__c == 0);
            check = new Map<String, Object>{
                'when' => k.CreatedDate.format('h:mma d MMM', tz).replace('AM', 'am').replace('PM', 'pm'),
                'ok' => ok, 'cls' => ok ? 'pill ok' : 'pill warn', 'label' => ok ? 'All files accounted for' : 'Needs a look',
                'store' => k.Store__c,
                'line' => n(k.Files__c) + ' files across all campaigns · ' + n(k.Missing__c) + ' missing · '
                          + n(k.Unlinked_Removed__c) + ' unlinked removed · ' + n(k.Expired_Removed__c) + ' deleted under retention',
                'problems' => k.Problems__c };
        }
        return new Map<String, Object>{ 'rows' => rows, 'check' => check };
    }
    static Integer n(Decimal d) { return d == null ? 0 : d.intValue(); }
    @TestVisible
    static String size(Decimal bytes) {
        if (bytes == null || bytes == 0) return '0 MB';
        if (bytes < 1048576) return (bytes / 1024).setScale(0, RoundingMode.HALF_UP) + ' KB';
        if (bytes < 1073741824) return (bytes / 1048576).setScale(1, RoundingMode.HALF_UP) + ' MB';
        return (bytes / 1073741824).setScale(2, RoundingMode.HALF_UP) + ' GB';
    }

    /** Team decisions. Setting the status fires the claimant email through ClaimHubEntryHandler. */
    @AuraEnabled
    public static void approve(Id entryId) {
        Entry__c e = [SELECT Id, Entry_Status__c FROM Entry__c WHERE Id = :entryId WITH USER_MODE];
        if (e.Entry_Status__c != ClaimHubService.STATUS_COMPLETE) throw new AuraHandledException('Only complete claims can be approved.');
        update as user new Entry__c(Id = entryId, Entry_Status__c = 'Valid');
    }

    @AuraEnabled
    public static void reject(Id entryId, String reason) {
        if (String.isBlank(reason)) throw new AuraHandledException('Choose a reason.');
        Entry__c e = [SELECT Entry_Status__c, EFT_Status__c FROM Entry__c WHERE Id = :entryId WITH USER_MODE];
        String stage = ClaimHubService.stage(e);
        if (stage == 'paid' || stage == 'not_approved') throw new AuraHandledException('This claim has already been ' + (stage == 'paid' ? 'paid' : 'rejected') + '.');
        update as user new Entry__c(Id = entryId, Entry_Status__c = 'Invalid', Invalid_Reason__c = reason);
    }

    /** A short-lived link to the claim's invoice file (see ClaimHubFiles). */
    @AuraEnabled
    public static String invoiceLink(Id entryId) {
        // Only for claims this staff member can see
        if ([SELECT COUNT() FROM Entry__c WHERE Id = :entryId WITH USER_MODE] == 0) throw new AuraHandledException('Claim not found.');
        try { return ClaimHubFiles.invoiceLink(entryId); }
        catch (Exception ex) { throw new AuraHandledException(ex.getMessage()); }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> reasons() {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Schema.PicklistEntry pe : Entry__c.Invalid_Reason__c.getDescribe().getPicklistValues()) {
            if (pe.isActive()) out.add(new Map<String, Object>{ 'label' => pe.getLabel(), 'value' => pe.getValue() });
        }
        return out;
    }

    static Map<String, Object> row(Id entryId, String claim, String who, String what, String detail, Datetime at, String tz) {
        return new Map<String, Object>{ 'key' => claim + what + at.getTime(), 'id' => entryId, 'claim' => claim, 'who' => who, 'what' => what,
            'detail' => detail, 'when' => at.format('d MMM, h:mma', tz) };
    }
    static Map<String, Object> tile(String label, Integer count, Decimal value, String cc, String note) {
        return new Map<String, Object>{ 'label' => label, 'count' => count, 'value' => ClaimHubService.money(value, cc), 'hint' => note };
    }
    static Map<String, Object> dateRow(String label, String value) { return new Map<String, Object>{ 'label' => label, 'value' => value }; }
    static String name(String f, String l) { return ((f == null ? '' : f) + ' ' + (l == null ? '' : l)).trim(); }
    static String fmt(Datetime d, String tz) { return d == null ? 'Not set' : d.format('h:mma d MMM yyyy', tz).replace('AM', 'am').replace('PM', 'pm'); }
    static String fmtDay(Date d) { return d == null ? '?' : Datetime.newInstanceGmt(d, Time.newInstance(12, 0, 0, 0)).formatGmt('d MMM yyyy'); }
}
