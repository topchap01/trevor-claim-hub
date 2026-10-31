@isTest
private class ClaimHubLogTest {

    @isTest static void eventsAreTrimmedAndCountedPerDay() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        Entry__c e = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'log@example.com', 1, false, 'AU'));
        Integer before = ClaimHubLog.countToday(e.Id, 'Link resent');
        ClaimHubLog.event(e.Id, 'Claimant', 'Link resent', 'x'.repeat(300));
        ClaimHubLog.event(e.Id, 'Claimant', 'Link resent', null);
        System.assertEquals(before + 2, ClaimHubLog.countToday(e.Id, 'Link resent'));
        Claim_Event__c built = ClaimHubLog.build(e.Id, 'System', 'a'.repeat(100), 'd'.repeat(300));
        System.assertEquals(80, built.Action__c.length());
        System.assertEquals(255, built.Detail__c.length());
        System.assertEquals(null, ClaimHubLog.build(e.Id, 'System', null, null).Action__c);
    }

    @isTest static void errorsAndWarningsNeverThrow() {
        Test.startTest();
        String ref;
        try { Integer.valueOf('not a number'); } catch (Exception ex) { ref = ClaimHubLog.error('Test failure', ex); }
        ClaimHubLog.warn('Test warning');
        Test.stopTest();
        // With Nebula Logger installed the claimant is shown a reference; without it, logging falls back to debug and returns null.
        System.assert(ref == null || ref.length() > 0);
    }
}
