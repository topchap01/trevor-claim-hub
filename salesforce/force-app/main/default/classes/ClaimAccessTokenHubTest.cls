@isTest
private class ClaimAccessTokenHubTest {
    @isTest static void codesAreRandomAndExact() {
        String a = ClaimAccessToken.newToken(), b = ClaimAccessToken.newToken();
        System.assertNotEquals(a, b);
        System.assertEquals(43, a.length());
        System.assert(Pattern.matches('^[A-Za-z0-9_-]+$', a));
        System.assertEquals(null, ClaimAccessToken.resolve(null));
        System.assertEquals(null, ClaimAccessToken.resolve('short'));
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        Entry__c e = ClaimHubTestFactory.bulkEntries(c.Id, 1, ClaimHubService.STATUS_AWAITING)[0];
        String token = [SELECT Access_Token__c FROM Entry__c WHERE Id = :e.Id].Access_Token__c;
        System.assertEquals(e.Id, ClaimAccessToken.resolve(token).Id);
        System.assertEquals(null, ClaimAccessToken.resolve(token.toUpperCase().equals(token) ? token.toLowerCase() : token.toUpperCase()), 'case matters');
        System.assertEquals(token, ClaimAccessToken.ensureToken(e.Id), 'existing code kept');
        String fresh = ClaimAccessToken.rotate(e.Id);
        System.assertNotEquals(token, fresh);
        System.assertEquals(null, ClaimAccessToken.resolve(token));
        System.assertEquals('•••678', ClaimAccessToken.mask('12-345-678'));
        System.assert(ClaimAccessToken.isMasked('•••678'));
        System.assert(!ClaimAccessToken.isGuest());
    }
}
