/**
 * Daily: reminds claimants with missing items at 7 and 21 days after lodging, then 14 and 3 days before the serial deadline.
 * Also sweeps the outbox. Schedule: System.schedule('Claim hub reminders', '0 0 9 * * ?', new ClaimHubReminders());
 * Bulk-safe: one event insert and one email insert for the whole run. Reminders sent are counted from the outbox rather than
 * stored on the claim, so the run never updates Entry__c (an update would re-send the claim to Electrolux C4C).
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubReminders implements Schedulable {
    public void execute(SchedulableContext ctx) { run(Date.today()); ClaimHubNotifier.dispatchDue(); }

    public static Integer run(Date today) {
        List<Claim_Event__c> events = new List<Claim_Event__c>();
        Map<Id, String> emails = new Map<Id, String>();
        Map<Id, Entry__c> open = new Map<Id, Entry__c>([SELECT Id, CreatedDate, Promotional_Campaign__r.Hub_Serial_Deadline__c FROM Entry__c
            WHERE Promotional_Campaign__r.Hub_Enabled__c = true AND Entry_Status__c = :ClaimHubService.STATUS_AWAITING ORDER BY CreatedDate LIMIT 2000]);
        Map<Id, Integer> sentSoFar = new Map<Id, Integer>();
        for (AggregateResult ar : [SELECT Entry__c id, COUNT(Id) k FROM Claim_Notification__c WHERE Template_Key__c = 'REMINDER' AND Entry__c IN :open.keySet() GROUP BY Entry__c]) {
            sentSoFar.put((Id) ar.get('id'), (Integer) ar.get('k'));
        }
        for (Entry__c e : open.values()) {
            Integer n = sentSoFar.containsKey(e.Id) ? sentSoFar.get(e.Id) : 0;
            if (!due(n, e.CreatedDate.date().daysBetween(today), e.Promotional_Campaign__r.Hub_Serial_Deadline__c, today)) continue;
            events.add(ClaimHubLog.build(e.Id, 'System', 'Reminder ' + (n + 1) + ' of 4 sent', null));
            emails.put(e.Id, 'REMINDER');
        }
        insert events;
        ClaimHubNotifier.enqueueMany(emails);
        return emails.size();
    }

    @TestVisible
    static Boolean due(Integer sent, Integer age, Datetime serialDeadline, Date today) {
        Integer toGo = serialDeadline == null ? 999 : today.daysBetween(serialDeadline.date());
        return (sent == 0 && age >= 7) || (sent == 1 && age >= 21) || (sent == 2 && toGo <= 14) || (sent == 3 && toGo <= 3);
    }
}
