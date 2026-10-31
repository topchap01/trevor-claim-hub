@isTest
private class ClaimHubBankTest {

    // Made-up account numbers that pass their bank's check digit (no claimant attached).
    static final String NZ_GOOD = '12-3140-0234566-00';     // algorithm A
    static final String NZ_TYPO = '12-3140-0234567-00';     // one digit off
    static final String NZ_UNLISTED = '99-3140-0234566-00'; // no such bank code

    static Hub_Bank_Branch__c row(String key, String bankName, String branchName, String payments) {
        return new Hub_Bank_Branch__c(Name = key, Key__c = key, Country__c = key.left(2), Bank_Code__c = key.substring(3, key.indexOf('-', 3)),
            Bank_Name__c = bankName, Branch_Name__c = branchName, Payments__c = payments, Load__c = 'test');
    }

    static void loadRegisters() {
        insert new List<Hub_Bank_Branch__c>{
            row('NZ-12-3140', 'ASB Bank', 'Test Branch', null),
            row('AU-062-000', 'Commonwealth Bank of Australia', 'Test Branch', 'PEH'),
            row('AU-062-001', 'Commonwealth Bank of Australia', 'Paper Only Branch', 'P'),
            row('AU-062-002', 'Commonwealth Bank of Australia', 'Closed', 'PEH') };
        ClaimHubBank.forget();
    }

    static Id lodge(String country, Map<String, Object> bank, String email) {
        Map<String, Object> r = ClaimHubTestFactory.claimRequest([SELECT Id FROM Promotional_Campaign__c LIMIT 1].Id, email, 1, false, country);
        r.put('bank', bank);
        return ClaimHubTestFactory.entry((String) ClaimHubService.lodge(ClaimHubTestFactory.SLUG, r).get('token')).Id;
    }

    static Integer flags(Id entryId) { return ClaimHubTestFactory.events(entryId, 'Needs review: bank details'); }

    // ------------------------------------------------------------------ check digits

    @isTest static void nzCheckDigitsFollowTheIrdExamples() {
        // Worked examples from Inland Revenue's bank account validation rules, and constructed cases for B and F
        System.assert(ClaimHubBank.nzCheckDigitOk('0109020068389000'), 'algorithm A');
        System.assertEquals('A', ClaimHubBank.nzAlgorithm('0109020068389000'));
        System.assert(ClaimHubBank.nzCheckDigitOk('0865231954512001'), 'algorithm D');
        System.assertEquals('D', ClaimHubBank.nzAlgorithm('0865231954512001'));
        System.assert(ClaimHubBank.nzCheckDigitOk('0109020998384000'), 'algorithm B (account from 0990000)');
        System.assertEquals('B', ClaimHubBank.nzAlgorithm('0109020998384000'));
        System.assert(ClaimHubBank.nzCheckDigitOk('2525453153624000'), 'algorithm F');
        System.assert(!ClaimHubBank.nzCheckDigitOk('0109020068388000'), 'last digit changed');
        System.assert(!ClaimHubBank.nzCheckDigitOk('0109020068398000'), 'two digits swapped');
        System.assert(!ClaimHubBank.nzCheckDigitOk('0865231954513001'), 'D, last digit changed');
        System.assert(ClaimHubBank.nzCheckDigitOk('0512340000001000'), 'bank 05 has no published check');
        System.assertEquals('1231400234566000', ClaimHubBank.nz16('123140023456600'), 'two-digit suffix padded');
        System.assertEquals('1231400234566001', ClaimHubBank.nz16('1231400234566001'));
    }

    @isTest static void nzNumberThatFailsTheCheckIsRefused() {
        ClaimHubTestFactory.campaign('NZ', null);
        Integer status;
        try { lodge('NZ', new Map<String, Object>{ 'name' => 'S Tester', 'account' => NZ_TYPO }, 'typo@example.com'); }
        catch (ClaimHubService.HubException ex) { status = ex.status; System.assertEquals(ClaimHubBank.WRONG_NUMBER, ex.getMessage()); }
        System.assertEquals(400, status);
    }

    // ------------------------------------------------------------------ registers

    @isTest static void withoutRegistersNothingIsFlagged() {
        ClaimHubTestFactory.campaign('NZ', null);
        Id e = lodge('NZ', new Map<String, Object>{ 'name' => 'S Tester', 'account' => NZ_UNLISTED }, 'noreg@example.com');
        System.assertEquals(0, flags(e), 'no register loaded, so nothing to compare with');
        System.assertEquals(false, ClaimHubBank.registerLoaded('NZ'));
    }

    @isTest static void nzBankAndBranchInTheRegisterPass() {
        loadRegisters();
        ClaimHubTestFactory.campaign('NZ', null);
        Id e = lodge('NZ', new Map<String, Object>{ 'name' => 'S Tester', 'account' => NZ_GOOD }, 'listed@example.com');
        System.assertEquals(0, flags(e));
        ClaimHubBank.Check chk = ClaimHubBank.nz('123140023456600');
        System.assertEquals('ASB Bank', chk.bankName);
        System.assertEquals('Test Branch', chk.branchName);
        System.assertEquals(null, chk.review);
    }

    @isTest static void nzNumbersTheRegisterDoesNotListAreFlaggedNotRefused() {
        loadRegisters();
        ClaimHubTestFactory.campaign('NZ', null);
        Id e = lodge('NZ', new Map<String, Object>{ 'name' => 'S Tester', 'account' => NZ_UNLISTED }, 'unlisted@example.com');
        System.assertEquals(1, flags(e), 'accepted, and flagged for a person to look at');
        Claim_Event__c ev = [SELECT Detail__c FROM Claim_Event__c WHERE Entry__c = :e AND Action__c LIKE 'Needs review: bank details%'];
        System.assert(ev.Detail__c.contains('Bank 99, branch 3140') && ev.Detail__c.contains('no check digit'), ev.Detail__c);
        ClaimHubBank.Check otherBranch = ClaimHubBank.nz('123141023456800');
        System.assert(otherBranch.review.contains('branch 3141') && !otherBranch.review.contains('no check digit'), 'known bank, branch not listed: ' + otherBranch.review);
    }

    // One lodge per test: each lodge also runs the org's existing Entry flows, and three in one
    // transaction passed the 100-query limit in Wizard. Claimants lodge one claim per transaction.
    @isTest static void auBsbInTheDirectoryPasses() {
        loadRegisters();
        ClaimHubTestFactory.campaign('AU', null);
        Id listed = lodge('AU', new Map<String, Object>{ 'name' => 'S Tester', 'bsb' => '062-000', 'account' => '12345678' }, 'au1@example.com');
        System.assertEquals(0, flags(listed));
        System.assertEquals('Commonwealth Bank of Australia', ClaimHubBank.au('062000').bankName);
    }

    @isTest static void auBsbNotInTheDirectoryIsFlagged() {
        loadRegisters();
        ClaimHubTestFactory.campaign('AU', null);
        Id unlisted = lodge('AU', new Map<String, Object>{ 'name' => 'S Tester', 'bsb' => '999-999', 'account' => '12345679' }, 'au2@example.com');
        System.assertEquals(1, flags(unlisted), 'BSB not in the directory');
    }

    @isTest static void auBsbListedAsClosedIsFlagged() {
        loadRegisters();
        ClaimHubBank.Check chk = ClaimHubBank.au('062002');
        System.assert(chk.review != null && chk.review.contains('closed'), 'closed BSB: ' + chk.review);
        System.assertEquals(true, ClaimHubBank.lookup('AU', '062002').get('closed'));
        System.assertEquals(false, ClaimHubBank.lookup('AU', '062000').get('closed'));
    }

    @isTest static void auBsbWithNoElectronicPaymentsIsFlagged() {
        loadRegisters();
        ClaimHubTestFactory.campaign('AU', null);
        Id paper = lodge('AU', new Map<String, Object>{ 'name' => 'S Tester', 'bsb' => '062-001', 'account' => '12345670' }, 'au3@example.com');
        System.assertEquals(1, flags(paper), 'BSB takes no electronic payments');
    }

    @isTest static void bankChangesAreCheckedToo() {
        loadRegisters();
        ClaimHubTestFactory.campaign('AU', null);
        String token = ClaimHubTestFactory.lodge([SELECT Id FROM Promotional_Campaign__c LIMIT 1].Id, 'change@example.com', 1, true, 'AU');
        Entry__c e = ClaimHubTestFactory.entry(token);
        ClaimHubService.requestCode(token);
        Claim_OTP__c otp = [SELECT Id FROM Claim_OTP__c WHERE Entry__c = :e.Id];
        update new Claim_OTP__c(Id = otp.Id, Code_Hash__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(e.Id + ':123456'))));
        ClaimHubService.changeBank(token, new Map<String, Object>{ 'code' => '123456', 'name' => 'S Tester', 'bsb' => '999-998', 'account' => '87654321' });
        System.assertEquals(1, flags(e.Id), 'new BSB is not in the directory');
    }

    // ------------------------------------------------------------------ lookup for the claim form

    @isTest static void lookupShowsBankAndBranch() {
        loadRegisters();
        Map<String, Object> nz = (Map<String, Object>) ClaimHubApi.route('GET', new List<String>{ 'banks', 'NZ', '123140' }, new Map<String, Object>());
        System.assertEquals(true, nz.get('found'));
        System.assertEquals('ASB Bank', nz.get('bankName'));
        Map<String, Object> au = ClaimHubBank.lookup('au', '062001');
        System.assertEquals('Paper Only Branch', au.get('branchName'));
        System.assertEquals(false, au.get('electronic'));
        Map<String, Object> missing = ClaimHubBank.lookup('AU', '999999');
        System.assertEquals(false, missing.get('found'));
        System.assertEquals(true, missing.get('registerLoaded'));
        for (List<String> bad : new List<List<String>>{ new List<String>{ 'UK', '123456' }, new List<String>{ 'NZ', '12345' }, new List<String>{ 'NZ', '12a456' }, new List<String>{ null, null } }) {
            Integer status;
            try { ClaimHubBank.lookup(bad[0], bad[1]); } catch (ClaimHubService.HubException ex) { status = ex.status; }
            System.assertEquals(400, status, String.valueOf(bad));
        }
    }

    @isTest static void healthCheckReportsRegisterRows() {
        loadRegisters();
        Map<String, Object> rows = (Map<String, Object>) ClaimHubMonitor.snapshot().get('bankRegisterRows');
        System.assertEquals(1, rows.get('NZ'));
        System.assertEquals(3, rows.get('AU'));
    }
}
