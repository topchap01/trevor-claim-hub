/**
 * Server-to-server API for the claim hub web app. Callable only by the hub's integration user (OAuth JWT),
 * never by anonymous website visitors.
 *   GET  /claimhub/v1/campaigns/{slug}
 *   POST /claimhub/v1/campaigns/{slug}/claims
 *   GET  /claimhub/v1/claims/{token}
 *   POST /claimhub/v1/claims/{token}/serial | receipt | plate | code | bank
 *   POST /claimhub/v1/resend
 *   GET  /claimhub/v1/files/{ticket}      staff invoice link (short-lived ticket from ClaimHubConsole.invoiceLink)
 *   GET  /claimhub/v1/health              uptime check
 * The web app passes the claimant's IP address in X-Hub-Client-IP; it is only stored hashed.
 */
@RestResource(urlMapping='/claimhub/v1/*')
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
global without sharing class ClaimHubApi {

    @HttpGet
    global static void doGet() { handle('GET'); }

    @HttpPost
    global static void doPost() { handle('POST'); }

    static void handle(String method) {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        res.addHeader('Cache-Control', 'no-store');
        List<String> p = req.requestURI.substringAfter('/claimhub/v1/').removeEnd('/').split('/');
        // Routes that call Claude can't hold a savepoint (Salesforce blocks callouts while one is open).
        Boolean callsOut = p.size() == 3 && (p[2] == 'receipt' || p[2] == 'plate' || p[2] == 'chat');
        Savepoint sp = callsOut ? null : Database.setSavepoint();
        try {
            Map<String, Object> body = (method == 'POST' && req.requestBody != null && req.requestBody.size() > 0)
                ? body(req.requestBody) : new Map<String, Object>();
            String ip = req.headers == null ? null : req.headers.get('X-Hub-Client-IP');
            if (String.isNotBlank(ip)) body.put('_ip', ip.left(64));
            Object out = route(method, p, body);
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(out));
        } catch (ClaimHubService.HubException ex) {
            if (sp != null) Database.rollback(sp);
            // A refusal can still need the team (duplicate or excluded serial): record it after the rollback
            if (ex.flagEntry != null) ClaimHubLog.event(ex.flagEntry, 'System', ex.flagAction, ex.flagDetail);
            if (ex.failedOtp != null) countFailedCode(ex.failedOtp);
            res.statusCode = ex.status;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'error' => ex.getMessage() }));
        } catch (TypeException ex) {
            // A field of the wrong type (e.g. products not a list): the caller's mistake, not ours
            if (sp != null) Database.rollback(sp);
            res.statusCode = 400;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'error' => 'Bad request' }));
        } catch (Exception ex) {
            if (sp != null) Database.rollback(sp);
            // Details stay in the log; the caller gets a reference support can look up
            String ref = ClaimHubLog.error('Claim hub API ' + method + ' /' + String.join(p, '/').replaceAll('[A-Za-z0-9_-]{40,64}', '{token}'), ex);
            res.statusCode = 500;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'error' => 'Something went wrong. Please try again.', 'ref' => ref }));
        }
    }

    static void countFailedCode(Id otpId) {
        for (Claim_OTP__c o : [SELECT Attempts__c FROM Claim_OTP__c WHERE Id = :otpId FOR UPDATE]) {
            o.Attempts__c = (o.Attempts__c == null ? 0 : o.Attempts__c) + 1;
            update o;
        }
    }

    static Map<String, Object> body(Blob b) {
        Object parsed;
        try { parsed = JSON.deserializeUntyped(b.toString()); } catch (Exception ex) { throw new ClaimHubService.HubException(400, 'Bad request'); }
        if (!(parsed instanceof Map<String, Object>)) throw new ClaimHubService.HubException(400, 'Bad request');
        return (Map<String, Object>) parsed;
    }

    @TestVisible
    static Object route(String method, List<String> p, Map<String, Object> body) {
        String head = p.isEmpty() ? '' : p[0];
        if (head == 'campaigns' && p.size() == 2 && method == 'GET') return ClaimHubService.publicCampaign(p[1]);
        if (head == 'campaigns' && p.size() == 3 && p[2] == 'claims' && method == 'POST') return ClaimHubService.lodge(p[1], body);
        if (head == 'campaigns' && p.size() == 3 && p[2] == 'chat' && method == 'POST') return ClaimHubAssistant.chatForCampaign(p[1], body);
        if (head == 'claims' && p.size() == 2 && method == 'GET') return ClaimHubService.view(p[1]);
        if (head == 'claims' && p.size() == 3 && method == 'POST') {
            if (p[2] == 'serial') return ClaimHubService.addSerial(p[1], body);
            if (p[2] == 'receipt') return ClaimHubService.addReceipt(p[1], body);
            if (p[2] == 'code') return ClaimHubService.requestCode(p[1]);
            if (p[2] == 'plate') return ClaimHubService.readPlate(p[1], body);
            if (p[2] == 'chat') return ClaimHubAssistant.chatForClaim(p[1], body);
            if (p[2] == 'bank') return ClaimHubService.changeBank(p[1], body);
        }
        if (head == 'resend' && method == 'POST') return ClaimHubService.resendLink(body);
        if (head == 'files' && p.size() == 2 && method == 'GET') return ClaimHubFiles.resolve(p[1]);
        if (head == 'health' && p.size() == 1 && method == 'GET') return ClaimHubMonitor.snapshot();
        throw new ClaimHubService.HubException(404, 'Not found');
    }
}
