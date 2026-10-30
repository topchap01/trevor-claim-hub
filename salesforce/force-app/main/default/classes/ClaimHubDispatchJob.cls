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
        if (!later.isEmpty() && !Test.isRunningTest()) {
            Integer mins = (Integer) Math.ceil((later[0].Send_After__c.getTime() - Datetime.now().getTime()) / 60000.0);
            AsyncOptions o = new AsyncOptions();
            o.MinimumQueueableDelayInMinutes = Math.min(Math.max(mins, 1), 10);
            System.enqueueJob(new ClaimHubDispatchJob(), o);
        }
    }
}
