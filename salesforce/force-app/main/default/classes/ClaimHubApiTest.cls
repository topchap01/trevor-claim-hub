@isTest
private class ClaimHubApiTest {

    static RestResponse call(String method, String path, Object body) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/claimhub/v1/' + path;
        req.httpMethod = method;
        req.addHeader('X-Hub-Client-IP', '198.51.100.7');
        if (body != null) req.requestBody = body instanceof String ? Blob.valueOf((String) body) : Blob.valueOf(JSON.serialize(body));
        RestContext.request = req;
        RestContext.response = new RestResponse();
        if (method == 'GET') ClaimHubApi.doGet(); else ClaimHubApi.doPost();
        return RestContext.response;
    }

    static Map<String, Object> json(RestResponse r) { return (Map<String, Object>) JSON.deserializeUntyped(r.responseBody.toString()); }

    @isTest static void routesTheClaimJourney() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        RestResponse r = call('GET', 'campaigns/' + ClaimHubTestFactory.SLUG, null);
        System.assertEquals(200, r.statusCode);
        System.assertEquals(3, ((List<Object>) json(r).get('products')).size());

        r = call('POST', 'campaigns/' + ClaimHubTestFactory.SLUG + '/claims', ClaimHubTestFactory.claimRequest(c.Id, 'api@example.com', 1, false, 'AU'));
        System.assertEquals(200, r.statusCode, r.responseBody.toString());
        String token = (String) json(r).get('token');
        System.assertNotEquals(null, [SELECT Hub_Client_IP_Hash__c FROM Entry__c WHERE Access_Token__c = :token].Hub_Client_IP_Hash__c, 'connection recorded, hashed');

        System.assertEquals(200, call('GET', 'claims/' + token, null).statusCode);
        System.assertEquals(200, call('POST', 'claims/' + token + '/code', new Map<String, Object>()).statusCode);
        Id productId = [SELECT Id FROM Entry_Product__c WHERE Entry__r.Access_Token__c = :token LIMIT 1].Id;
        System.assertEquals(200, call('POST', 'claims/' + token + '/serial', new Map<String, Object>{ 'productId' => productId, 'serial' => '61234567' }).statusCode);
        System.assertEquals(200, call('POST', 'resend', new Map<String, Object>{ 'slug' => ClaimHubTestFactory.SLUG, 'email' => 'api@example.com' }).statusCode);
    }

    @isTest static void refusalsRollBackButKeepTheFlag() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        String token = ClaimHubTestFactory.lodge(c.Id, 'flag@example.com', 1, false, 'AU');
        Id productId = [SELECT Id FROM Entry_Product__c WHERE Entry__r.Access_Token__c = :token LIMIT 1].Id;
        RestResponse r = call('POST', 'claims/' + token + '/serial', new Map<String, Object>{ 'productId' => productId, 'serial' => 'A1234567' });
        System.assertEquals(400, r.statusCode);
        System.assert(String.valueOf(json(r).get('error')).contains('T2'));
        System.assertEquals(1, ClaimHubTestFactory.events(ClaimHubTestFactory.entry(token).Id, 'Needs review: excluded serial'));
    }

    @isTest static void wrongSecurityCodesCountEvenThoughTheRequestRollsBack() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        String token = ClaimHubTestFactory.lodge(c.Id, 'otp@example.com', 1, true, 'AU');
        System.assertEquals(200, call('POST', 'claims/' + token + '/code', new Map<String, Object>()).statusCode);
        Map<String, Object> guess = new Map<String, Object>{ 'code' => '000000', 'name' => 'S Tester', 'bsb' => '063000', 'account' => '87654321' };
        for (Integer i = 0; i < 5; i++) System.assertEquals(401, call('POST', 'claims/' + token + '/bank', guess).statusCode);
        System.assertEquals(5, [SELECT Attempts__c FROM Claim_OTP__c WHERE Entry__r.Access_Token__c = :token].Attempts__c);
        System.assertEquals(429, call('POST', 'claims/' + token + '/bank', guess).statusCode, 'sixth guess is refused even with the right code');
        System.assertEquals(5, ClaimHubTestFactory.events(ClaimHubTestFactory.entry(token).Id, 'Wrong security code'));
    }

    @isTest static void aFreshLinkReplacesTheOldOne() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        String token = ClaimHubTestFactory.lodge(c.Id, 'fresh@example.com', 1, false, 'AU');
        System.assertEquals(200, call('POST', 'resend', new Map<String, Object>{ 'slug' => ClaimHubTestFactory.SLUG, 'email' => ' Fresh@example.com ' }).statusCode);
        System.assertEquals(404, call('GET', 'claims/' + token, null).statusCode, 'old link no longer works');
        System.assertEquals(1, [SELECT COUNT() FROM Entry__c WHERE Consumer_Email_Stamp__c = 'fresh@example.com' AND Access_Token__c != :token]);
    }

    @isTest static void filesMustBelongToTheClaim() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        String token = ClaimHubTestFactory.lodge(c.Id, 'file@example.com', 1, false, 'AU');
        Map<String, Object> req = ClaimHubTestFactory.receiptRequest();
        req.put('fileKey', 'invoices/someone-else/invoice.jpg');
        System.assertEquals(400, call('POST', 'claims/' + token + '/receipt', req).statusCode);
        req.remove('fileKey'); req.put('contentType', 'text/html');
        System.assertEquals(415, call('POST', 'claims/' + token + '/receipt', req).statusCode);
    }

    @isTest static void badRequestsGetPlainErrors() {
        ClaimHubTestFactory.campaign('AU', null);
        System.assertEquals(404, call('GET', 'nowhere', null).statusCode);
        System.assertEquals(404, call('GET', 'campaigns/unknown-promo', null).statusCode);
        System.assertEquals(400, call('POST', 'resend', 'this is not json').statusCode);
        System.assertEquals(400, call('POST', 'resend', '[1,2]').statusCode);
        RestResponse r = call('POST', 'campaigns/' + ClaimHubTestFactory.SLUG + '/claims', new Map<String, Object>{ 'firstName' => 'A', 'lastName' => 'B', 'email' => 'a@example.com', 'mobile' => '0412345678', 'products' => 'not a list' });
        System.assertEquals(400, r.statusCode, 'a field of the wrong type is the caller\'s mistake');
        System.assert(!r.responseBody.toString().contains('TypeException'), 'no internals leak to the caller');
        System.assertEquals(404, call('GET', 'files/' + 'x'.repeat(43), null).statusCode);
        RestResponse h = call('GET', 'health', null);
        System.assertEquals(200, h.statusCode);
        System.assert(json(h).containsKey('ok'));
    }
}
