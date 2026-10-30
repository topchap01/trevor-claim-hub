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

    @isTest static void badRequestsGetPlainErrors() {
        ClaimHubTestFactory.campaign('AU', null);
        System.assertEquals(404, call('GET', 'nowhere', null).statusCode);
        System.assertEquals(404, call('GET', 'campaigns/unknown-promo', null).statusCode);
        System.assertEquals(400, call('POST', 'resend', 'this is not json').statusCode);
        System.assertEquals(400, call('POST', 'resend', '[1,2]').statusCode);
        RestResponse r = call('POST', 'campaigns/' + ClaimHubTestFactory.SLUG + '/claims', new Map<String, Object>{ 'firstName' => 'A', 'lastName' => 'B', 'email' => 'a@example.com', 'mobile' => '0412345678', 'products' => 'not a list' });
        System.assertEquals(500, r.statusCode, 'unexpected failure');
        System.assert(!r.responseBody.toString().contains('TypeException'), 'no internals leak to the caller');
        System.assertEquals(404, call('GET', 'files/' + 'x'.repeat(43), null).statusCode);
        RestResponse h = call('GET', 'health', null);
        System.assertEquals(200, h.statusCode);
        System.assert(json(h).containsKey('ok'));
    }
}
