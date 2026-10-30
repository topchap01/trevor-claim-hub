@isTest
private class ClaimHubConsoleTest {

    @isTest static void showsTheCampaignAndTheWork() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        c.Hub_Terms_Issues__c = '[HIGH] Clause 4: dates contradict\n[LOW] Clause 9: typo'; c.Hub_Min_Spend__c = 1000; c.Hub_Single_Transaction__c = true; update c;
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 3, ClaimHubService.STATUS_COMPLETE);
        insert new Entry_Receipt__c(Entry__c = es[0].Id, OCR_Status__c = 'Check: Retailer is not Harvey Norman', Hub_Has_File__c = true);
        ClaimHubLog.event(es[1].Id, 'System', 'Needs review: duplicate serial', '61234567');

        System.assertEquals(1, ClaimHubConsole.campaigns().size());
        Map<String, Object> s = ClaimHubConsole.summary(c.Id);
        System.assertEquals('Open for claims', s.get('state'));
        System.assertEquals(3, ((List<Object>) s.get('ready')).size());
        System.assertEquals(2, ((List<Object>) s.get('queue')).size(), 'flag plus invoice check');
        System.assertEquals(2, ((List<Object>) s.get('issues')).size());
        System.assert(((List<String>) s.get('rules')).contains('One invoice'));
        System.assert(!ClaimHubConsole.reasons().isEmpty());
    }

    @isTest static void approvesAndRejects() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 3, ClaimHubService.STATUS_COMPLETE);
        ClaimHubConsole.approve(es[0].Id);
        System.assertEquals('Valid', [SELECT Entry_Status__c FROM Entry__c WHERE Id = :es[0].Id].Entry_Status__c);
        String reason = (String) ClaimHubConsole.reasons()[0].get('value');
        ClaimHubConsole.reject(es[1].Id, reason);
        System.assertEquals('Invalid', [SELECT Entry_Status__c FROM Entry__c WHERE Id = :es[1].Id].Entry_Status__c);
        Boolean refused = false;
        try { ClaimHubConsole.approve(es[0].Id); } catch (AuraHandledException ex) { refused = true; }
        System.assert(refused, 'only complete claims can be approved');
        refused = false;
        try { ClaimHubConsole.reject(es[2].Id, ''); } catch (AuraHandledException ex) { refused = true; }
        System.assert(refused, 'a reason is required');
        System.assertEquals(1, [SELECT COUNT() FROM Claim_Notification__c WHERE Template_Key__c = 'INVALID']);
    }

    @isTest static void opensInvoicesThroughShortLivedTickets() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 3, ClaimHubService.STATUS_COMPLETE);
        System.assertEquals(null, ClaimHubConsole.invoiceLink(es[2].Id), 'no receipt yet');

        Entry_Receipt__c outside = new Entry_Receipt__c(Entry__c = es[0].Id, Hub_File_Key__c = 'claims/x/invoice.jpg', Hub_Has_File__c = true);
        Entry_Receipt__c inside = new Entry_Receipt__c(Entry__c = es[1].Id, Hub_Has_File__c = true);
        insert new List<Entry_Receipt__c>{ outside, inside };
        insert new ContentVersion(Title = 'invoice.jpg', PathOnClient = '/invoice.jpg', VersionData = Blob.valueOf('x'), FirstPublishLocationId = inside.Id);

        String link = ClaimHubConsole.invoiceLink(es[0].Id);
        System.assert(link.startsWith('https://claims.example.com/api/file?t='), link);
        String ticket = link.substringAfter('t=');
        System.assertEquals('claims/x/invoice.jpg', ClaimHubFiles.resolve(ticket).get('key'));
        System.assert(ClaimHubConsole.invoiceLink(es[1].Id).startsWith('/lightning/r/ContentDocument/'));

        update new Entry_Receipt__c(Id = outside.Id, Hub_File_Ticket_Expires__c = Datetime.now().addMinutes(-1));
        Integer status;
        try { ClaimHubFiles.resolve(ticket); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(404, status, 'expired tickets stop working');
        try { ClaimHubFiles.resolve('short'); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(404, status);

        ClaimHubSettings.current = new Claim_Hub_Settings__c(File_Base_URL__c = 'https://files.example.com');
        System.assert(ClaimHubConsole.invoiceLink(es[0].Id).startsWith('https://files.example.com/api/file?t='));
    }
}
