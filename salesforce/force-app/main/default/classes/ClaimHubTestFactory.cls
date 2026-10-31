/**
 * Test data and a fake Claude for the claim hub tests. Nothing here runs outside tests.
 */
@isTest
public class ClaimHubTestFactory {

    public static final String SLUG = 'test-cashback';
    public static final List<String> MODELS = new List<String>{ 'TESTA001', 'TESTB002', 'TESTC003' };

    /** A hub campaign open for claims today. country: 'AU' or 'NZ'. percent: null for fixed tiers ($100 for 1, $250 for 2+). */
    public static Promotional_Campaign__c campaign(String country, Decimal percent) {
        Account a = new Account(Name = 'Test Brand Pty Ltd');
        insert a;
        Promotional_Campaign__c c = new Promotional_Campaign__c(Name = 'Test Cashback', Account__c = a.Id, Active__c = true, Status__c = 'Active',
            Campaign_Type__c = 'Cashback', Hub_Enabled__c = true, Hub_Slug__c = SLUG, Hub_Country__c = country, Hub_Brand_Name__c = 'TestBrand',
            Hub_Base_URL__c = 'https://claims.example.com', Hub_Timezone__c = country == 'NZ' ? 'Pacific/Auckland' : 'Australia/Sydney',
            Hub_Retailers__c = 'Harvey Norman', Hub_Excluded_Serial_Prefixes__c = 'A,B,C', Hub_Payment_Promise__c = 'within 6 to 8 weeks',
            Hub_Terms_Summary__c = 'Buy participating appliances at Harvey Norman and claim cashback.',
            Sales_From__c = Date.today().addDays(-30), Sales_To__c = Date.today().addDays(30),
            Date_start__c = Datetime.now().addDays(-30), Date_end__c = Datetime.now().addDays(30),
            Hub_Serial_Deadline__c = Datetime.now().addDays(90), Hub_Bank_Deadline__c = Datetime.now().addDays(120),
            Minimum_Number_Of_Products__c = 1, Maximum_Number_Of_Products__c = 10);
        insert c;
        List<Campaign_Product__c> cps = new List<Campaign_Product__c>();
        for (String m : MODELS) cps.add(new Campaign_Product__c(Name = m, Name__c = 'Test appliance ' + m, Category__c = 'Oven', Manufacturer_Client__c = a.Id));
        insert cps;
        List<Promotional_Product__c> pps = new List<Promotional_Product__c>();
        for (Campaign_Product__c cp : cps) pps.add(new Promotional_Product__c(Promotional_Campaign__c = c.Id, Campaign_Products__c = cp.Id));
        insert pps;
        if (percent == null) {
            insert new List<Cashback_Range__c>{
                new Cashback_Range__c(Name = '1 product', Promotional_Campaign__c = c.Id, Cashback_Type__c = 'Product Quantity', Minimum_Quantity__c = 1, Maximum_Quantity__c = 1, Cashback_Value__c = 100),
                new Cashback_Range__c(Name = '2+ products', Promotional_Campaign__c = c.Id, Cashback_Type__c = 'Product Quantity', Minimum_Quantity__c = 2, Cashback_Value__c = 250) };
        } else {
            insert new Cashback_Range__c(Name = percent + '%', Promotional_Campaign__c = c.Id, Cashback_Type__c = 'Product Quantity', Minimum_Quantity__c = 1, Percentage__c = percent);
        }
        return c;
    }

    public static List<Promotional_Product__c> products(Id campaignId) {
        return [SELECT Id, Campaign_Products__r.Name FROM Promotional_Product__c WHERE Promotional_Campaign__c = :campaignId ORDER BY Campaign_Products__r.Name];
    }

    /** A claim request body. count products, each priced at 1,000. */
    public static Map<String, Object> claimRequest(Id campaignId, String email, Integer count, Boolean withBank, String country) {
        List<Object> items = new List<Object>();
        List<Promotional_Product__c> ps = products(campaignId);
        for (Integer i = 0; i < count; i++) items.add(new Map<String, Object>{ 'promoProductId' => ps[i].Id, 'price' => '$1,000' });
        Map<String, Object> req = new Map<String, Object>{ 'firstName' => 'Sam', 'lastName' => 'Tester', 'email' => email, 'mobile' => mobileFor(email), 'products' => items, 'acceptedTerms' => true };
        if (withBank) req.put('bank', country == 'NZ'
            ? new Map<String, Object>{ 'name' => 'S Tester', 'account' => '12-3140-0234566-00' }
            : new Map<String, Object>{ 'name' => 'S Tester', 'bsb' => '062-000', 'account' => '12345678' });
        return req;
    }

    /** A different made-up mobile for each email, so only tests that mean to share a mobile do. */
    public static String mobileFor(String email) {
        return '04' + String.valueOf(Math.abs(email.hashCode())).leftPad(8, '0').right(8);
    }

    /** Lodges a claim and returns its link code. */
    public static String lodge(Id campaignId, String email, Integer count, Boolean withBank, String country) {
        return (String) ClaimHubService.lodge(SLUG, claimRequest(campaignId, email, count, withBank, country)).get('token');
    }

    /** Claims made directly (not through lodge), for bulk tests. */
    public static List<Entry__c> bulkEntries(Id campaignId, Integer n, String status) {
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < n; i++) leads.add(new Lead(FirstName = 'Bulk', LastName = 'Claimant' + i, Email = 'bulk' + i + '@example.com', Company = 'None',
            Account_Name__c = 'B Claimant', BSB__c = '062000', Account_Number__c = '1000000' + i));
        insert leads;
        List<Entry__c> es = new List<Entry__c>();
        for (Integer i = 0; i < n; i++) es.add(new Entry__c(RecordTypeId = ClaimHubService.hubRecordType('Entry__c'), Promotional_Campaign__c = campaignId, Customer__c = leads[i].Id,
            Entry_Status__c = status, Consumer_First_Name_Stamp__c = 'Bulk', Consumer_Last_Name_Stamp__c = 'Claimant' + i, Consumer_Email_Stamp__c = 'bulk' + i + '@example.com',
            Consumer_Account_Name_Stamp__c = 'B Claimant', Consumer_BSB_Stamp__c = '062000', Consumer_Account_Number_Stamp__c = '1000000' + i,
            Cashback_Amount__c = 100, I_have_read_and_accepted_the_promotion__c = true, Access_Token__c = ClaimAccessToken.newToken()));
        insert es;
        return es;
    }

    public static Entry__c entry(String token) {
        return [SELECT Id, Name, Entry_Status__c, EFT_Status__c, Cashback_Amount__c, Purchase_Price__c, Customer__c, Promotional_Campaign__c,
                       Consumer_Bank_Account_Number__c, Consumer_Account_Number_Stamp__c, Consumer_BSB_Stamp__c
                FROM Entry__c WHERE Access_Token__c = :token];
    }

    public static Integer events(Id entryId, String actionPrefix) {
        String pattern = actionPrefix + '%';
        return [SELECT COUNT() FROM Claim_Event__c WHERE Entry__c = :entryId AND Action__c LIKE :pattern];
    }

    // ------------------------------------------------------------------ fake Claude
    /** Answers like the Claude Messages API. Set the public fields to change what it says. */
    public class Claude implements HttpCalloutMock {
        public Integer status = 200;
        public Boolean fail = false;
        public Map<String, Object> invoice = goodInvoice();
        public Map<String, Object> plate = new Map<String, Object>{ 'serial' => '61234567', 'pnc' => '949597455', 'model' => 'TESTOVN01', 'readable' => true };
        public String chatReply = 'Payment is made within 6 to 8 weeks of approval.';
        public Map<String, Object> terms;
        public Integer calls = 0;

        public HttpResponse respond(HttpRequest req) {
            calls++;
            if (fail) throw new CalloutException('Read timed out');
            String body = req.getBody();
            String text;
            if (body.contains('"system"')) text = chatReply;
            else if (body.contains('rating plate')) text = JSON.serialize(plate);
            else if (body.contains('tax invoice')) text = JSON.serialize(invoice);
            else if (body.contains('setting up a cashback promotion')) text = 'Here it is: ' + JSON.serialize(terms) + ' done.';
            else text = chatReply;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(status == 200 ? JSON.serialize(new Map<String, Object>{ 'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => text } } })
                                      : '{"type":"error","error":{"type":"overloaded_error"}}');
            return res;
        }
    }

    public static Claude claude() {
        Claude c = new Claude();
        Test.setMock(HttpCalloutMock.class, c);
        return c;
    }

    /** An invoice that passes every check for a two-product claim at 1,000 each, lodged by Sam Tester. */
    public static Map<String, Object> goodInvoice() {
        return new Map<String, Object>{ 'isInvoice' => true, 'retailer' => 'Harvey Norman', 'store' => 'Harvey Norman Auburn',
            'invoiceNumber' => 'HN-100200', 'invoiceDate' => String.valueOf(Date.today().addDays(-2)), 'total' => 2000, 'balanceDue' => 0,
            'customerName' => 'Sam Tester', 'lines' => new List<Object>{
                new Map<String, Object>{ 'model' => MODELS[0], 'description' => 'Oven', 'price' => 1000 },
                new Map<String, Object>{ 'model' => MODELS[1], 'description' => 'Cooktop', 'price' => 1000 } } };
    }

    public static Map<String, Object> receiptRequest() {
        return new Map<String, Object>{ 'base64' => EncodingUtil.base64Encode(Blob.valueOf('fake image bytes')), 'contentType' => 'image/jpeg', 'fileName' => 'invoice.jpg' };
    }
}
