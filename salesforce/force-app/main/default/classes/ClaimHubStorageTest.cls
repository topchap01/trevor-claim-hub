@isTest
private class ClaimHubStorageTest {

    /** One receipt with a stored file per claim. Keys look like the web app's S3 keys. */
    static List<Entry_Receipt__c> withFiles(List<Entry__c> es) {
        List<Entry_Receipt__c> rs = new List<Entry_Receipt__c>();
        for (Integer i = 0; i < es.size(); i++) rs.add(new Entry_Receipt__c(Entry__c = es[i].Id, Hub_Has_File__c = true, Hub_File_Size__c = 1048576,
            Hub_File_Key__c = 'invoices/' + String.valueOf(i).leftPad(24, '0') + '/00000000-0000-4000-8000-' + String.valueOf(i).leftPad(12, '0') + '.jpg'));
        insert rs;
        return rs;
    }

    @isTest static void listsTheIndexInPages() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry_Receipt__c> rs = withFiles(ClaimHubTestFactory.bulkEntries(c.Id, 3, ClaimHubService.STATUS_COMPLETE));
        update new Entry_Receipt__c(Id = rs[2].Id, Hub_File_Removed__c = Datetime.now());

        Map<String, Object> page = (Map<String, Object>) ClaimHubApi.route('GET', new List<String>{ 'storage', 'keys' }, new Map<String, Object>());
        System.assertEquals(2, ((List<String>) page.get('keys')).size(), 'deleted files are not in the index');
        System.assertEquals(null, page.get('next'), 'one page');
        String firstId = [SELECT Id FROM Entry_Receipt__c WHERE Hub_File_Key__c != null ORDER BY Id LIMIT 1].Id;
        Map<String, Object> after = ClaimHubStorage.keys(firstId);
        System.assertEquals(1, ((List<String>) after.get('keys')).size());
        Integer status;
        try { ClaimHubStorage.keys('not-an-id'); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(400, status);
    }

    @isTest static void nothingIsDueWithoutARetentionPeriod() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 1, ClaimHubService.STATUS_COMPLETE);
        withFiles(es);
        update new Entry__c(Id = es[0].Id, EFT_Status__c = 'Fulfilled');
        Map<String, Object> d = (Map<String, Object>) ClaimHubApi.route('GET', new List<String>{ 'storage', 'due' }, new Map<String, Object>());
        System.assertEquals(null, d.get('months'));
        System.assert(((List<String>) d.get('keys')).isEmpty(), 'blank setting keeps every file');
    }

    @isTest static void filesFallDueAfterTheClaimIsSettled() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 4, ClaimHubService.STATUS_COMPLETE);
        List<Entry_Receipt__c> rs = withFiles(es);
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Invoice_Retention_Months__c = 12);
        // es[0] paid 13 months ago, es[1] paid last week, es[2] rejected 13 months ago, es[3] still with the team
        update new List<Entry__c>{ new Entry__c(Id = es[0].Id, EFT_Status__c = 'Fulfilled'), new Entry__c(Id = es[1].Id, EFT_Status__c = 'Fulfilled'),
                                   new Entry__c(Id = es[2].Id, Entry_Status__c = 'Invalid') };
        Claim_Event__c old0 = ClaimHubLog.build(es[0].Id, 'Team', 'Paid', null), new1 = ClaimHubLog.build(es[1].Id, 'Team', 'Paid', null),
                       old2 = ClaimHubLog.build(es[2].Id, 'Team', 'Not approved', null);
        insert new List<Claim_Event__c>{ old0, new1, old2 };
        Test.setCreatedDate(old0.Id, Datetime.now().addMonths(-13));
        Test.setCreatedDate(old2.Id, Datetime.now().addMonths(-13));
        delete [SELECT Id FROM Claim_Event__c WHERE Entry__c IN (:es[0].Id, :es[1].Id, :es[2].Id) AND Id NOT IN (:old0.Id, :new1.Id, :old2.Id)];

        List<String> due = (List<String>) ClaimHubStorage.due().get('keys');
        System.assertEquals(new Set<String>{ rs[0].Hub_File_Key__c, rs[2].Hub_File_Key__c }, new Set<String>(due));
    }

    @isTest static void decidesWhenEachStageIsDue() {
        Datetime cutoff = Datetime.now(), before = cutoff.addDays(-1), after = cutoff.addDays(1);
        System.assert(ClaimHubStorage.isDue('paid', before, null, cutoff));
        System.assert(!ClaimHubStorage.isDue('paid', after, before, cutoff), 'settled date wins over claims closing');
        System.assert(ClaimHubStorage.isDue('not_approved', null, before, cutoff), 'settled before the hub logged it: claims close');
        System.assert(!ClaimHubStorage.isDue('not_approved', null, null, cutoff));
        System.assert(ClaimHubStorage.isDue('awaiting', null, before, cutoff), 'never completed, claims long closed');
        System.assert(!ClaimHubStorage.isDue('awaiting', null, after, cutoff));
        for (String stage : new List<String>{ 'review', 'approved', 'payment_failed' }) {
            System.assert(!ClaimHubStorage.isDue(stage, before, before, cutoff), stage + ' still needs its invoice');
        }
    }

    @isTest static void recordsTheNightlyCheck() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 3, ClaimHubService.STATUS_COMPLETE);
        List<Entry_Receipt__c> rs = withFiles(es);
        Map<String, Object> body = new Map<String, Object>{ 'store' => 'trevor-claim-hub/sandbox/invoices/', 'files' => 41, 'bytes' => 5242880,
            'unlinked' => 3, 'unlinkedRemoved' => 2, 'expiredRemoved' => new List<Object>{ rs[0].Hub_File_Key__c },
            'missing' => new List<Object>{ rs[1].Hub_File_Key__c }, 'problems' => new List<Object>() };

        Map<String, Object> out = (Map<String, Object>) ClaimHubApi.route('POST', new List<String>{ 'storage', 'report' }, body);
        System.assertEquals(1, out.get('markedRemoved'));
        System.assertEquals(1, out.get('flaggedMissing'));
        System.assertNotEquals(null, [SELECT Hub_File_Removed__c FROM Entry_Receipt__c WHERE Id = :rs[0].Id].Hub_File_Removed__c);
        System.assertEquals(1, ClaimHubTestFactory.events(es[0].Id, 'Internal: invoice file deleted'));
        System.assertEquals(1, ClaimHubTestFactory.events(es[1].Id, ClaimHubStorage.MISSING_ACTION));

        // A second night with the same file still missing does not raise it again
        out = ClaimHubStorage.report(body);
        System.assertEquals(0, out.get('markedRemoved'), 'already marked');
        System.assertEquals(0, out.get('flaggedMissing'), 'raised once');
        Hub_Storage_Check__c k = ClaimHubStorage.latest();
        System.assertEquals(41, k.Files__c);
        System.assertEquals(2, k.Unlinked_Removed__c);
        System.assertEquals(1, k.Missing__c);
        System.assertEquals('trevor-claim-hub/sandbox/invoices/', k.Store__c);
        System.assertEquals(2, [SELECT COUNT() FROM Hub_Storage_Check__c]);
    }

    @isTest static void alertsOnceWhenACheckFindsSomething() {
        System.assert(ClaimHubStorage.alerts().isEmpty(), 'no check yet, nothing to say');
        insert new Hub_Storage_Check__c(Files__c = 10, Missing__c = 2, Problems__c = 'Could not list the store');
        List<String> a = ClaimHubStorage.alerts();
        System.assertEquals(2, a.size(), String.join(a, '; '));
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Alert_Email__c = 'ops@example.com');
        System.assertEquals(2, ClaimHubMonitor.check().size(), 'emailed with the hourly check');
        Hub_Storage_Check__c old = new Hub_Storage_Check__c(Files__c = 10);
        insert old;
        Test.setCreatedDate(old.Id, Datetime.now().addHours(-36).addMinutes(-10));
        delete [SELECT Id FROM Hub_Storage_Check__c WHERE Id != :old.Id];
        System.assertEquals(new List<String>{ 'The nightly invoice storage check has not run for 36 hours' }, ClaimHubStorage.alerts());
    }

    @isTest static void consoleShowsTheCampaignsFiles() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('AU', null);
        List<Entry__c> es = ClaimHubTestFactory.bulkEntries(c.Id, 2, ClaimHubService.STATUS_COMPLETE);
        withFiles(es);
        Map<String, Object> s = ClaimHubConsole.storage(c.Id, 'Australia/Sydney');
        List<Object> rows = (List<Object>) s.get('rows');
        System.assertEquals('2', ((Map<String, Object>) rows[0]).get('value'));
        System.assertEquals('2.0 MB', ((Map<String, Object>) rows[1]).get('value'));
        System.assertEquals(null, s.get('check'), 'no nightly check yet');

        ClaimHubSettings.current = new Claim_Hub_Settings__c(Invoice_Retention_Months__c = 12);
        insert new Hub_Storage_Check__c(Files__c = 2, Missing__c = 0);
        s = ClaimHubConsole.storage(c.Id, 'Australia/Sydney');
        System.assertEquals(6, ((List<Object>) s.get('rows')).size(), 'adds the next 30 days');
        System.assertEquals(true, ((Map<String, Object>) s.get('check')).get('ok'));
        System.assertNotEquals(null, ClaimHubConsole.summary(c.Id).get('storage'));
        System.assertEquals('0 MB', ClaimHubConsole.size(null));
        System.assertEquals('500 KB', ClaimHubConsole.size(512000));
        System.assertEquals('1.50 GB', ClaimHubConsole.size(1610612736));
    }
}
