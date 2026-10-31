/**
 * Health of the claim hub, for the uptime check (GET /claimhub/v1/health through the web app's /api/health)
 * and an hourly scheduled job that sends anything stuck in the email outbox and emails an alert when something is wrong.
 * Schedule: System.schedule('Claim hub monitor', '0 5 * * * ?', new ClaimHubMonitor());
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubMonitor implements Schedulable {

    public void execute(SchedulableContext ctx) {
        ClaimHubNotifier.dispatchDue();
        check();
    }

    /** Numbers only, no personal data: safe to return from the public health route. */
    public static Map<String, Object> snapshot() {
        Datetime now = Datetime.now(), hourAgo = now.addHours(-1), dayAgo = now.addDays(-1), stuckSince = now.addMinutes(-30);
        Integer overdue = [SELECT COUNT() FROM Claim_Notification__c WHERE Status__c = 'Queued' AND Send_After__c < :stuckSince];
        Integer failedDay = [SELECT COUNT() FROM Claim_Notification__c WHERE Status__c = 'Failed' AND LastModifiedDate >= :dayAgo];
        Integer failedHour = [SELECT COUNT() FROM Claim_Notification__c WHERE Status__c = 'Failed' AND LastModifiedDate >= :hourAgo];
        Integer claimsDay = [SELECT COUNT() FROM Entry__c WHERE Promotional_Campaign__r.Hub_Enabled__c = true AND CreatedDate >= :dayAgo];
        Integer readsDay = [SELECT COUNT() FROM Entry_Receipt__c WHERE Hub_Has_File__c = true AND LastModifiedDate >= :dayAgo];
        Integer notReadDay = [SELECT COUNT() FROM Entry_Receipt__c WHERE Hub_Has_File__c = true AND OCR_Status__c = 'Not read' AND LastModifiedDate >= :dayAgo];
        Integer needsReview = [SELECT COUNT() FROM Claim_Event__c WHERE Action__c LIKE 'Needs review%' AND CreatedDate >= :dayAgo];
        Map<String, Object> registers = ClaimHubBank.registerCounts();
        List<String> problems = new List<String>();
        if (overdue > 0) problems.add(overdue + ' email' + (overdue == 1 ? '' : 's') + ' waiting more than 30 minutes to send');
        // Alerts look at the last hour so one failure is reported once, not every hour for a day
        if (failedHour > 0) problems.add(failedHour + ' email' + (failedHour == 1 ? '' : 's') + ' failed in the last hour');
        if (readsDay >= 5 && notReadDay * 100 / readsDay >= 30) problems.add(notReadDay + ' of ' + readsDay + ' invoices could not be read automatically in the last 24 hours (is Claude reachable?)');
        return new Map<String, Object>{ 'ok' => problems.isEmpty(), 'checkedAt' => now, 'problems' => problems,
            'emailsOverdue' => overdue, 'emailsFailedLastHour' => failedHour, 'emailsFailed24h' => failedDay, 'claims24h' => claimsDay,
            'invoicesRead24h' => readsDay, 'invoicesNotRead24h' => notReadDay, 'flaggedForReview24h' => needsReview,
            // Rows in the bank registers. 0 means bank details are checked by format and check digit only.
            'bankRegisterRows' => registers };
    }

    /** Emails the alert address if the snapshot shows a problem. Returns the problems found. */
    public static List<String> check() {
        Map<String, Object> snap = snapshot();
        List<String> problems = (List<String>) snap.get('problems');
        if (problems.isEmpty()) return problems;
        ClaimHubLog.warn('Claim hub health: ' + String.join(problems, '; '));
        String to = ClaimHubSettings.alertEmail();
        if (String.isNotBlank(to)) {
            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setToAddresses(new List<String>{ to });
            m.setSubject('Claim hub needs attention: ' + problems[0]);
            m.setPlainTextBody('The hourly claim hub check found:\n\n- ' + String.join(problems, '\n- ') +
                '\n\nOpen the Claim Hub app in Salesforce and the runbook (docs/runbook.md) for what to do.');
            try { Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ m }, false); } catch (Exception ex) { ClaimHubLog.warn('Alert email failed: ' + ex.getMessage()); }
        }
        return problems;
    }
}
