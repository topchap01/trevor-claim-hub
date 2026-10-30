@isTest
private class ClaimHubEntryHandlerTest {

    @isTest static void aPaymentFileEmailsEveryClaimantInOneGo() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Id> ids = new List<Id>();
        for (Entry__c e : ClaimHubTestFactory.bulkEntries(c.Id, 40, ClaimHubService.STATUS_COMPLETE)) ids.add(e.Id);
        List<Entry__c> ups = new List<Entry__c>();
        for (Integer i = 0; i < ids.size(); i++) {
            ups.add(i < 20 ? new Entry__c(Id = ids[i], Entry_Status__c = 'Valid') : new Entry__c(Id = ids[i], Entry_Status__c = 'Valid', EFT_Status__c = 'Fulfilled'));
        }
        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        update ups;
        Integer used = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();
        System.assertEquals(20, [SELECT COUNT() FROM Claim_Notification__c WHERE Template_Key__c = 'VALID']);
        System.assertEquals(20, [SELECT COUNT() FROM Claim_Notification__c WHERE Template_Key__c = 'PAID']);
        System.assert(used < 50, 'bulk update used ' + used + ' DML statements (limit 150)');
        // A second save of the same status sends nothing new
        update new Entry__c(Id = ids[0], Entry_Status__c = 'Valid');
        System.assertEquals(20, [SELECT COUNT() FROM Claim_Notification__c WHERE Template_Key__c = 'VALID']);
    }

    @isTest static void mapsStatusChangesToEmails() {
        Entry__c before = new Entry__c(Entry_Status__c = 'Submitted');
        System.assertEquals('INVALID', ClaimHubEntryHandler.keyFor(new Entry__c(Entry_Status__c = 'Invalid'), before));
        System.assertEquals('EFT_FAILED', ClaimHubEntryHandler.keyFor(new Entry__c(Entry_Status__c = 'Submitted', EFT_Status__c = 'EFT Failed'), before));
        System.assertEquals(null, ClaimHubEntryHandler.keyFor(new Entry__c(Entry_Status__c = 'Submitted'), before));
    }

    @isTest static void remindersFollowTheSchedule() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        Entry__c e = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'remind@example.com', 1, false, 'AU'));
        Test.setCreatedDate(e.Id, Datetime.now().addDays(-8));
        Test.startTest();
        System.assertEquals(1, ClaimHubReminders.run(Date.today()), 'first reminder at 7 days');
        System.assertEquals(0, ClaimHubReminders.run(Date.today()), 'not again until 21 days');
        System.schedule('Claim hub reminders test', '0 0 9 * * ?', new ClaimHubReminders());
        Test.stopTest();
        System.assertEquals(1, ClaimHubTestFactory.events(e.Id, 'Reminder 1'));
        System.assert(ClaimHubReminders.due(1, 21, null, Date.today()));
        System.assert(ClaimHubReminders.due(2, 30, Datetime.now().addDays(10), Date.today()));
        System.assert(ClaimHubReminders.due(3, 30, Datetime.now().addDays(2), Date.today()));
        System.assert(!ClaimHubReminders.due(4, 300, Datetime.now(), Date.today()));
    }
}
