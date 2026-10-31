@isTest
private class ClaimHubNotifierTest {

    @isTest static void everyTemplateRenders() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('NZ', null);
        String token = ClaimHubTestFactory.lodge(c.Id, 'tpl@example.com', 2, true, 'NZ');
        Entry__c e = ClaimHubService.load(ClaimHubTestFactory.entry(token).Id);
        e.Consumer_First_Name_Stamp__c = '<b>Sam</b>';
        e.Invalid_Reason__c = 'Not a participating model';
        for (String key : new List<String>{ 'LODGED', 'PROGRESS', 'COMPLETE', 'VALID', 'PAID', 'EFT_FAILED', 'BANK_CHANGED', 'INVALID', 'REMINDER', 'LINK' }) {
            List<String> parts = ClaimHubNotifier.render(key, e, 'Your invoice');
            System.assertNotEquals(null, parts, key);
            System.assert(!parts[1].contains('<b>Sam</b>'), key + ': claimant text is escaped');
            System.assert(parts[1].contains(c.Hub_Base_URL__c) || key == 'PAID' || key == 'BANK_CHANGED' || key == 'INVALID', key + ' links to the claim');
        }
        System.assertEquals(null, ClaimHubNotifier.render('NOPE', e, null));
        System.assert(ClaimHubNotifier.link(e).contains('&s=' + ClaimHubTestFactory.SLUG));
    }

    @isTest static void theOutboxSendsAndBatchesChanges() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        Entry__c e = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'outbox@example.com', 1, false, 'AU'));
        ClaimHubNotifier.addToSummary(e.Id, 'Your invoice');
        ClaimHubNotifier.addToSummary(e.Id, 'Serial number for your oven');
        Claim_Notification__c summary = [SELECT Changes__c FROM Claim_Notification__c WHERE Entry__c = :e.Id AND Template_Key__c = 'PROGRESS'];
        System.assertEquals('Your invoice\nSerial number for your oven', summary.Changes__c, 'two changes, one email');

        update new Claim_Notification__c(Id = summary.Id, Send_After__c = Datetime.now().addMinutes(-1));
        Test.startTest();
        ClaimHubNotifier.dispatchDue();
        Test.stopTest();
        for (Claim_Notification__c n : [SELECT Template_Key__c, Status__c, Subject__c FROM Claim_Notification__c WHERE Entry__c = :e.Id]) {
            System.assertEquals('Sent', n.Status__c, n.Template_Key__c);
            System.assertNotEquals(null, n.Subject__c);
        }
        ClaimHubNotifier.addToSummary(e.Id, 'Bank details');
        ClaimHubNotifier.mergePendingSummary(e.Id);
        System.assertEquals(0, [SELECT COUNT() FROM Claim_Notification__c WHERE Entry__c = :e.Id AND Status__c = 'Queued'], 'pending summary merged into the completion email');
    }

    @isTest static void securityCodesAreNeverStored() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        Entry__c e = ClaimHubService.load(ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'code@example.com', 1, false, 'AU')).Id);
        ClaimHubNotifier.sendCode(e, '654321');
        Claim_Notification__c n = [SELECT Body__c, Status__c FROM Claim_Notification__c WHERE Entry__c = :e.Id AND Template_Key__c = 'CODE'];
        System.assert(!n.Body__c.contains('654321'));
        System.assertEquals('Sent', n.Status__c);
    }

    @isTest static void theDispatchJobRuns() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        Entry__c e = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'job@example.com', 1, false, 'AU'));
        Test.startTest();
        System.enqueueJob(new ClaimHubDispatchJob());
        Test.stopTest();
        System.assertEquals('Sent', [SELECT Status__c FROM Claim_Notification__c WHERE Entry__c = :e.Id AND Template_Key__c = 'LODGED'].Status__c);
    }

    @isTest static void anEmailDueLaterWaitsForTheNextRun() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        Entry__c e = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'later@example.com', 1, false, 'AU'));
        ClaimHubNotifier.addToSummary(e.Id, 'Your invoice');
        Claim_Notification__c summary = [SELECT Id FROM Claim_Notification__c WHERE Entry__c = :e.Id AND Template_Key__c = 'PROGRESS'];
        update new Claim_Notification__c(Id = summary.Id, Send_After__c = Datetime.now().addMinutes(5));
        Test.startTest();
        System.enqueueJob(new ClaimHubDispatchJob());
        Test.stopTest();
        System.assertEquals('Queued', [SELECT Status__c FROM Claim_Notification__c WHERE Id = :summary.Id].Status__c, 'not due yet');

        Datetime now = Datetime.newInstanceGmt(2026, 10, 31, 9, 0, 0);
        System.assertEquals(1, ClaimHubDispatchJob.delayMinutes(now.addMinutes(-30), now), 'overdue runs as soon as allowed');
        System.assertEquals(4, ClaimHubDispatchJob.delayMinutes(now.addSeconds(200), now), 'rounded up to whole minutes');
        System.assertEquals(10, ClaimHubDispatchJob.delayMinutes(now.addMinutes(45), now), 'never waits more than 10 minutes');
    }
}
