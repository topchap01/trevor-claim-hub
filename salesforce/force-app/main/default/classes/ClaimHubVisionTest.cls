@isTest
private class ClaimHubVisionTest {

    static HttpResponse res(Integer status, String text) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(status);
        r.setBody(JSON.serialize(new Map<String, Object>{ 'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => text } } }));
        return r;
    }

    @isTest static void parsesWhatClaudeSends() {
        System.assertEquals('1', ClaimHubVision.parseJson(res(200, 'Sure: {"a":"1"} hope that helps')).get('a'));
        System.assert(ClaimHubVision.parseJson(res(200, 'no json here')).containsKey('error'));
        System.assert(ClaimHubVision.parseJson(res(200, '{not valid}')).containsKey('error'));
        System.assert(ClaimHubVision.parseJson(res(529, '')).containsKey('error'));
        System.assert(ClaimHubVision.parseJson(null).containsKey('error'));
    }

    @isTest static void timeoutsDegradeInsteadOfFailing() {
        ClaimHubTestFactory.claude().fail = true;
        Test.startTest();
        System.assert(ClaimHubVision.readInvoice('eA==', 'application/pdf').containsKey('error'));
        System.assertEquals(null, ClaimHubVision.chat('system', new List<Object>()));
        Test.stopTest();
    }

    @isTest static void settingsHaveDefaults() {
        System.assertEquals(10, ClaimHubSettings.debounceMinutes());
        System.assertEquals('claude-sonnet-4-6', ClaimHubSettings.model());
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Debounce_Minutes__c = 2, Model__c = 'claude-test');
        System.assertEquals(2, ClaimHubSettings.debounceMinutes());
        System.assertEquals('claude-test', ClaimHubSettings.model());
        System.assertEquals(40, ClaimHubSettings.chatDailyLimit());
        System.assertEquals(null, ClaimHubSettings.alertEmail());
    }
}
