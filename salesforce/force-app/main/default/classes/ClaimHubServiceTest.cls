@isTest
private class ClaimHubServiceTest {

    static Promotional_Campaign__c au() { return ClaimHubTestFactory.campaign('AU', null); }

    static Integer refusal(Map<String, Object> req) {
        try { ClaimHubService.lodge(ClaimHubTestFactory.SLUG, req); }
        catch (ClaimHubService.HubException ex) { return ex.status; }
        return 200;
    }

    // ------------------------------------------------------------------ lodging
    @isTest static void lodgesAClaimAndQueuesTheEmail() {
        Promotional_Campaign__c c = au();
        Test.startTest();
        String token = ClaimHubTestFactory.lodge(c.Id, 'sam@example.com', 2, false, 'AU');
        Test.stopTest();
        Entry__c e = ClaimHubTestFactory.entry(token);
        System.assertEquals(ClaimHubService.STATUS_AWAITING, e.Entry_Status__c);
        System.assertEquals(250, e.Cashback_Amount__c, 'two products earn the 2+ tier');
        System.assertEquals(2000, e.Purchase_Price__c);
        System.assertEquals(1, [SELECT COUNT() FROM Claim_Notification__c WHERE Entry__c = :e.Id AND Template_Key__c = 'LODGED']);
        System.assertEquals(2, [SELECT COUNT() FROM Entry_Product__c WHERE Entry__c = :e.Id]);
        Map<String, Object> v = ClaimHubService.view(token);
        System.assertEquals('awaiting', v.get('stage'));
        System.assertEquals('AU', v.get('country'));
        List<Object> out = (List<Object>) v.get('outstanding');
        System.assert(out.contains('invoice') && out.contains('bank'), 'invoice and bank still needed: ' + out);
    }

    @isTest static void percentTiersPayAShareOfSpendUpToTheCap() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('NZ', 15);
        c.Hub_Max_Cashback__c = 250; update c;
        String token = ClaimHubTestFactory.lodge(c.Id, 'pct@example.com', 2, true, 'NZ');
        Entry__c e = ClaimHubTestFactory.entry(token);
        System.assertEquals(250, e.Cashback_Amount__c, '15% of 2,000 is 300, capped at 250');
        System.assertEquals('123140023456600', e.Consumer_Bank_Account_Number__c);
        Map<String, Object> pub = ClaimHubService.publicCampaign(ClaimHubTestFactory.SLUG);
        System.assertEquals('percent', pub.get('tierBasis'));
        System.assertEquals(true, pub.get('needsPrices'));
        System.assertEquals('NZD', pub.get('currency'));
    }

    @isTest static void refusesBadOrIneligibleClaims() {
        Promotional_Campaign__c c = au();
        Map<String, Object> ok = ClaimHubTestFactory.claimRequest(c.Id, 'r@example.com', 1, false, 'AU');

        Map<String, Object> r = ok.clone(); r.remove('acceptedTerms');
        System.assertEquals(400, refusal(r), 'terms not accepted');
        r = ok.clone(); r.remove('firstName');
        System.assertEquals(400, refusal(r), 'missing field');
        r = ok.clone(); r.put('email', 'not-an-email');
        System.assertEquals(400, refusal(r), 'bad email');
        r = ok.clone(); r.put('mobile', '12');
        System.assertEquals(400, refusal(r), 'bad mobile');
        r = ok.clone(); r.put('products', new List<Object>());
        System.assertEquals(400, refusal(r), 'no products');
        r = ok.clone(); r.put('products', new List<Object>{ new Map<String, Object>{ 'promoProductId' => 'not-an-id' } });
        System.assertEquals(400, refusal(r), 'product not in promotion');
        r = ok.clone(); r.put('bank', new Map<String, Object>{ 'name' => 'S Tester', 'bsb' => '12', 'account' => '12345678' });
        System.assertEquals(400, refusal(r), 'bad BSB');
        r = ok.clone(); r.put('bank', new Map<String, Object>{ 'name' => 'S Tester', 'bsb' => '062000', 'account' => '12' });
        System.assertEquals(400, refusal(r), 'bad AU account');
        r = ok.clone(); r.put('bank', new Map<String, Object>{ 'bsb' => '062000', 'account' => '12345678' });
        System.assertEquals(400, refusal(r), 'no account name');
        r = ok.clone(); r.put('products', new List<Object>{ new Map<String, Object>{ 'promoProductId' => ClaimHubTestFactory.products(c.Id)[0].Id, 'serial' => 'A1234567' } });
        System.assertEquals(400, refusal(r), 'second-quality serial');

        c.Maximum_Number_Of_Products__c = 0; update c;
        System.assertEquals(400, refusal(ok), 'more appliances than the promotion allows');
        c.Maximum_Number_Of_Products__c = 10;
        c.Hub_Min_Spend__c = 5000; update c;
        System.assertEquals(400, refusal(ok), 'under the minimum spend');
        c.Hub_Min_Spend__c = null; c.Minimum_Number_Of_Products__c = 3; update c;
        System.assertEquals(400, refusal(ok), 'too few products');
        c.Minimum_Number_Of_Products__c = 1; c.Date_end__c = Datetime.now().addDays(-1); update c;
        System.assertEquals(409, refusal(ok), 'closed');
        c.Hub_Enabled__c = false; update c;
        System.assertEquals(404, refusal(ok), 'switched off');
    }

    @isTest static void oneClaimPerEmailPerPromotion() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.lodge(c.Id, 'twice@example.com', 1, false, 'AU');
        System.assertEquals(409, refusal(ClaimHubTestFactory.claimRequest(c.Id, 'TWICE@example.com', 1, false, 'AU')));
    }

    @isTest static void nzBankAccountsAreChecked() {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign('NZ', null);
        Map<String, Object> r = ClaimHubTestFactory.claimRequest(c.Id, 'nz@example.com', 1, false, 'NZ');
        r.put('bank', new Map<String, Object>{ 'name' => 'S Tester', 'account' => '12-3140-0234567-00' });
        System.assertEquals(400, refusal(r), 'fails the check digit');
        r.put('bank', new Map<String, Object>{ 'name' => 'S Tester', 'account' => '12-3140' });
        System.assertEquals(400, refusal(r), 'too short');
        r.put('bank', new Map<String, Object>{ 'name' => 'S Tester', 'bsb' => '062000', 'account' => '12345678' });
        System.assertEquals(400, refusal(r), 'AU details on an NZ promotion');
    }

    @isTest static void manyClaimsFromOneConnectionAreFlaggedThenRefused() {
        Promotional_Campaign__c c = au();
        String ipHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf('203.0.113.9:' + UserInfo.getOrganizationId())));
        List<Entry__c> earlier = ClaimHubTestFactory.bulkEntries(c.Id, 2, ClaimHubService.STATUS_AWAITING);
        for (Entry__c e : earlier) e.Hub_Client_IP_Hash__c = ipHash;
        update earlier;
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Claims_Per_IP_Daily__c = 3);
        Map<String, Object> r3 = ClaimHubTestFactory.claimRequest(c.Id, 'ip3@example.com', 1, false, 'AU');
        r3.put('_ip', '203.0.113.9');
        Id third = ClaimHubTestFactory.entry((String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r3).get('token')).Id;
        System.assertEquals(1, ClaimHubTestFactory.events(third, 'Needs review: several claims'), 'third claim from one connection is flagged');
        Map<String, Object> r = ClaimHubTestFactory.claimRequest(c.Id, 'ip9@example.com', 1, false, 'AU');
        r.put('_ip', '203.0.113.9');
        System.assertEquals(429, refusal(r));
    }

    @isTest static void sharedBankAccountsAreFlagged() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.lodge(c.Id, 'one@example.com', 1, true, 'AU');
        Entry__c second = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'two@example.com', 1, true, 'AU'));
        System.assertEquals(1, ClaimHubTestFactory.events(second.Id, 'Needs review: bank account'));
    }

    @isTest static void sharedMobilesAreFlaggedWhateverTheFormat() {
        Promotional_Campaign__c c = au();
        Map<String, Object> r1 = ClaimHubTestFactory.claimRequest(c.Id, 'sam.typo@example.com', 1, false, 'AU');
        r1.put('mobile', '0412 345 678');
        ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r1);
        Map<String, Object> r2 = ClaimHubTestFactory.claimRequest(c.Id, 'sam@example.com', 1, false, 'AU');
        r2.put('mobile', '+61 412-345-678');
        Id second = ClaimHubTestFactory.entry((String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r2).get('token')).Id;
        System.assertEquals(1, ClaimHubTestFactory.events(second, 'Needs review: mobile'), 'same mobile, different format, is flagged');
        Id third = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'other@example.com', 1, false, 'AU')).Id;
        System.assertEquals(0, ClaimHubTestFactory.events(third, 'Needs review: mobile'), 'a different mobile is not');
        System.assertEquals(null, ClaimHubService.mobileKey('123'));
    }

    // ------------------------------------------------------------------ serials
    @isTest static void serialsAreCheckedAndSaved() {
        Promotional_Campaign__c c = au();
        String token = ClaimHubTestFactory.lodge(c.Id, 'serial@example.com', 2, false, 'AU');
        Entry__c e = ClaimHubTestFactory.entry(token);
        List<Entry_Product__c> eps = [SELECT Id FROM Entry_Product__c WHERE Entry__c = :e.Id ORDER BY CreatedDate];

        Map<String, Object> v = ClaimHubService.addSerial(token, new Map<String, Object>{ 'productId' => eps[0].Id, 'serial' => '61234567', 'pnc' => '949597455' });
        System.assertEquals(1, ((List<Object>) v.get('outstanding')).size() - 2, 'one serial left plus invoice and bank');
        System.assertEquals('61234567', [SELECT Hub_Serial_Key__c FROM Entry_Product__c WHERE Id = :eps[0].Id].Hub_Serial_Key__c);

        Integer status;
        try { ClaimHubService.addSerial(token, new Map<String, Object>{ 'productId' => eps[1].Id, 'serial' => '61234567' }); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(409, status, 'same serial twice on one claim');
        try { ClaimHubService.addSerial(token, new Map<String, Object>{ 'productId' => eps[1].Id, 'serial' => 'B7654321' }); } catch (ClaimHubService.HubException ex) { status = ex.status; System.assertEquals(e.Id, ex.flagEntry); }
        System.assertEquals(400, status, 'second-quality prefix is refused and flagged');
        try { ClaimHubService.addSerial(token, new Map<String, Object>{ 'productId' => eps[1].Id, 'serial' => '67654321', 'pnc' => '12' }); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(400, status, 'bad PNC');
        try { ClaimHubService.addSerial(token, new Map<String, Object>{ 'productId' => eps[1].Id, 'serial' => 'short' }); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(400, status, 'bad format');
        try { ClaimHubService.addSerial(token, new Map<String, Object>{ 'productId' => e.Id, 'serial' => '67654321' }); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(404, status, 'not a product on this claim');

        // Another claim cannot reuse the serial; the team is told
        String other = ClaimHubTestFactory.lodge(c.Id, 'other@example.com', 1, false, 'AU');
        Id otherProduct = [SELECT Id FROM Entry_Product__c WHERE Entry__r.Access_Token__c = :other LIMIT 1].Id;
        ClaimHubService.HubException dup;
        try { ClaimHubService.addSerial(other, new Map<String, Object>{ 'productId' => otherProduct, 'serial' => '61234567' }); } catch (ClaimHubService.HubException ex) { dup = ex; }
        System.assertEquals(409, dup.status);
        System.assert(dup.flagDetail.contains(e.Name), 'flag names the other claim');
    }

    @isTest static void serialsOnTheClaimFormAreSaved() {
        Promotional_Campaign__c c = au();
        Map<String, Object> r = ClaimHubTestFactory.claimRequest(c.Id, 'withserial@example.com', 2, false, 'AU');
        List<Object> items = (List<Object>) r.get('products');
        ((Map<String, Object>) items[0]).put('serial', '61111111');
        ((Map<String, Object>) items[1]).put('serial', '61111111');
        System.assertEquals(400, refusal(r), 'same serial twice on the form');
        ((Map<String, Object>) items[1]).put('serial', '62222222');
        ((Map<String, Object>) items[1]).put('pnc', '949597455');
        String token = (String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r).get('token');
        System.assertEquals(2, [SELECT COUNT() FROM Entry_Product__c WHERE Entry__r.Access_Token__c = :token AND Hub_Serial_Key__c != null]);
    }

    // ------------------------------------------------------------------ address and store (decisions.md #13)
    static Promotional_Campaign__c collecting(String country, String stores) {
        Promotional_Campaign__c c = ClaimHubTestFactory.campaign(country, null);
        c.Hub_Collect_Address__c = true; c.Hub_Collect_Store__c = true; c.Hub_Stores__c = stores;
        update c;
        return c;
    }

    static Map<String, Object> withAddress(Map<String, Object> r, String state) {
        r.put('address', new Map<String, Object>{ 'unit' => '4', 'streetNumber' => '12', 'street' => 'Example  Street', 'suburb' => 'Testville', 'postcode' => '2000', 'state' => state });
        return r;
    }

    @isTest static void addressAndStoreGoWhereTheC4CFeedReadsThem() {
        Promotional_Campaign__c c = collecting('AU', 'Harvey Norman\nThe Good Guys\nharvey norman\nOther');
        Map<String, Object> pub = ClaimHubService.publicCampaign(ClaimHubTestFactory.SLUG);
        System.assertEquals(true, pub.get('collectAddress'));
        System.assertEquals(new List<String>{ 'Harvey Norman', 'The Good Guys', 'Other' }, pub.get('stores'), 'duplicates dropped, Other last');
        System.assertEquals(8, ((List<Object>) pub.get('regions')).size());

        Map<String, Object> r = withAddress(ClaimHubTestFactory.claimRequest(c.Id, 'addr@example.com', 1, false, 'AU'), 'NSW');
        r.put('store', new Map<String, Object>{ 'retailer' => 'the good guys', 'suburb' => 'Testville', 'state' => 'NSW' });
        String token = (String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r).get('token');

        Entry__c e = [SELECT Consumer_Unit_No__c, Consumer_Street_Number__c, Consumer_Street_Stamp__c, Consumer_Suburb__c, Consumer_PostalCode_Stamp__c,
                             Consumer_State_Stamp__c, Consumer_Country_Stamp__c, Consumer_Contact_Number__c FROM Entry__c WHERE Access_Token__c = :token];
        System.assertEquals('4', e.Consumer_Unit_No__c);
        System.assertEquals('12', e.Consumer_Street_Number__c);
        System.assertEquals('Example Street', e.Consumer_Street_Stamp__c, 'spaces tidied');
        System.assertEquals('Testville', e.Consumer_Suburb__c);
        System.assertEquals('2000', e.Consumer_PostalCode_Stamp__c);
        System.assertEquals('NSW', e.Consumer_State_Stamp__c);
        System.assertEquals('Australia', e.Consumer_Country_Stamp__c);
        System.assertEquals(null, e.Consumer_Contact_Number__c, 'AU claims keep the mobile in the mobile stamp');
        Lead l = [SELECT Unit_No__c, Street_Number__c, Street__c, Suburb__c, Postal_Code__c, State_Territory__c, Country__c FROM Lead WHERE Id IN (SELECT Customer__c FROM Entry__c WHERE Access_Token__c = :token)];
        System.assertEquals('NSW', l.State_Territory__c, 'AU state on the Lead where the old AU forms put it');
        System.assertEquals('12', l.Street_Number__c);
        System.assertEquals('2000', l.Postal_Code__c);
        Entry_Receipt__c rec = [SELECT Retailer__c, Retailer_Suburb__c, Retailer_State__c, Store_Name__c, Hub_Has_File__c FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :token];
        System.assertEquals('The Good Guys', rec.Retailer__c, 'spelt as on the list');
        System.assertEquals('Testville', rec.Retailer_Suburb__c);
        System.assertEquals('NSW', rec.Retailer_State__c);
        System.assertEquals(null, rec.Store_Name__c);
        System.assert(!rec.Hub_Has_File__c);
        Map<String, Object> v = ClaimHubService.view(token);
        System.assertEquals('The Good Guys Testville', ((Map<String, Object>) ((List<Object>) v.get('receipts'))[0]).get('store'));
        System.assert(((List<Object>) v.get('outstanding')).contains('invoice'), 'the store alone is not an invoice');

        // A later invoice upload fills the same receipt rather than adding a second one
        ClaimHubTestFactory.claude();
        Test.startTest();
        ClaimHubService.addReceipt(token, ClaimHubTestFactory.receiptRequest());
        Test.stopTest();
        List<Entry_Receipt__c> recs = [SELECT Retailer__c, Hub_Has_File__c FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :token];
        System.assertEquals(1, recs.size());
        System.assertEquals('The Good Guys', recs[0].Retailer__c);
        System.assert(recs[0].Hub_Has_File__c);
    }

    @isTest static void nzClaimsTakeARegionAndTheContactNumber() {
        Promotional_Campaign__c c = collecting('NZ', null);
        Map<String, Object> pub = ClaimHubService.publicCampaign(ClaimHubTestFactory.SLUG);
        System.assertEquals(new List<String>{ 'Harvey Norman', 'Other' }, pub.get('stores'), 'falls back to the eligible retailers');
        System.assertEquals(16, ((List<Object>) pub.get('regions')).size());

        Map<String, Object> r = withAddress(ClaimHubTestFactory.claimRequest(c.Id, 'nzaddr@example.com', 1, false, 'NZ'), 'NSW');
        r.put('store', new Map<String, Object>{ 'retailer' => 'Other', 'name' => 'Example Appliances', 'suburb' => 'Testtown' });
        System.assertEquals(400, refusal(r), 'an AU state on an NZ promotion');
        withAddress(r, 'Hawke\'s Bay');
        String token = (String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r).get('token');

        Entry__c e = [SELECT Consumer_State_Stamp__c, Consumer_Country_Stamp__c, Consumer_Contact_Number__c, Consumer_Mobile_Stamp__c FROM Entry__c WHERE Access_Token__c = :token];
        System.assertEquals('Hawke\'s Bay', e.Consumer_State_Stamp__c);
        System.assertEquals('New Zealand', e.Consumer_Country_Stamp__c);
        System.assertEquals(e.Consumer_Mobile_Stamp__c, e.Consumer_Contact_Number__c, 'the NZ number C4C sends');
        Lead l = [SELECT Town_City__c, State_Territory__c, Country__c FROM Lead WHERE Id IN (SELECT Customer__c FROM Entry__c WHERE Access_Token__c = :token)];
        System.assertEquals('Hawke\'s Bay', l.Town_City__c, 'NZ region on the Lead where the old NZ forms put it');
        System.assertEquals(null, l.State_Territory__c);
        System.assertEquals('New Zealand', l.Country__c);
        Entry_Receipt__c rec = [SELECT Retailer__c, Store_Name__c, Retailer_Suburb__c, Retailer_State__c FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :token];
        System.assertEquals('Other', rec.Retailer__c);
        System.assertEquals('Example Appliances', rec.Store_Name__c);
        System.assertEquals('Testtown', rec.Retailer_Suburb__c);
        System.assertEquals(null, rec.Retailer_State__c, 'NZ stores have no state, as on the old NZ forms');
    }

    @isTest static void withNoStoreListTheClaimantTypesTheStore() {
        Promotional_Campaign__c c = collecting('AU', null);
        c.Hub_Retailers__c = null; update c;
        System.assertEquals(0, ((List<Object>) ClaimHubService.publicCampaign(ClaimHubTestFactory.SLUG).get('stores')).size());
        Map<String, Object> r = withAddress(ClaimHubTestFactory.claimRequest(c.Id, 'typed@example.com', 1, false, 'AU'), 'VIC');
        r.put('store', new Map<String, Object>{ 'suburb' => 'Testville', 'state' => 'VIC' });
        System.assertEquals(400, refusal(r), 'no store name');
        r.put('store', new Map<String, Object>{ 'name' => 'Example Appliances', 'suburb' => 'Testville', 'state' => 'VIC' });
        r.put('invoice', new Map<String, Object>{ 'number' => 'INV-1', 'store' => 'Ignored Store' });
        String token = (String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r).get('token');
        Entry_Receipt__c rec = [SELECT Retailer__c, Store_Name__c, Receipt_Number__c FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :token];
        System.assertEquals('Other', rec.Retailer__c);
        System.assertEquals('Example Appliances', rec.Store_Name__c, 'the store the claimant chose wins over the invoice field');
        System.assertEquals('INV-1', rec.Receipt_Number__c, 'invoice details share the one receipt');
    }

    static Map<String, Object> goodCollectingRequest(Promotional_Campaign__c c) {
        Map<String, Object> ok = withAddress(ClaimHubTestFactory.claimRequest(c.Id, 'bad@example.com', 1, false, 'AU'), 'QLD');
        ok.put('store', new Map<String, Object>{ 'retailer' => 'Harvey Norman', 'suburb' => 'Testville', 'state' => 'QLD' });
        return ok;
    }

    @isTest static void refusesAMissingOrWrongAddress() {
        Map<String, Object> ok = goodCollectingRequest(collecting('AU', 'Harvey Norman'));
        Map<String, Object> r = ok.clone(); r.remove('address');
        System.assertEquals(400, refusal(r), 'no address');
        for (String k : new List<String>{ 'streetNumber', 'street', 'suburb', 'postcode', 'state' }) {
            r = ok.clone();
            Map<String, Object> a = ((Map<String, Object>) ok.get('address')).clone(); a.remove(k); r.put('address', a);
            System.assertEquals(400, refusal(r), 'missing ' + k);
        }
        Test.startTest(); // fresh limits: each refusal runs the earlier checks again
        r = ok.clone(); Map<String, Object> a = ((Map<String, Object>) ok.get('address')).clone(); a.put('postcode', '20000'); r.put('address', a);
        System.assertEquals(400, refusal(r), 'postcode too long');
        a = a.clone(); a.put('postcode', 'ABCD'); r.put('address', a);
        System.assertEquals(400, refusal(r), 'postcode not digits');
        a = ((Map<String, Object>) ok.get('address')).clone(); a.put('state', 'Queensland'); r.put('address', a);
        System.assertEquals(400, refusal(r), 'state not from the list');
        a = ((Map<String, Object>) ok.get('address')).clone(); a.put('street', 'x'.repeat(121)); r.put('address', a);
        System.assertEquals(400, refusal(r), 'street too long');
        System.assertEquals(0, [SELECT COUNT() FROM Entry__c], 'nothing saved by a refusal');
        System.assertEquals(200, refusal(ok));
        Test.stopTest();
    }

    @isTest static void refusesAMissingOrWrongStore() {
        Map<String, Object> ok = goodCollectingRequest(collecting('AU', 'Harvey Norman'));
        Map<String, Object> r = ok.clone(); r.remove('store');
        System.assertEquals(400, refusal(r), 'no store');
        r = ok.clone(); r.put('store', new Map<String, Object>{ 'retailer' => 'Some Other Shop', 'suburb' => 'Testville', 'state' => 'QLD' });
        System.assertEquals(400, refusal(r), 'store not on the list');
        r = ok.clone(); r.put('store', new Map<String, Object>{ 'retailer' => 'Other', 'suburb' => 'Testville', 'state' => 'QLD' });
        System.assertEquals(400, refusal(r), 'Other without a name');
        Test.startTest(); // fresh limits
        r = ok.clone(); r.put('store', new Map<String, Object>{ 'retailer' => 'Harvey Norman', 'state' => 'QLD' });
        System.assertEquals(400, refusal(r), 'no store suburb');
        r = ok.clone(); r.put('store', new Map<String, Object>{ 'retailer' => 'Harvey Norman', 'suburb' => 'Testville' });
        System.assertEquals(400, refusal(r), 'no store state in AU');
        r = ok.clone(); r.put('store', new Map<String, Object>{ 'retailer' => 'Harvey Norman', 'suburb' => 'Testville', 'state' => 'XX' });
        System.assertEquals(400, refusal(r), 'store state not from the list');
        System.assertEquals(0, [SELECT COUNT() FROM Entry__c], 'nothing saved by a refusal');
        Test.stopTest();
    }

    @isTest static void campaignsThatDontAskIgnoreAddressAndStore() {
        Promotional_Campaign__c c = au();
        Map<String, Object> pub = ClaimHubService.publicCampaign(ClaimHubTestFactory.SLUG);
        System.assertEquals(false, pub.get('collectAddress'));
        System.assertEquals(null, pub.get('stores'));
        Map<String, Object> r = withAddress(ClaimHubTestFactory.claimRequest(c.Id, 'plain@example.com', 1, false, 'AU'), 'Nowhere');
        String token = (String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r).get('token');
        System.assertEquals(null, [SELECT Consumer_State_Stamp__c FROM Entry__c WHERE Access_Token__c = :token].Consumer_State_Stamp__c);
        System.assertEquals(0, [SELECT COUNT() FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :token]);
    }

    // ------------------------------------------------------------------ invoice
    @isTest static void aCompleteClaimMovesToTheTeam() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.claude();
        Map<String, Object> r = ClaimHubTestFactory.claimRequest(c.Id, 'sam.tester@example.com', 2, true, 'AU');
        List<Object> items = (List<Object>) r.get('products');
        ((Map<String, Object>) items[0]).put('serial', '61111111');
        ((Map<String, Object>) items[1]).put('serial', '62222222');
        String token = (String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r).get('token');
        Map<String, Object> req = ClaimHubTestFactory.receiptRequest();
        String folder = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(token))).left(24);
        req.put('fileKey', 'invoices/' + folder + '/invoice-x1.jpg');
        Test.startTest();
        Map<String, Object> v = ClaimHubService.addReceipt(token, req);
        Test.stopTest();
        System.assertEquals('review', v.get('stage'), 'all items in: ' + v.get('outstanding'));
        Entry_Receipt__c rec = [SELECT OCR_Status__c, Hub_Has_File__c, Hub_File_Key__c, Hub_Invoice_Key__c, Receipt_Number__c FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :token];
        System.assertEquals('Passed', rec.OCR_Status__c);
        System.assert(rec.Hub_Has_File__c);
        System.assertEquals('invoices/' + folder + '/invoice-x1.jpg', rec.Hub_File_Key__c);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :ClaimHubTestFactory.entry(token).Id], 'file kept outside Salesforce');
        System.assertEquals(1, [SELECT COUNT() FROM Claim_Notification__c WHERE Entry__r.Access_Token__c = :token AND Template_Key__c = 'COMPLETE']);

        // Once the team has decided, the claimant can no longer change it
        update new Entry__c(Id = ClaimHubTestFactory.entry(token).Id, Entry_Status__c = 'Valid');
        Integer status;
        try { ClaimHubService.addReceipt(token, ClaimHubTestFactory.receiptRequest()); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(409, status);
    }

    @isTest static void invoiceProblemsAreListedForTheTeam() {
        Promotional_Campaign__c c = au();
        c.Hub_Min_Spend__c = 1500; update c;
        String token = ClaimHubTestFactory.lodge(c.Id, 'sam@example.com', 2, false, 'AU');
        Entry__c e = ClaimHubService.load(ClaimHubTestFactory.entry(token).Id);

        System.assertEquals(0, ClaimHubInvoice.invoiceChecks(e, ClaimHubTestFactory.goodInvoice()).size());
        Map<String, Object> bad = ClaimHubTestFactory.goodInvoice();
        bad.put('retailer', 'Other Store'); bad.put('store', 'Other Store');
        bad.put('customerName', 'Someone Else');
        bad.put('balanceDue', 500);
        bad.put('invoiceDate', String.valueOf(Date.today().addDays(-90)));
        bad.put('isInvoice', false);
        bad.put('lines', new List<Object>{ new Map<String, Object>{ 'model' => ClaimHubTestFactory.MODELS[0], 'price' => 700 },
                                           new Map<String, Object>{ 'model' => ClaimHubTestFactory.MODELS[1], 'price' => 700 } });
        String all = String.join(ClaimHubInvoice.invoiceChecks(e, bad), ' | ');
        for (String expected : new List<String>{ 'not look like an invoice', 'outside the promotion dates', 'is not Harvey Norman', 'does not match', 'balance owing', 'under the', 'differs from invoice' }) {
            System.assert(all.contains(expected), 'expected "' + expected + '" in: ' + all);
        }
        bad.put('lines', new List<Object>());
        bad.put('customerName', null); bad.put('invoiceDate', 'garbage');
        all = String.join(ClaimHubInvoice.invoiceChecks(e, bad), ' | ');
        System.assert(all.contains('not found on invoice') && all.contains('not readable'), all);
        System.assertEquals(1, ClaimHubInvoice.invoiceChecks(e, new Map<String, Object>{ 'error' => 'x' }).size());
    }

    @isTest static void theSameInvoiceOnTwoClaimsIsFlagged() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.claude();
        Entry__c first = ClaimHubTestFactory.entry(ClaimHubTestFactory.lodge(c.Id, 'a@example.com', 2, false, 'AU'));
        insert new Entry_Receipt__c(Entry__c = first.Id, Hub_Invoice_Key__c = ClaimHubInvoice.invoiceKey(ClaimHubTestFactory.goodInvoice()), Hub_Has_File__c = true);
        String second = ClaimHubTestFactory.lodge(c.Id, 'b@example.com', 2, false, 'AU');
        Test.startTest();
        ClaimHubService.addReceipt(second, ClaimHubTestFactory.receiptRequest());
        Test.stopTest();
        Entry_Receipt__c r = [SELECT Id, OCR_Status__c FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :second];
        System.assert(r.OCR_Status__c.contains('already on claim ' + first.Name), r.OCR_Status__c);
        System.assertEquals(1, ClaimHubTestFactory.events(ClaimHubTestFactory.entry(second).Id, 'Needs review: invoice'));
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :r.Id], 'no file key, so kept in Salesforce');
    }

    @isTest static void unreadableInvoicesGoToTheTeamAndUploadsAreLimited() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.Claude fake = ClaimHubTestFactory.claude();
        fake.status = 529;
        String token = ClaimHubTestFactory.lodge(c.Id, 'a@example.com', 1, false, 'AU');
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Upload_Daily_Limit__c = 1);
        Test.startTest();
        ClaimHubService.addReceipt(token, ClaimHubTestFactory.receiptRequest());
        Integer status;
        try { ClaimHubService.addReceipt(token, ClaimHubTestFactory.receiptRequest()); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        Test.stopTest();
        System.assertEquals(429, status);
        System.assertEquals('Not read', [SELECT OCR_Status__c FROM Entry_Receipt__c WHERE Entry__r.Access_Token__c = :token].OCR_Status__c);
        Map<String, Object> big = ClaimHubTestFactory.receiptRequest();
        big.put('base64', 'A'.repeat(2100001));
        try { ClaimHubService.addReceipt(token, big); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(413, status);
    }

    // ------------------------------------------------------------------ plate, link, bank
    @isTest static void readsARatingPlate() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.claude();
        String token = ClaimHubTestFactory.lodge(c.Id, 'plate@example.com', 1, false, 'AU');
        Test.startTest();
        Map<String, Object> out = ClaimHubService.readPlate(token, ClaimHubTestFactory.receiptRequest());
        Test.stopTest();
        System.assertEquals('61234567', out.get('serial'));
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Plate_Daily_Limit__c = 1);
        Integer status;
        try { ClaimHubService.readPlate(token, ClaimHubTestFactory.receiptRequest()); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(429, status);
    }

    @isTest static void sendsAFreshLinkWithoutRevealingWhoHasClaimed() {
        Promotional_Campaign__c c = au();
        String token = ClaimHubTestFactory.lodge(c.Id, 'link@example.com', 1, false, 'AU');
        System.assertEquals(true, ClaimHubService.resendLink(new Map<String, Object>{ 'slug' => ClaimHubTestFactory.SLUG, 'email' => 'nobody@example.com' }).get('sent'));
        System.assertEquals(true, ClaimHubService.resendLink(new Map<String, Object>{ 'slug' => ClaimHubTestFactory.SLUG, 'email' => 'LINK@example.com' }).get('sent'));
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Link_Daily_Limit__c = 1);
        ClaimHubService.resendLink(new Map<String, Object>{ 'slug' => ClaimHubTestFactory.SLUG, 'email' => 'link@example.com' });
        System.assertEquals(1, [SELECT COUNT() FROM Claim_Notification__c WHERE Entry__r.Consumer_Email_Stamp__c = 'link@example.com' AND Template_Key__c = 'LINK'], 'second request within the limit sends nothing');
    }

    @isTest static void bankChangesNeedTheEmailedCode() {
        Promotional_Campaign__c c = au();
        String token = ClaimHubTestFactory.lodge(c.Id, 'bank@example.com', 1, true, 'AU');
        Entry__c e = ClaimHubTestFactory.entry(token);
        Map<String, Object> change = new Map<String, Object>{ 'code' => '000000', 'name' => 'S Tester', 'bsb' => '063000', 'account' => '87654321' };

        Integer status;
        try { ClaimHubService.changeBank(token, change); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(401, status, 'no code issued yet');

        System.assertEquals(true, ClaimHubService.requestCode(token).get('sent'));
        Claim_OTP__c otp = [SELECT Id, Code_Hash__c FROM Claim_OTP__c WHERE Entry__c = :e.Id];
        try { ClaimHubService.changeBank(token, change); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(401, status, 'wrong code');
        // (the attempt is counted by ClaimHubApi after its rollback: see ClaimHubApiTest)

        // The code itself is only ever emailed; give the stored code a known value for the test
        String code = '123456';
        update new Claim_OTP__c(Id = otp.Id, Code_Hash__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(e.Id + ':' + code))));
        change.put('code', code);
        update new Entry__c(Id = e.Id, EFT_Status__c = 'Queued EFT processing');
        try { ClaimHubService.changeBank(token, change); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(409, status, 'no change while a payment is being made');
        update new Entry__c(Id = e.Id, EFT_Status__c = 'EFT Failed');
        Map<String, Object> v = ClaimHubService.changeBank(token, change);
        System.assertEquals('321', ((Map<String, Object>) v.get('bank')).get('last3'));
        System.assertEquals('EFT Updated', ClaimHubTestFactory.entry(token).EFT_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Claim_Notification__c WHERE Entry__c = :e.Id AND Template_Key__c = 'BANK_CHANGED']);
        try { ClaimHubService.changeBank(token, change); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(401, status, 'a code works once');
    }

    @isTest static void tooManyWrongCodesLockTheCode() {
        Promotional_Campaign__c c = au();
        String token = ClaimHubTestFactory.lodge(c.Id, 'lock@example.com', 1, true, 'AU');
        ClaimHubService.requestCode(token);
        update new Claim_OTP__c(Id = [SELECT Id FROM Claim_OTP__c LIMIT 1].Id, Attempts__c = 5);
        Integer status;
        try { ClaimHubService.changeBank(token, new Map<String, Object>{ 'code' => '1' }); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(429, status);
    }

    // ------------------------------------------------------------------ assistant
    static List<Object> question() {
        return new List<Object>{ new Map<String, Object>{ 'role' => 'assistant', 'content' => 'Hi' },
                                 new Map<String, Object>{ 'role' => 'user', 'content' => 'When do I get paid?' } };
    }

    @isTest static void theAssistantAnswersFromTheTerms() {
        au();
        ClaimHubTestFactory.claude();
        Test.startTest();
        Map<String, Object> a = ClaimHubAssistant.chatForCampaign(ClaimHubTestFactory.SLUG, new Map<String, Object>{ 'messages' => question() });
        Test.stopTest();
        System.assertEquals(false, a.get('handover'));
        System.assert(String.valueOf(a.get('reply')).contains('6 to 8 weeks'));
        Integer status;
        try { ClaimHubAssistant.chatForCampaign(ClaimHubTestFactory.SLUG, new Map<String, Object>{ 'messages' => new List<Object>() }); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(400, status);
    }

    @isTest static void theAssistantHandsOverToTheTeam() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.claude().chatReply = 'I will pass this on.\nHANDOVER: claimant disputes the amount';
        String token = ClaimHubTestFactory.lodge(c.Id, 'chat@example.com', 1, false, 'AU');
        Test.startTest();
        Map<String, Object> b = ClaimHubAssistant.chatForClaim(token, new Map<String, Object>{ 'messages' => question() });
        Test.stopTest();
        System.assertEquals(true, b.get('handover'));
        System.assertEquals('I will pass this on.', b.get('reply'));
        System.assertEquals(1, ClaimHubTestFactory.events(ClaimHubTestFactory.entry(token).Id, 'Needs review: assistant handover'));
        ClaimHubSettings.current = new Claim_Hub_Settings__c(Chat_Daily_Limit__c = 1);
        System.assert(String.valueOf(ClaimHubAssistant.chatForClaim(token, new Map<String, Object>{ 'messages' => question() }).get('reply')).contains('passed your claim to the team'), 'over the limit: no call');
    }

    @isTest static void theAssistantFallsBackWhenClaudeIsDown() {
        Promotional_Campaign__c c = au();
        ClaimHubTestFactory.claude().status = 500;
        String token = ClaimHubTestFactory.lodge(c.Id, 'down@example.com', 1, false, 'AU');
        Test.startTest();
        Map<String, Object> d = ClaimHubAssistant.chatForClaim(token, new Map<String, Object>{ 'messages' => question() });
        Test.stopTest();
        System.assert(String.valueOf(d.get('reply')).startsWith('Sorry'));
    }

    // ------------------------------------------------------------------ small helpers
    @isTest static void helpers() {
        System.assertEquals('NZ$1,234.50', ClaimHubService.money(1234.5, 'NZ'));
        System.assertEquals('$100', ClaimHubService.money(100, 'AU'));
        System.assertEquals('', ClaimHubService.money(null, 'AU'));
        System.assertEquals('AU', ClaimHubService.country(null));
        System.assertEquals('678', ClaimHubService.last3('0412 345 678'));
        System.assertEquals(null, ClaimHubService.last3(''));
        System.assertEquals('s•••@example.com', ClaimHubService.maskEmail('sam@example.com'));
        System.assertEquals(4299.00, ClaimHubService.price('$4,299.00'));
        System.assertEquals(null, ClaimHubService.price('abc'));
        System.assertEquals(null, ClaimHubService.price('0'));
        System.assertEquals('HARVEYN0RMAN:HN100200', ClaimHubInvoice.invoiceKey(ClaimHubTestFactory.goodInvoice()));
        System.assertEquals(null, ClaimHubInvoice.invoiceKey(new Map<String, Object>{ 'invoiceNumber' => '1' }));
        Map<String, String> stages = new Map<String, String>{ 'Invalid' => 'not_approved', 'Valid' => 'approved', 'Submitted' => 'review', 'Submitted - Awaiting Details' => 'awaiting' };
        for (String s : stages.keySet()) System.assertEquals(stages.get(s), ClaimHubService.stage(new Entry__c(Entry_Status__c = s)));
        System.assertEquals('paid', ClaimHubService.stage(new Entry__c(Entry_Status__c = 'Valid', EFT_Status__c = 'Fulfilled')));
        System.assertEquals('payment_failed', ClaimHubService.stage(new Entry__c(Entry_Status__c = 'Valid', EFT_Status__c = 'EFT Failed')));
        Integer status;
        try { ClaimHubService.view('x'.repeat(43)); } catch (ClaimHubService.HubException ex) { status = ex.status; }
        System.assertEquals(404, status, 'unknown link');
    }
}
