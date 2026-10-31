/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubDispatchJob implements Queueable {
    public void execute(QueueableContext ctx) {
        ClaimHubNotifier.dispatchDue();
        // Anything batched for later gets one run when due. Only one waiting dispatcher at a time, so chains never multiply.
        Integer waiting = [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ClaimHubDispatchJob' AND Status IN ('Queued', 'Holding', 'Preparing') AND Id != :ctx.getJobId()];
        if (waiting > 0) return;
        List<Claim_Notification__c> later = [SELECT Send_After__c FROM Claim_Notification__c WHERE Status__c = 'Queued' ORDER BY Send_After__c LIMIT 1];
        if (later.isEmpty()) return;
        AsyncOptions o = new AsyncOptions();
        o.MinimumQueueableDelayInMinutes = delayMinutes(later[0].Send_After__c, Datetime.now());
        // Tests can't chain a queueable from a queueable, so the next run is only queued outside tests.
        if (!Test.isRunningTest()) System.enqueueJob(new ClaimHubDispatchJob(), o);
    }

    /** Minutes until the next queued email is due, held between 1 and 10 so the hourly monitor stays the backstop. */
    @TestVisible static Integer delayMinutes(Datetime sendAfter, Datetime now) {
        Integer mins = (Integer) Math.ceil((sendAfter.getTime() - now.getTime()) / 60000.0);
        return Math.min(Math.max(mins, 1), 10);
    }
}
