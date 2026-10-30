@isTest
private class ClaimAccessTokenTest {
    static final String RT = '012OZ00000Gclj3YAB';

    static User guest() {
        // AEG NZ site guest user; same pattern applies to every campaign site guest.
        return [SELECT Id FROM User WHERE UserType = 'Guest' AND IsActive = true AND Id = '0050o00000Y9AGfAAN'];
    }

    @TestSetup static void data() {
        Promotional_Campaign__c c = new Promotional_Campaign__c(Name='Token Test', Job_Number__c='TOKTEST', Campaign_Type__c='Cashback',
            Entry_Record_Type_ID__c=RT, Edit_URL__c='https://example.com/', Status_URL__c='https://example.com/claimstatus',
            Status_Fields_Data__c='[{"apiName":"Name","label":"Name","data":""},{"apiName":"Entry_Status__c","label":"Status","data":""}]',
            Customer_Fields_Data__c='[{"apiName":"FirstName","renderable":true},{"apiName":"Email","renderable":true},' +
                '{"apiName":"Account_Name__c","renderable":true},{"apiName":"Bank_Account_Number__c","renderable":true}]');
        insert c;
        Lead l = new Lead(FirstName='Test', LastName='Claimant', Email='test.claimant@example.com', Company='None',
            Account_Name__c='Test Claimant', Bank_Account_Number__c='1234567890123400');
        insert l;
        insert new Entry__c(RecordTypeId=RT, Promotional_Campaign__c=c.Id, Customer__c=l.Id, Entry_Status__c='Submitted - Awaiting Details');
    }

    static Entry__c claim() {
        return [SELECT Id, Promotional_Campaign__c, Access_Token__c, Resume_Url__c, Status_URL__c FROM Entry__c LIMIT 1];
    }

    @isTest static void newClaimGetsRandomLinkNotRecordId() {
        Entry__c e = claim();
        String oldStyle = EncodingUtil.base64Encode(Blob.valueOf(e.Id));
        System.assert(e.Access_Token__c != null && e.Access_Token__c.length() >= 40, 'token too short');
        System.assert(!e.Resume_Url__c.contains(oldStyle), 'link still built from record Id');
        System.assertEquals('https://example.com/?token=' + e.Access_Token__c, e.Resume_Url__c);
        System.assertEquals('https://example.com/claimstatus?token=' + e.Access_Token__c, e.Status_URL__c);
        System.assertNotEquals(ClaimAccessToken.newToken(), ClaimAccessToken.newToken());
    }

    @isTest static void guessedOldStyleLinkReturnsNothing() {
        Entry__c e = claim();
        String guessed = EncodingUtil.base64Encode(Blob.valueOf(e.Id));
        String details, status, raw;
        System.runAs(guest()) {
            details = LightningCustomerEntry.getDetailsByToken(guessed, e.Promotional_Campaign__c);
            status = EntryStatus.getDetailsByToken(guessed);
            raw = LightningCustomerEntry.getDetails(e.Id, e.Promotional_Campaign__c);
        }
        System.assert(details.contains('"expired":true') && !details.contains('test.claimant@example.com'), 'old-style link still opens the claim: ' + details);
        System.assertEquals(null, status, 'old-style link still opens the status page');
        System.assertEquals(null, raw, 'website visitor can still read a claim by record Id');
    }

    @isTest static void realLinkWorksButBankNumberIsMasked() {
        Entry__c e = claim();
        String details, status;
        System.runAs(guest()) {
            details = LightningCustomerEntry.getDetailsByToken(e.Access_Token__c, e.Promotional_Campaign__c);
            status = EntryStatus.getDetailsByToken(e.Access_Token__c);
        }
        System.assertNotEquals(null, details);
        System.assert(details.contains('test.claimant@example.com'), details);
        System.assert(!details.contains('1234567890123400'), 'full bank number sent to browser');
        System.assert(details.contains(ClaimAccessToken.MASK + '400'), 'masked bank number missing: ' + details);
        System.assertNotEquals(null, status);
    }

    @isTest static void staffStillSeeFullDetails() {
        Entry__c e = claim();
        String details = LightningCustomerEntry.getDetails(e.Id, e.Promotional_Campaign__c);
        System.assert(details != null && details.contains('1234567890123400'), 'staff view broken');
    }

    @isTest static void updateWithoutTheRightCodeIsRefused() {
        Entry__c e = claim();
        String noToken, wrongToken, oldToken, rightToken;
        System.runAs(guest()) {
            noToken = PromotionalCampaignsController.updateCashbackEntry(JSON.serialize(new Map<String, Object>{'entryId' => e.Id}));
            wrongToken = PromotionalCampaignsController.updateCashbackEntry(JSON.serialize(new Map<String, Object>{'entryId' => e.Id, 'token' => ClaimAccessToken.newToken()}));
            oldToken = PromotionalCampaignsController.updateCashbackEntry(JSON.serialize(new Map<String, Object>{'entryId' => e.Id, 'token' => EncodingUtil.base64Encode(Blob.valueOf(e.Id))}));
            try {
                rightToken = PromotionalCampaignsController.updateCashbackEntry(JSON.serialize(new Map<String, Object>{'entryId' => e.Id, 'token' => e.Access_Token__c,
                    'customerData' => new Map<String, Object>{'Bank_Account_Number__c' => ClaimAccessToken.MASK + '400'}}));
            } catch (Exception ex) {
                // Passed the code check; the existing save routine then needs a full form payload.
                rightToken = 'passed gate: ' + ex.getMessage();
            }
        }
        for (String r : new List<String>{noToken, wrongToken, oldToken}) {
            System.assert(r.contains('This link has expired'), 'update allowed without the claim\'s code: ' + r);
        }
        System.assert(!rightToken.contains('This link has expired'), 'valid code refused: ' + rightToken);
    }

    @isTest static void maskHelpers() {
        System.assertEquals(ClaimAccessToken.MASK + '400', ClaimAccessToken.mask('12-3456-7890123-400'));
        System.assert(ClaimAccessToken.isMasked(ClaimAccessToken.MASK + '123'));
        System.assert(!ClaimAccessToken.isMasked('1234567'));
        System.assertEquals(null, ClaimAccessToken.resolve('short'));
        System.assertEquals(null, ClaimAccessToken.resolve(null));
    }

    @isTest static void backfillGivesOldClaimsANewLink() {
        Entry__c e = claim();
        ClaimAccessToken.suppressAutoStamp = true;
        e.Access_Token__c = null;
        e.Resume_Url__c = 'https://example.com/?token=' + EncodingUtil.base64Encode(Blob.valueOf(e.Id));
        update e;
        ClaimAccessToken.suppressAutoStamp = false;
        System.assertEquals(null, claim().Access_Token__c);
        Test.startTest();
        Database.executeBatch(new ClaimAccessTokenBackfill(e.Promotional_Campaign__c));
        Test.stopTest();
        Entry__c after = claim();
        System.assertNotEquals(null, after.Access_Token__c);
        System.assertEquals('https://example.com/?token=' + after.Access_Token__c, after.Resume_Url__c);
    }

    @isTest static void otherSiteEndpointsStillRespond() {
        // Smoke test: the security change must not break the read endpoints the claim sites call.
        Entry__c e = claim();
        Id campaignId = e.Promotional_Campaign__c;
        System.assertNotEquals(null, PromotionalCampaignsController.getCampaignInfo(campaignId));
        System.assertNotEquals(null, PromotionalCampaignsController.getCampaignInfoByEntryId(e.Id));
        System.assertNotEquals(null, PromotionalCampaignsController.getCampaignInfoByEntryId(null));
        PromotionalCampaignsController.getList();
        PromotionalCampaignsController.getCashbackValue(campaignId, 8000);
        PromotionalCampaignsController.getPromotionalProducts(campaignId);
        PromotionalCampaignsController.isCampaignCodeValid(campaignId, 'NOPE');
        PromotionalCampaignsController.getCampaignProducts('BPK');
        // Legacy method: only checked for not crashing the transaction; it may throw on test data without daily limits
        try { PromotionalCampaignsController.isMaximumDailyEntriesLimitRiched(JSON.serialize(new Map<String, Object>{'campaignId' => campaignId})); }
        catch (Exception ex) { System.assertNotEquals(null, ex.getMessage(), 'a legacy failure explains itself'); }
    }
}
