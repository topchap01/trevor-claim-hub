@isTest
private class ClaimHubMonitorTest {

    @isTest static void healthyWhenNothingIsStuck() {
        Map<String, Object> s = ClaimHubMonitor.snapshot();
        System.assertEquals(true, s.get('ok'));
        System.assert(ClaimHubMonitor.check().isEmpty());
    }

    @isTest static void alertsWhenEmailsAreStuckOrFailing() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 1, ClaimHubService.STATUS_AWAITING);
        insert new List<Claim_Notification__c>{
            new Claim_Notification__c(Entry__c = es[0].Id, Template_Key__c = 'LODGED', Status__c = 'Queued', Send_After__c = Datetime.now().addHours(-2), Attempts__c = 0),
            new Claim_Notification__c(Entry__c = es[0].Id, Template_Key__c = 'LINK', Status__c = 'Failed', Send_After__c = Datetime.now(), Attempts__c = 3) };
        List<Entry_Receipt__c> rs = new List<Entry_Receipt__c>();
        for (Integer i = 0; i < 5; i++) rs.add(new Entry_Receipt__c(Entry__c = es[0].Id, Hub_Has_File__c = true, OCR_Status__c = 'Not read'));
        insert rs;
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Alert_Email__c = 'ops@example.com');
        List<String> problems = ClaimHubMonitor.check();
        System.assertEquals(3, problems.size(), String.join(problems, '; '));
        Test.startTest();
        System.schedule('Claim hub monitor test', '0 5 * * * ?', new ClaimHubMonitor());
        Test.stopTest();
    }
}
