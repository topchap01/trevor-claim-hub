@isTest
private class ClaimHubTermsTest {

    static Map<String, Object> spec() {
        return new Map<String, Object>{
            'promotionName' => 'TestBrand Summer Cashback', 'brand' => 'TestBrand', 'promoter' => 'TestBrand Pty Ltd', 'country' => 'NZ', 'currency' => 'NZD',
            'timezone' => 'Pacific/Auckland', 'retailers' => new List<Object>{ 'Harvey Norman' },
            'purchaseStart' => '2026-08-01', 'purchaseEnd' => '2026-08-31',
            'claimsOpen' => '2026-08-01T00:00', 'claimsClose' => '2026-09-30T23:59', 'serialDeadline' => '2026-11-30T23:59', 'bankDeadline' => '2026-12-31T23:59',
            'minProducts' => 2, 'maxProducts' => null, 'minSpend' => 5000, 'singleTransaction' => true, 'tierBasis' => 'spend',
            'tiers' => new List<Object>{
                new Map<String, Object>{ 'minSpend' => 5000, 'maxSpend' => 9999.99, 'amount' => 500 },
                new Map<String, Object>{ 'minSpend' => 10000, 'maxSpend' => null, 'amount' => 1000 } },
            'maxCashback' => null, 'mechanicSupported' => true, 'mechanicNote' => 'Fixed amount by spend band.',
            'products' => new List<Object>{
                new Map<String, Object>{ 'model' => 'TESTA001', 'group' => 'Ovens', 'category' => 'Oven' },
                new Map<String, Object>{ 'model' => 'NEWMODEL9', 'group' => 'Cooktops', 'category' => 'Cooking' },
                new Map<String, Object>{ 'model' => 'newmodel9', 'group' => 'Cooktops', 'category' => 'Cooking' } },
            'excludedSerialPrefixes' => new List<Object>{ 'a', 'B' }, 'onePerHousehold' => true, 'paymentPromise' => 'within 6 to 8 weeks',
            'summary' => 'Buy two or more appliances.', 'issues' => new List<Object>{
                new Map<String, Object>{ 'clause' => '4', 'severity' => 'high', 'issue' => 'Dates contradict.' } } };
    }

    @isTest static void readsTermsAndAddsItsOwnChecks() {
        Map<String, Object> s = spec();
        s.remove('bankDeadline');
        ClaimHubTestFactory.claude().terms = s;
        Test.startTest();
        Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(ClaimHubTerms.readTerms('Terms text', null));
        Test.stopTest();
        String issues = JSON.serialize(out.get('issues'));
        System.assert(issues.contains('listed more than once'), issues);
        System.assert(issues.contains('No deadline for correcting bank details'), issues);
        System.assertEquals(3, out.get('productCount'));
    }

    @isTest static void movesDeadlinesWithTheNewDates() {
        Map<String, Object> sch = ClaimHubTerms.scheduleFor(spec(), Date.newInstance(2026, 10, 29), Date.newInstance(2026, 12, 31));
        System.assertEquals('2027-01-31T23:59', sch.get('claimsClose'), 'one month after, month end kept');
        System.assertEquals('2027-03-31T23:59', sch.get('serialDeadline'));
        System.assertEquals('2027-04-30T23:59', sch.get('bankDeadline'));
        System.assertEquals('1 month after the promotion closes', sch.get('claimsCloseRule'));
        Map<String, Object> odd = spec();
        odd.put('claimsClose', '2026-09-14T17:00');
        System.assertEquals('2027-01-14T17:00', ClaimHubTerms.scheduleFor(odd, Date.newInstance(2026, 10, 29), Date.newInstance(2026, 12, 31)).get('claimsClose'), 'same number of days');
        Map<String, Object> viaAura = (Map<String, Object>) JSON.deserializeUntyped(ClaimHubTerms.schedule(JSON.serialize(spec()), '2026-10-29', '2026-12-31'));
        System.assertEquals('2027-01-31T23:59', viaAura.get('claimsClose'));
        Boolean refused = false;
        try { ClaimHubTerms.schedule(JSON.serialize(spec()), '2026-12-31', '2026-10-29'); } catch (AuraHandledException ex) { refused = true; }
        System.assert(refused, 'end before start');
        // 23:59 New Zealand summer time is 10:59 UTC
        System.assertEquals(Datetime.newInstanceGmt(2027, 1, 31, 10, 59, 0), ClaimHubTerms.localToInstant('2027-01-31T23:59', 'Pacific/Auckland'));
    }

    @isTest static void buildsTheCampaign() {
        Promotional_Campaign__c compare = ClaimHubTestFactory.campaign('NZ', null);
        Map<String, Object> o = new Map<String, Object>{ 'name' => 'TestBrand Summer (copy)', 'slug' => 'testbrand-summer', 'start' => '2026-10-29', 'end' => '2026-12-31',
            'baseUrl' => 'https://claims.example.com', 'sender' => 'promo@example.com', 'enable' => true, 'compareCampaignId' => compare.Id };
        Id cid = ClaimHubTerms.create(JSON.serialize(spec()), JSON.serialize(o));
        Promotional_Campaign__c c = [SELECT Hub_Slug__c, Hub_Country__c, Hub_Min_Spend__c, Hub_Excluded_Serial_Prefixes__c, Hub_Terms_Issues__c, Hub_Single_Transaction__c,
                                            (SELECT Id FROM Cashback_ranges__r), (SELECT Id FROM Promo_Products__r) FROM Promotional_Campaign__c WHERE Id = :cid];
        System.assertEquals('NZ', c.Hub_Country__c);
        System.assertEquals('A,B', c.Hub_Excluded_Serial_Prefixes__c);
        System.assertEquals(2, c.Cashback_ranges__r.size());
        System.assertEquals(2, c.Promo_Products__r.size(), 'duplicate model listed once');
        System.assert(c.Hub_Terms_Issues__c.contains('NEWMODEL9'), 'product list compared with the past campaign: ' + c.Hub_Terms_Issues__c);
        System.assert(c.Hub_Terms_Issues__c.contains('TESTB002'), 'models on the past campaign but not in the terms');

        for (Map<String, Object> bad : new List<Map<String, Object>>{
                new Map<String, Object>{ 'slug' => 'testbrand-summer' },
                new Map<String, Object>{ 'slug' => 'Bad Slug!' } }) {
            Map<String, Object> o2 = o.clone(); o2.putAll(bad);
            Boolean refused = false;
            try { ClaimHubTerms.create(JSON.serialize(spec()), JSON.serialize(o2)); } catch (AuraHandledException ex) { refused = true; }
            System.assert(refused, JSON.serialize(bad));
        }
        Map<String, Object> unsupported = spec();
        unsupported.put('mechanicSupported', false);
        Map<String, Object> o3 = o.clone(); o3.put('slug', 'another-one');
        Boolean refused = false;
        try { ClaimHubTerms.create(JSON.serialize(unsupported), JSON.serialize(o3)); } catch (AuraHandledException ex) { refused = true; }
        System.assert(refused, 'unsupported mechanic');
    }

    @isTest static void percentTiersAndTemplates() {
        Map<String, Object> s = spec();
        s.put('country', 'AU'); s.put('timezone', 'Australia/Sydney'); s.put('tierBasis', 'percent'); s.put('minSpend', null);
        s.put('tiers', new List<Object>{ new Map<String, Object>{ 'minQty' => 2, 'maxQty' => 2, 'percent' => 15 }, new Map<String, Object>{ 'minQty' => 3, 'percent' => 20 } });
        Id cid = ClaimHubTerms.build(s, new Map<String, Object>{ 'name' => 'Pct', 'slug' => 'pct-test', 'start' => '2026-10-29', 'end' => '2026-12-31' });
        System.assertEquals(2, [SELECT COUNT() FROM Cashback_Range__c WHERE Promotional_Campaign__c = :cid AND Percentage__c != null]);
        System.assertNotEquals(null, ClaimHubTerms.templates());
        System.assertEquals('', ClaimHubTerms.issuesText(new Map<String, Object>()));
    }
}
