/**
 * Claim hub engine. Salesforce is the system of record; the hub web app calls this through ClaimHubApi.
 * Every claimant action is keyed by the claim's random link code (Entry__c.Access_Token__c), never a record Id.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubService {

    public class HubException extends Exception {
        public Integer status = 400;
        public Id flagEntry; public String flagAction; public String flagDetail;
        public HubException flag(Id entryId, String action, String detail) { flagEntry = entryId; flagAction = action; flagDetail = detail == null ? null : detail.left(255); return this; }
        public HubException(Integer status, String message) { this(message); this.status = status; }
    }

    public static final String STATUS_AWAITING = 'Submitted - Awaiting Details';
    public static final String STATUS_COMPLETE = 'Submitted';
    public static final Set<String> OPEN_STATUSES = new Set<String>{ STATUS_AWAITING, STATUS_COMPLETE };

    // ---------------------------------------------------------------- campaign
    public static Promotional_Campaign__c campaignBySlug(String slug) {
        List<Promotional_Campaign__c> cs = [
            SELECT Id, Name, Job_Number__c, Hub_Enabled__c, Hub_Slug__c, Hub_Headline__c, Hub_Brand_Color__c, Hub_Terms_URL__c,
                   Hub_Base_URL__c, Hub_Serial_Deadline__c, Hub_Bank_Deadline__c, Hub_Payment_Promise__c, Hub_Sender_Address__c,
                   Hub_Timezone__c, Hub_Terms_Summary__c, Date_start__c, Date_end__c, Sales_From__c, Sales_To__c,
                   Entry_Record_Type_ID__c, First_Product_RecordType_ID__c, Minimum_Number_Of_Products__c, Maximum_Number_Of_Products__c,
                   Campaign_Email_Address__c, Campaign_Email_From_Name__c, Hub_Country__c, Hub_Brand_Name__c, Hub_Retailers__c,
                   Hub_Excluded_Serial_Prefixes__c, Hub_Min_Spend__c, Hub_Single_Transaction__c, Hub_Max_Cashback__c
            FROM Promotional_Campaign__c WHERE Hub_Slug__c = :slug AND Hub_Enabled__c = true LIMIT 1];
        if (cs.isEmpty()) throw new HubException(404, 'Promotion not found');
        return cs[0];
    }

    public static Map<String, Object> publicCampaign(String slug) {
        Promotional_Campaign__c c = campaignBySlug(slug);
        List<Object> products = new List<Object>();
        for (Promotional_Product__c p : [SELECT Id, Campaign_Products__r.Name, Campaign_Products__r.Name__c, Campaign_Products__r.Category__c
                                         FROM Promotional_Product__c WHERE Promotional_Campaign__c = :c.Id
                                         ORDER BY Campaign_Products__r.Category__c, Campaign_Products__r.Name]) {
            products.add(new Map<String, Object>{ 'id' => p.Id, 'model' => p.Campaign_Products__r.Name,
                'name' => p.Campaign_Products__r.Name__c, 'category' => p.Campaign_Products__r.Category__c });
        }
        List<Object> tiers = new List<Object>();
        List<Cashback_Range__c> rs = ranges(c.Id);
        for (Cashback_Range__c r : rs) {
            tiers.add(new Map<String, Object>{ 'minQty' => r.Minimum_Quantity__c, 'maxQty' => r.Maximum_Quantity__c, 'minSpend' => r.Minimum_Value__c,
                'maxSpend' => r.Maximum_Value__c, 'amount' => r.Cashback_Value__c, 'percent' => r.Percentage__c, 'label' => r.Name });
        }
        Datetime now = Datetime.now();
        return new Map<String, Object>{
            'slug' => c.Hub_Slug__c, 'name' => c.Name, 'headline' => c.Hub_Headline__c, 'brandColor' => c.Hub_Brand_Color__c,
            'termsUrl' => c.Hub_Terms_URL__c, 'termsSummary' => c.Hub_Terms_Summary__c, 'paymentPromise' => c.Hub_Payment_Promise__c,
            'purchaseFrom' => c.Sales_From__c, 'purchaseTo' => c.Sales_To__c, 'claimsOpen' => c.Date_start__c, 'claimsClose' => c.Date_end__c,
            'serialDeadline' => c.Hub_Serial_Deadline__c, 'bankDeadline' => c.Hub_Bank_Deadline__c, 'timezone' => c.Hub_Timezone__c,
            'minProducts' => c.Minimum_Number_Of_Products__c, 'maxProducts' => c.Maximum_Number_Of_Products__c,
            'isOpen' => (c.Date_start__c == null || c.Date_start__c <= now) && (c.Date_end__c == null || c.Date_end__c >= now),
            'products' => products, 'tiers' => tiers, 'tierBasis' => tierBasis(rs), 'maxCashback' => c.Hub_Max_Cashback__c, 'needsPrices' => needsPrices(rs, c), 'supportEmail' => c.Hub_Sender_Address__c,
            'country' => country(c.Hub_Country__c), 'currency' => country(c.Hub_Country__c) == 'NZ' ? 'NZD' : 'AUD', 'brandName' => c.Hub_Brand_Name__c,
            'retailers' => c.Hub_Retailers__c, 'minSpend' => c.Hub_Min_Spend__c, 'singleTransaction' => c.Hub_Single_Transaction__c,
            'excludedSerialPrefixes' => c.Hub_Excluded_Serial_Prefixes__c };
    }

    public static String country(String v) { return String.isBlank(v) ? 'AU' : v.trim().toUpperCase(); }

    /** spend = fixed amounts by spend band; percent = a share of what was paid; quantity = fixed amounts by number of appliances. */
    static String tierBasis(List<Cashback_Range__c> rs) {
        for (Cashback_Range__c r : rs) if (r.Percentage__c != null && r.Percentage__c > 0) return 'percent';
        for (Cashback_Range__c r : rs) if (r.Minimum_Value__c != null && r.Minimum_Value__c > 0) return 'spend';
        return 'quantity';
    }

    /** Prices matter whenever the payout or eligibility depends on them. */
    static Boolean needsPrices(List<Cashback_Range__c> rs, Promotional_Campaign__c c) {
        return tierBasis(rs) != 'quantity' || c.Hub_Min_Spend__c != null;
    }

    /** What one tier pays on a given spend, before any campaign cap. */
    public static Decimal amountFor(Cashback_Range__c r, Decimal spend) {
        if (r.Cashback_Value__c != null) return r.Cashback_Value__c;
        if (r.Percentage__c != null && spend != null) return (spend * r.Percentage__c / 100).setScale(2, RoundingMode.HALF_UP);
        return null;
    }

    /** Shared record types for hub campaigns. The old platform needs one set per campaign because its entry trigger finds the
     *  campaign from the record type; the hub links every claim to its campaign directly. */
    static Map<String, Id> hubRts;
    public static Id hubRecordType(String sobjectName) {
        if (hubRts == null) {
            hubRts = new Map<String, Id>();
            for (RecordType rt : [SELECT Id, SobjectType FROM RecordType WHERE DeveloperName IN ('Claim_Hub', 'Claim_Hub_Entry_Product', 'Claim_Hub_Entry_Receipt')]) hubRts.put(rt.SobjectType, rt.Id);
        }
        return hubRts.get(sobjectName);
    }

    public static String money(Decimal d, String countryCode) {
        if (d == null) return '';
        Decimal r = d.setScale(2, RoundingMode.HALF_UP);
        String txt = r == r.setScale(0, RoundingMode.DOWN) ? r.setScale(0).format() : r.format();
        if (txt.contains('.') && txt.substringAfter('.').length() == 1) txt += '0';
        return (country(countryCode) == 'NZ' ? 'NZ$' : '$') + txt;
    }

    static List<Cashback_Range__c> ranges(Id campaignId) {
        return [SELECT Id, Name, Cashback_Value__c, Percentage__c, Minimum_Quantity__c, Maximum_Quantity__c, Minimum_Value__c, Maximum_Value__c FROM Cashback_Range__c
                WHERE Promotional_Campaign__c = :campaignId ORDER BY Minimum_Value__c ASC NULLS FIRST, Minimum_Quantity__c ASC];
    }

    static Cashback_Range__c rangeFor(Id campaignId, Integer qty, Decimal spend) {
        Cashback_Range__c best; Decimal bestAmt;
        for (Cashback_Range__c r : ranges(campaignId)) {
            if (r.Minimum_Quantity__c != null && qty < r.Minimum_Quantity__c) continue;
            if (r.Maximum_Quantity__c != null && qty > r.Maximum_Quantity__c) continue;
            if (r.Minimum_Value__c != null && r.Minimum_Value__c > 0 && (spend == null || spend < r.Minimum_Value__c)) continue;
            Decimal amt = amountFor(r, spend);
            if (amt == null) continue;
            if (best == null || amt > bestAmt) { best = r; bestAmt = amt; }
        }
        return best;
    }

    // ---------------------------------------------------------------- lodge
    public static Map<String, Object> lodge(String slug, Map<String, Object> req) {
        Promotional_Campaign__c c = campaignBySlug(slug);
        Datetime now = Datetime.now();
        if ((c.Date_start__c != null && c.Date_start__c > now) || (c.Date_end__c != null && c.Date_end__c < now)) {
            throw new HubException(409, 'Claims for this promotion are closed.');
        }
        String first = req(req, 'firstName').trim(), last = req(req, 'lastName').trim(), email = req(req, 'email').trim().toLowerCase(), mobile = req(req, 'mobile').trim();
        if (first.length() > 40 || last.length() > 80) throw new HubException(400, 'Please shorten your name.');
        if (email.length() > 80 || !Pattern.matches('^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$', email)) throw new HubException(400, 'Please check your email address.');
        String mobileDigits = mobile.replaceAll('[^0-9]', '');
        if (mobileDigits.length() < 8 || mobileDigits.length() > 15) throw new HubException(400, 'Please check your mobile number.');

        // One claim per person: same email on this promotion. The unique duplicate key also stops two arriving at once.
        if (![SELECT Id FROM Entry__c WHERE Promotional_Campaign__c = :c.Id AND Consumer_Email_Stamp__c = :email LIMIT 1].isEmpty()) {
            throw new HubException(409, DUPLICATE_EMAIL);
        }

        // Many claims from one connection: refuse above the daily limit, flag from the third
        String ipHash = req.get('_ip') == null ? null : hash(String.valueOf(req.get('_ip')) + ':' + UserInfo.getOrganizationId());
        Integer fromIp = ipHash == null ? 0 : [SELECT COUNT() FROM Entry__c WHERE Hub_Client_IP_Hash__c = :ipHash AND CreatedDate = LAST_N_DAYS:1];
        if (fromIp >= ClaimHubSettings.claimsPerIpDaily()) throw new HubException(429, 'We have had a lot of claims from your connection today. Please try again tomorrow, or email us.');

        List<Object> items = (List<Object>) req.get('products');
        if (items == null || items.isEmpty()) throw new HubException(400, 'Add the appliances you bought.');
        Integer minQ = c.Minimum_Number_Of_Products__c == null ? 1 : c.Minimum_Number_Of_Products__c.intValue();
        if (items.size() < minQ) throw new HubException(400, 'This promotion needs at least ' + minQ + ' participating appliances.');

        Map<Id, Promotional_Product__c> promo = new Map<Id, Promotional_Product__c>([
            SELECT Id, Campaign_Products__c, Campaign_Products__r.Name, Campaign_Products__r.Name__c
            FROM Promotional_Product__c WHERE Promotional_Campaign__c = :c.Id]);

        // Combined spend on participating appliances (the tiers and minimum spend in spend-based promotions use this)
        Boolean bySpend = needsPrices(ranges(c.Id), c);
        Decimal spend = 0;
        for (Object o : items) {
            if (!(o instanceof Map<String, Object>)) throw new HubException(400, 'Add the appliances you bought.');
            Decimal price = price(((Map<String, Object>) o).get('price'));
            if (price == null) { if (bySpend) throw new HubException(400, 'Add the price you paid for each appliance. The cashback depends on your total spend.'); }
            else spend += price;
        }
        if (c.Hub_Min_Spend__c != null && spend < c.Hub_Min_Spend__c) {
            throw new HubException(400, 'This promotion needs a combined spend of at least ' + money(c.Hub_Min_Spend__c, c.Hub_Country__c) +
                ' on participating appliances' + (c.Hub_Single_Transaction__c ? ' in one transaction' : '') + '. Your total is ' + money(spend, c.Hub_Country__c) + '.');
        }

        // Products and serial rules before anything is saved
        Set<String> formSerials = new Set<String>();
        for (Object o : items) {
            Map<String, Object> it = (Map<String, Object>) o;
            if (!promo.containsKey(idOrNull(it.get('promoProductId')))) throw new HubException(400, 'One of the products is not part of this promotion.');
            String sv = it.get('serial') == null ? null : String.valueOf(it.get('serial'));
            if (String.isBlank(sv)) continue;
            checkSerialRules(sv, c.Hub_Excluded_Serial_Prefixes__c);
            if (!formSerials.add(sv.trim().toUpperCase())) throw new HubException(400, 'The same serial number is entered twice.');
        }

        Lead l = new Lead(FirstName = first, LastName = last, Email = email, MobilePhone = mobile, Company = 'None');
        if (country(c.Hub_Country__c) == 'NZ') l.Contact_Number__c = mobile;
        Map<String, Object> bank = (Map<String, Object>) req.get('bank');
        if (bank != null) applyBank(l, bank, c.Hub_Country__c);
        insert l;

        Cashback_Range__c range = rangeFor(c.Id, items.size(), spend);
        Decimal cashback = range == null ? null : amountFor(range, spend);
        if (cashback != null && c.Hub_Max_Cashback__c != null && cashback > c.Hub_Max_Cashback__c) cashback = c.Hub_Max_Cashback__c;
        Id entryRt = c.Entry_Record_Type_ID__c != null ? (Id) c.Entry_Record_Type_ID__c : hubRecordType('Entry__c');
        Id productRt = c.First_Product_RecordType_ID__c != null ? (Id) c.First_Product_RecordType_ID__c : hubRecordType('Entry_Product__c');
        Entry__c e = new Entry__c(RecordTypeId = entryRt, Promotional_Campaign__c = c.Id, Customer__c = l.Id, Promotional_Campaign_Stamp__c = c.Name,
            Entry_Status__c = STATUS_AWAITING, Cashback_Range__c = range == null ? null : range.Id,
            Cashback_Amount__c = cashback,
            Consumer_First_Name_Stamp__c = first, Consumer_Last_Name_Stamp__c = last, Consumer_Email_Stamp__c = email,
            Consumer_Mobile_Stamp__c = mobile, Hub_Last_Activity__c = now, Purchase_Price__c = spend > 0 ? spend : null,
            // The claim form cannot be submitted without ticking "I've read the terms"
            I_have_read_and_accepted_the_promotion__c = true,
            Hub_Dedupe_Key__c = hash(c.Id + ':' + email), Hub_Client_IP_Hash__c = ipHash);
        // Same stamps the old entry trigger sets (it only finds campaigns by record type): weekly reports and the C4C feed read them
        if (e.Created_At_Datetime__c == null) {
            e.Created_At_Datetime__c = now;
            e.Created_At_Timestamp__c = now.getTime();
            e.Created_At_Datetime_AEST__c = now.addHours(TimeZone.getTimeZone('Australia/Sydney').getOffset(now) / 3600000);
        }
        if (bank != null) stampBank(e, l);
        try { insert e; }
        catch (DmlException ex) {
            if (ex.getDmlType(0) == StatusCode.DUPLICATE_VALUE) throw new HubException(409, DUPLICATE_EMAIL);
            throw ex;
        }

        List<Entry_Product__c> eps = new List<Entry_Product__c>();
        Set<String> seen = new Set<String>();
        for (Object o : items) {
            Map<String, Object> it = (Map<String, Object>) o;
            Promotional_Product__c p = promo.get(idOrNull(it.get('promoProductId')));
            if (p == null) throw new HubException(400, 'One of the products is not part of this promotion.');
            Entry_Product__c ep = new Entry_Product__c(RecordTypeId = productRt, Entry__c = e.Id, Promotional_Product__c = p.Id, Product__c = p.Campaign_Products__c,
                Purchase_Price__c = price(it.get('price')), Serial_Number_Status__c = 'Product awaiting delivery');
            String serial = (String) it.get('serial'), pnc = (String) it.get('pnc');
            if (String.isNotBlank(serial)) {
                checkSerial(serial, pnc, null, null, c.Hub_Excluded_Serial_Prefixes__c);
                if (!seen.add(serial.trim().toUpperCase())) throw new HubException(400, 'The same serial number is entered twice.');
                ep.Serial_Number__c = serial.trim().toUpperCase(); ep.Hub_Serial_Key__c = ep.Serial_Number__c; ep.PNC_Number__c = pnc == null ? null : pnc.trim();
                ep.Serial_Number_Status__c = 'I have received this product';
            }
            eps.add(ep);
        }
        insertSerials(eps);

        Map<String, Object> inv = (Map<String, Object>) req.get('invoice');
        if (inv != null) {
            insert new Entry_Receipt__c(RecordTypeId = receiptRecordType(entryRt), Entry__c = e.Id, Receipt_Number__c = (String) inv.get('number'),
                Receipt_Date__c = dateOrNull(inv.get('date')),
                Store_Name__c = (String) inv.get('store'));
        }

        ClaimHubLog.event(e.Id, 'Claimant', 'Lodged', items.size() + ' appliances' + (spend > 0 ? ', spend ' + money(spend, c.Hub_Country__c) : '') +
            ', cashback ' + (cashback == null ? 'none' : money(cashback, c.Hub_Country__c) + (range.Percentage__c != null ? ' (' + range.Percentage__c + '%)' : '')));
        if (fromIp + 1 >= ClaimHubSettings.IP_FLAG_AT) ClaimHubLog.event(e.Id, 'System', 'Needs review: several claims from one connection', (fromIp + 1) + ' claims from the same connection in 24 hours');
        if (bank != null) flagSharedBank(e.Id, c.Id, l);
        Entry__c fresh = load(e.Id);
        recompute(fresh, null);
        ClaimHubNotifier.enqueueNow(fresh.Id, 'LODGED');
        return new Map<String, Object>{ 'token' => fresh.Access_Token__c };
    }

    // ---------------------------------------------------------------- read
    public static Entry__c byToken(String token) {
        Entry__c ref = ClaimAccessToken.resolve(token);
        if (ref == null) throw new HubException(404, 'expired');
        return load(ref.Id);
    }

    public static Entry__c load(Id entryId) {
        Entry__c e = loadMany(new Set<Id>{ entryId }).get(entryId);
        if (e == null) throw new HubException(404, 'expired');
        return e;
    }

    /** Claims with everything the API, the emails and the status engine need, in one query. */
    public static Map<Id, Entry__c> loadMany(Set<Id> entryIds) {
        return new Map<Id, Entry__c>([SELECT Id, Name, Access_Token__c, Entry_Status__c, EFT_Status__c, Invalid_Reason__c, Cashback_Amount__c, CreatedDate,
                       Customer__c, Consumer_First_Name_Stamp__c, Consumer_Last_Name_Stamp__c, Consumer_Email_Stamp__c, Consumer_Mobile_Stamp__c,
                       Consumer_Account_Name_Stamp__c, Consumer_BSB_Stamp__c, Consumer_Account_Number_Stamp__c, Hub_Reminders_Sent__c,
                       Consumer_Bank_Account_Number__c, Purchase_Price__c, Promotional_Campaign__r.Hub_Country__c, Promotional_Campaign__r.Hub_Brand_Name__c,
                       Promotional_Campaign__r.Hub_Excluded_Serial_Prefixes__c, Promotional_Campaign__r.Hub_Retailers__c,
                       Promotional_Campaign__r.Hub_Min_Spend__c, Promotional_Campaign__r.Hub_Single_Transaction__c,
                       Promotional_Campaign__r.Sales_From__c, Promotional_Campaign__r.Sales_To__c,
                       Promotional_Campaign__c, Promotional_Campaign__r.Name, Promotional_Campaign__r.Hub_Slug__c,
                       Promotional_Campaign__r.Hub_Base_URL__c, Promotional_Campaign__r.Hub_Serial_Deadline__c,
                       Promotional_Campaign__r.Hub_Bank_Deadline__c, Promotional_Campaign__r.Hub_Payment_Promise__c,
                       Promotional_Campaign__r.Hub_Sender_Address__c, Promotional_Campaign__r.Hub_Brand_Color__c,
                       Promotional_Campaign__r.Hub_Timezone__c, Promotional_Campaign__r.Hub_Enabled__c,
                       (SELECT Id, Serial_Number__c, PNC_Number__c, Purchase_Price__c, Serial_Number_Status__c,
                               Promotional_Product__r.Campaign_Products__r.Name, Promotional_Product__r.Campaign_Products__r.Name__c,
                               Promotional_Product__r.Campaign_Products__r.Category__c
                        FROM Entry_Products__r ORDER BY CreatedDate),
                       (SELECT Id, Receipt_Number__c, Receipt_Date__c, Store_Name__c, OCR_Status__c, OCR_Invoice_Date__c, OCR_Store_Name__c, Hub_Has_File__c, Hub_File_Key__c FROM Entry_Receipts__r ORDER BY CreatedDate)
                FROM Entry__c WHERE Id IN :entryIds]);
    }

    /** The hub sets Hub_Has_File__c when it stores an invoice; a file staff attach by hand in Salesforce also counts. */
    public static Boolean hasReceiptFile(Entry__c e) {
        Set<Id> ids = new Set<Id>();
        for (Entry_Receipt__c r : e.Entry_Receipts__r) { if (r.Hub_Has_File__c) return true; ids.add(r.Id); }
        if (ids.isEmpty()) return false;
        return ![SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId IN :ids LIMIT 1].isEmpty();
    }

    public static Boolean hasBank(Entry__c e) {
        if (country(e.Promotional_Campaign__r.Hub_Country__c) == 'NZ') return String.isNotBlank(e.Consumer_Bank_Account_Number__c);
        return String.isNotBlank(e.Consumer_BSB_Stamp__c) && String.isNotBlank(e.Consumer_Account_Number_Stamp__c);
    }

    /** The account number the claimant gave, whichever country format it is in. */
    public static String accountNumber(Entry__c e) {
        return country(e.Promotional_Campaign__r.Hub_Country__c) == 'NZ' ? e.Consumer_Bank_Account_Number__c : e.Consumer_Account_Number_Stamp__c;
    }

    public static List<String> outstanding(Entry__c e) {
        List<String> out = new List<String>();
        if (!hasReceiptFile(e)) out.add('invoice');
        for (Entry_Product__c p : e.Entry_Products__r) if (String.isBlank(p.Serial_Number__c)) out.add('serial:' + p.Promotional_Product__r.Campaign_Products__r.Name);
        if (!hasBank(e)) out.add('bank');
        return out;
    }

    public static Map<String, Object> view(String token) {
        Entry__c e = byToken(token);
        Boolean receiptOk = hasReceiptFile(e);
        List<Object> products = new List<Object>();
        for (Entry_Product__c p : e.Entry_Products__r) {
            products.add(new Map<String, Object>{ 'id' => p.Id, 'model' => p.Promotional_Product__r.Campaign_Products__r.Name,
                'name' => p.Promotional_Product__r.Campaign_Products__r.Name__c, 'category' => p.Promotional_Product__r.Campaign_Products__r.Category__c,
                'price' => p.Purchase_Price__c, 'serial' => p.Serial_Number__c, 'pnc' => p.PNC_Number__c, 'done' => String.isNotBlank(p.Serial_Number__c) });
        }
        List<Object> receipts = new List<Object>();
        for (Entry_Receipt__c r : e.Entry_Receipts__r) {
            receipts.add(new Map<String, Object>{ 'number' => r.Receipt_Number__c, 'date' => r.Receipt_Date__c, 'store' => r.Store_Name__c, 'check' => r.OCR_Status__c });
        }
        List<Object> timeline = new List<Object>();
        for (Claim_Event__c ev : [SELECT Actor__c, Action__c, Detail__c, CreatedDate FROM Claim_Event__c WHERE Entry__c = :e.Id ORDER BY CreatedDate DESC LIMIT 20]) {
            // Staff-only entries (fraud flags, internal notes) never reach the claimant's page
            if (ev.Action__c != null && (ev.Action__c.startsWith('Internal') || ev.Action__c.startsWith('Needs review'))) continue;
            timeline.add(new Map<String, Object>{ 'at' => ev.CreatedDate, 'who' => ev.Actor__c, 'what' => ev.Action__c });
        }
        return new Map<String, Object>{
            'claimNumber' => e.Name, 'firstName' => e.Consumer_First_Name_Stamp__c, 'campaign' => e.Promotional_Campaign__r.Name,
            'slug' => e.Promotional_Campaign__r.Hub_Slug__c, 'brandColor' => e.Promotional_Campaign__r.Hub_Brand_Color__c,
            'stage' => stage(e), 'entryStatus' => e.Entry_Status__c, 'eftStatus' => e.EFT_Status__c, 'invalidReason' => e.Invalid_Reason__c,
            'cashback' => e.Cashback_Amount__c, 'paymentPromise' => e.Promotional_Campaign__r.Hub_Payment_Promise__c,
            'serialDeadline' => e.Promotional_Campaign__r.Hub_Serial_Deadline__c, 'bankDeadline' => e.Promotional_Campaign__r.Hub_Bank_Deadline__c,
            'timezone' => e.Promotional_Campaign__r.Hub_Timezone__c, 'country' => country(e.Promotional_Campaign__r.Hub_Country__c),
            'brandName' => e.Promotional_Campaign__r.Hub_Brand_Name__c, 'spend' => e.Purchase_Price__c,
            'excludedSerialPrefixes' => e.Promotional_Campaign__r.Hub_Excluded_Serial_Prefixes__c,
            'mobileLast3' => last3(e.Consumer_Mobile_Stamp__c), 'emailMasked' => maskEmail(e.Consumer_Email_Stamp__c),
            'checklist' => new Map<String, Object>{ 'details' => true, 'invoice' => receiptOk, 'bank' => hasBank(e) },
            'bank' => hasBank(e) ? new Map<String, Object>{ 'name' => e.Consumer_Account_Name_Stamp__c, 'last3' => last3(accountNumber(e)) } : null,
            'products' => products, 'receipts' => receipts, 'timeline' => timeline, 'outstanding' => outstanding(e) };
    }

    /** Claimant-facing stage: awaiting | review | approved | paid | payment_failed | not_approved */
    public static String stage(Entry__c e) {
        if (e.Entry_Status__c == 'Invalid' || e.Entry_Status__c == 'Cancelled') return 'not_approved';
        if (e.EFT_Status__c == 'Fulfilled') return 'paid';
        if (e.EFT_Status__c == 'EFT Failed' || e.EFT_Status__c == 'EFT Fail' || e.EFT_Status__c == 'Reprocessing failed') return 'payment_failed';
        if (e.Entry_Status__c == 'Valid' || e.Entry_Status__c == 'Valid Updated' || e.Entry_Status__c == 'Validation Complete' || e.Entry_Status__c == 'Approved') return 'approved';
        if (e.Entry_Status__c == STATUS_COMPLETE || e.Entry_Status__c == 'Updated' || e.Entry_Status__c == 'To Review') return 'review';
        return 'awaiting';
    }

    // ---------------------------------------------------------------- actions
    public static Map<String, Object> addSerial(String token, Map<String, Object> req) {
        Entry__c e = byToken(token);
        guardOpen(e);
        Id productId = (Id) req(req, 'productId');
        Entry_Product__c target;
        for (Entry_Product__c p : e.Entry_Products__r) if (p.Id == productId) target = p;
        if (target == null) throw new HubException(404, 'Product not found on this claim.');
        String serial = req(req, 'serial').trim().toUpperCase(), pnc = String.valueOf(req.get('pnc') == null ? '' : req.get('pnc')).trim();
        checkSerial(serial, pnc, e.Id, target.Id, e.Promotional_Campaign__r.Hub_Excluded_Serial_Prefixes__c);
        target.Serial_Number__c = serial; target.Hub_Serial_Key__c = serial; target.PNC_Number__c = String.isBlank(pnc) ? null : pnc;
        target.Serial_Number_Status__c = 'I have received this product';
        try { update target; }
        catch (DmlException ex) {
            if (ex.getDmlType(0) == StatusCode.DUPLICATE_VALUE) throw new HubException(409, DUPLICATE_SERIAL).flag(e.Id, 'Needs review: duplicate serial', serial + ' was saved on another claim at the same moment');
            throw ex;
        }
        String label = target.Promotional_Product__r.Campaign_Products__r.Name__c + ' (' + target.Promotional_Product__r.Campaign_Products__r.Name + ')';
        ClaimHubLog.event(e.Id, 'Claimant', 'Serial added', label + ' ' + serial);
        Entry__c fresh = load(e.Id);
        recompute(fresh, 'Serial number for your ' + label);
        return view(token);
    }

    public static void checkSerial(String serial, String pnc, Id entryId) { checkSerial(serial, pnc, entryId, null, null); }
    public static void checkSerial(String serial, String pnc, Id entryId, Id productId) { checkSerial(serial, pnc, entryId, productId, null); }

    /** Format and terms rules that need no database lookup. */
    public static void checkSerialRules(String serial, String excludedPrefixes) {
        serial = serial == null ? '' : serial.trim().toUpperCase();
        if (!Pattern.matches('^[A-Z0-9]{8}$', serial)) throw new HubException(400, 'Serial numbers are 8 characters. Check the rating plate and try again.');
        if (String.isNotBlank(excludedPrefixes)) {
            List<String> bad = new List<String>();
            for (String px : excludedPrefixes.split(',')) if (String.isNotBlank(px)) bad.add(px.trim().toUpperCase());
            for (String px : bad) {
                if (serial.startsWith(px)) throw new HubException(400, 'Serial numbers starting with ' + joinOr(bad) +
                    ' belong to second-quality (T2) stock, which the terms exclude. Check you have copied it from the rating plate correctly.');
            }
        }
    }

    static String joinOr(List<String> xs) {
        if (xs.size() == 1) return xs[0];
        List<String> head = new List<String>(xs); String tail = head.remove(head.size() - 1);
        return String.join(head, ', ') + ' or ' + tail;
    }

    public static void checkSerial(String serial, String pnc, Id entryId, Id productId, String excludedPrefixes) {
        serial = serial == null ? '' : serial.trim().toUpperCase();
        try { checkSerialRules(serial, excludedPrefixes); }
        catch (HubException ex) {
            if (entryId != null && ex.getMessage().contains('T2')) ex.flag(entryId, 'Needs review: excluded serial', serial + ' (second-quality prefix)');
            throw ex;
        }
        if (String.isNotBlank(pnc) && !Pattern.matches('^[0-9]{9}$', pnc.trim())) throw new HubException(400, 'The PNC is the 9-digit product number on the same plate.');
        List<Entry_Product__c> dupes = [SELECT Id, Entry__c FROM Entry_Product__c WHERE Serial_Number__c = :serial AND Id != :productId LIMIT 1];
        if (!dupes.isEmpty()) {
            if (entryId != null && dupes[0].Entry__c == entryId) throw new HubException(409, 'You\'ve already used this serial number for another appliance on this claim. Each appliance has its own.');
            HubException dup = new HubException(409, DUPLICATE_SERIAL);
            if (entryId != null) dup.flag(entryId, 'Needs review: duplicate serial', serial + ' is already on claim ' + [SELECT Name FROM Entry__c WHERE Id = :dupes[0].Entry__c].Name);
            throw dup;
        }
    }

    public static Map<String, Object> addReceipt(String token, Map<String, Object> req) {
        Entry__c e = byToken(token);
        guardOpen(e);
        String b64 = req(req, 'base64');
        String mediaType = String.valueOf(req.get('contentType') == null ? 'image/jpeg' : req.get('contentType'));
        if (b64.length() > 2100000) throw new HubException(413, 'That file is too large. Try a photo instead of a scan.');
        if (ClaimHubLog.countToday(e.Id, 'Invoice uploaded') >= ClaimHubSettings.uploadDailyLimit()) throw new HubException(429, 'That is a lot of uploads for one day. Please try again tomorrow, or reply to any of our emails.');
        String fileKey = req.get('fileKey') == null ? null : String.valueOf(req.get('fileKey')).left(255);
        // Read the invoice first (callouts must happen before any database writes)
        Map<String, Object> ocr = ClaimHubVision.readInvoice(b64, mediaType, country(e.Promotional_Campaign__r.Hub_Country__c));
        List<String> checks = ClaimHubInvoice.invoiceChecks(e, ocr);
        String invoiceKey = ClaimHubInvoice.invoiceKey(ocr);
        Entry_Receipt__c other = invoiceKey == null ? null : ClaimHubInvoice.otherClaimWithInvoice(invoiceKey, e.Id);
        if (other != null) checks.add('Invoice ' + String.valueOf(ocr.get('invoiceNumber')).left(40) + ' is already on claim ' + other.Entry__r.Name);
        Blob data;
        try { data = EncodingUtil.base64Decode(b64); } catch (Exception ex) { throw new HubException(400, 'That file could not be read. Try again.'); }
        String fileName = String.valueOf(req.get('fileName') == null ? 'invoice.jpg' : req.get('fileName'));
        Entry_Receipt__c r = e.Entry_Receipts__r.isEmpty() ? new Entry_Receipt__c(Entry__c = e.Id, RecordTypeId = receiptRecordType([SELECT RecordTypeId FROM Entry__c WHERE Id = :e.Id].RecordTypeId)) : e.Entry_Receipts__r[0];
        if (ocr.get('invoiceNumber') != null) r.OCR_Invoice_Number__c = String.valueOf(ocr.get('invoiceNumber')).left(255);
        if (ocr.get('invoiceDate') != null) r.OCR_Invoice_Date__c = String.valueOf(ocr.get('invoiceDate')).left(255);
        if (ocr.get('store') != null || ocr.get('retailer') != null) {
            String rt = ocr.get('retailer') == null ? '' : String.valueOf(ocr.get('retailer')), st = ocr.get('store') == null ? '' : String.valueOf(ocr.get('store'));
            r.OCR_Store_Name__c = (st.containsIgnoreCase(rt) ? st : (rt + ' ' + st)).trim().left(255);
        }
        r.OCR_Processed__c = !ocr.containsKey('error');
        r.Hub_Invoice_Key__c = invoiceKey;
        r.Hub_Has_File__c = true;
        r.Hub_File_Key__c = fileKey;
        r.OCR_Status__c = ocr.containsKey('error') ? 'Not read' : (checks.isEmpty() ? 'Passed' : 'Check: ' + String.join(checks, '; ')).left(255);
        r.Validation_Notes__c = r.OCR_Status__c;
        if (r.Receipt_Date__c == null) r.Receipt_Date__c = dateOrNull(ocr.get('invoiceDate'));
        if (r.Receipt_Number__c == null && ocr.get('invoiceNumber') != null) r.Receipt_Number__c = String.valueOf(ocr.get('invoiceNumber')).left(80);
        if (r.Store_Name__c == null && r.OCR_Store_Name__c != null) r.Store_Name__c = r.OCR_Store_Name__c.left(255);
        upsert r;
        // Stored outside Salesforce when the web app sends a file key; otherwise kept as a Salesforce file
        if (fileKey == null) insert new ContentVersion(Title = fileName, PathOnClient = '/' + fileName, VersionData = data, FirstPublishLocationId = r.Id);
        ClaimHubLog.event(e.Id, 'Claimant', 'Invoice uploaded', fileName);
        if (other != null) ClaimHubLog.event(e.Id, 'System', 'Needs review: invoice on another claim', 'Same invoice as claim ' + other.Entry__r.Name);
        ClaimHubLog.event(e.Id, 'System', 'Invoice read automatically', r.OCR_Status__c);
        Entry__c fresh = load(e.Id);
        recompute(fresh, 'Your invoice');
        return view(token);
    }


    public static Map<String, Object> readPlate(String token, Map<String, Object> req) {
        Entry__c e = byToken(token);
        if (ClaimHubLog.countToday(e.Id, 'Scanned a rating plate') >= ClaimHubSettings.plateDailyLimit()) throw new HubException(429, 'That is a lot of scans for one day. Type the serial number in instead.');
        Map<String, Object> out = ClaimHubVision.readPlate(req(req, 'base64'), String.valueOf(req.get('contentType') == null ? 'image/jpeg' : req.get('contentType')));
        ClaimHubLog.event(e.Id, 'Claimant', 'Scanned a rating plate', out.containsKey('error') ? 'Not readable' : 'Read ' + out.get('serial'));
        return out;
    }

    public static Map<String, Object> requestCode(String token) {
        Entry__c e = byToken(token);
        guardBankChange(e);
        Integer recent = [SELECT COUNT() FROM Claim_OTP__c WHERE Entry__c = :e.Id AND CreatedDate = LAST_N_DAYS:1];
        if (recent >= 10) throw new HubException(429, 'Too many codes requested today. Please try again tomorrow.');
        String code = String.valueOf(100000 + Math.mod(Math.abs(Crypto.getRandomInteger()), 900000));
        insert new Claim_OTP__c(Entry__c = e.Id, Code_Hash__c = hash(e.Id + ':' + code), Expires__c = Datetime.now().addMinutes(10), Attempts__c = 0);
        ClaimHubNotifier.sendCode(e, code);
        ClaimHubLog.event(e.Id, 'Claimant', 'Security code sent', 'For a bank details change');
        return new Map<String, Object>{ 'sent' => true, 'channel' => 'email', 'to' => maskEmail(e.Consumer_Email_Stamp__c) };
    }

    public static Map<String, Object> changeBank(String token, Map<String, Object> req) {
        Entry__c e = byToken(token);
        guardBankChange(e);
        String code = req(req, 'code').replaceAll('\\s', '');
        List<Claim_OTP__c> codes = [SELECT Id, Code_Hash__c, Expires__c, Attempts__c FROM Claim_OTP__c
                                    WHERE Entry__c = :e.Id AND Used__c = false ORDER BY CreatedDate DESC LIMIT 1];
        if (codes.isEmpty() || codes[0].Expires__c < Datetime.now()) throw new HubException(401, 'That code has expired. Ask for a new one.');
        Claim_OTP__c otp = codes[0];
        if (otp.Attempts__c >= 5) throw new HubException(429, 'Too many attempts. Ask for a new code.');
        if (otp.Code_Hash__c != hash(e.Id + ':' + code)) {
            otp.Attempts__c += 1; update otp;
            ClaimHubLog.event(e.Id, 'Claimant', 'Wrong security code', null);
            throw new HubException(401, 'That code doesn\'t match. Check it and try again.');
        }
        otp.Used__c = true; update otp;

        Lead l = new Lead(Id = e.Customer__c);
        applyBank(l, req, e.Promotional_Campaign__r.Hub_Country__c);
        // The org only lets bank details change while EFT status is Pending (rule Cant_update_bank_details_after_EFT).
        // After a failed payment: back to Pending, change the details, then mark EFT Updated so the payments team re-sends.
        Boolean wasFailed = stage(e) == 'payment_failed' || e.EFT_Status__c == 'EFT Updated';
        ClaimHubEntryHandler.suppress = true;
        if (e.EFT_Status__c != 'Pending') update new Entry__c(Id = e.Id, EFT_Status__c = 'Pending');
        update l;
        Entry__c upd = new Entry__c(Id = e.Id, Hub_Last_Activity__c = Datetime.now());
        stampBank(upd, l);
        update upd;
        if (wasFailed) update new Entry__c(Id = e.Id, EFT_Status__c = 'EFT Updated');
        ClaimHubEntryHandler.suppress = false;
        ClaimHubLog.event(e.Id, 'Claimant', 'Bank details changed', 'Account ending ' + last3(l.Account_Number__c != null ? l.Account_Number__c : l.Bank_Account_Number__c));
        flagSharedBank(e.Id, e.Promotional_Campaign__c, l);
        Entry__c fresh = load(e.Id);
        ClaimHubNotifier.enqueueNow(fresh.Id, 'BANK_CHANGED');
        recompute(fresh, null);
        return view(token);
    }

    public static Map<String, Object> resendLink(Map<String, Object> req) {
        Promotional_Campaign__c c = campaignBySlug(req(req, 'slug'));
        String email = req(req, 'email').toLowerCase();
        List<Entry__c> es = [SELECT Id FROM Entry__c WHERE Promotional_Campaign__c = :c.Id AND Consumer_Email_Stamp__c = :email LIMIT 1];
        Integer sentToday = es.isEmpty() ? 0 : [SELECT COUNT() FROM Claim_Notification__c WHERE Entry__c = :es[0].Id AND Template_Key__c = 'LINK' AND CreatedDate = LAST_N_DAYS:1];
        if (!es.isEmpty() && sentToday < ClaimHubSettings.linkDailyLimit()) {
            ClaimAccessToken.ensureToken(es[0].Id);
            ClaimHubNotifier.enqueueNow(es[0].Id, 'LINK');
            ClaimHubLog.event(es[0].Id, 'Claimant', 'Asked for a fresh link', null);
        }
        // Same answer either way, so nobody can test which emails have claims.
        return new Map<String, Object>{ 'sent' => true };
    }


    // ---------------------------------------------------------------- status engine
    /** Moves an open claim between "awaiting details" and "complete, with team", and queues the right email. */
    public static void recompute(Entry__c e, String changeForSummary) {
        if (!OPEN_STATUSES.contains(e.Entry_Status__c)) {
            if (changeForSummary != null) ClaimHubNotifier.addToSummary(e.Id, changeForSummary);
            return;
        }
        List<String> out = outstanding(e);
        String target = out.isEmpty() ? STATUS_COMPLETE : STATUS_AWAITING;
        if (target != e.Entry_Status__c) {
            ClaimHubEntryHandler.suppress = true;
            update new Entry__c(Id = e.Id, Entry_Status__c = target, Hub_Last_Activity__c = Datetime.now());
            ClaimHubEntryHandler.suppress = false;
            if (target == STATUS_COMPLETE) {
                ClaimHubLog.event(e.Id, 'System', 'Complete, with team', 'All checklist items in');
                ClaimHubNotifier.mergePendingSummary(e.Id);
                ClaimHubNotifier.enqueueNow(e.Id, 'COMPLETE');
                return;
            }
        } else {
            update new Entry__c(Id = e.Id, Hub_Last_Activity__c = Datetime.now());
        }
        if (changeForSummary != null) ClaimHubNotifier.addToSummary(e.Id, changeForSummary);
    }


    /** Receipt record type that goes with a campaign's entry record type (same name + ' - Entry Receipt'). */
    static Id receiptRecordType(Id entryRecordTypeId) {
        if (entryRecordTypeId == null) return null;
        RecordType ert = [SELECT Name FROM RecordType WHERE Id = :entryRecordTypeId];
        List<RecordType> rts = [SELECT Id FROM RecordType WHERE SobjectType = 'Entry_Receipt__c' AND Name LIKE :(ert.Name + '%') LIMIT 1];
        return rts.isEmpty() ? null : rts[0].Id;
    }

    // ---------------------------------------------------------------- helpers
    /** Bank details can change before payment, or after a failed payment, but not while a payment is being made or once paid. */
    static void guardBankChange(Entry__c e) {
        String s = stage(e);
        if (s == 'paid' || s == 'not_approved') throw new HubException(409, 'This claim can no longer be changed.');
        if (s != 'payment_failed' && e.EFT_Status__c != null && e.EFT_Status__c != 'Pending' && e.EFT_Status__c != 'EFT Updated') {
            throw new HubException(409, 'Your payment is being processed, so the bank details can\'t change right now. If it doesn\'t go through we\'ll email you.');
        }
    }

    static void guardOpen(Entry__c e) {
        if (!OPEN_STATUSES.contains(e.Entry_Status__c)) throw new HubException(409, 'This claim is with our team and can\'t be changed here. Reply to any of our emails if something is wrong.');
    }

    static void applyBank(Lead l, Map<String, Object> bank, String countryCode) {
        String name = String.valueOf(bank.get('name') == null ? '' : bank.get('name')).trim();
        String bsb = String.valueOf(bank.get('bsb') == null ? '' : bank.get('bsb')).replaceAll('[^0-9]', '');
        String acct = String.valueOf(bank.get('account') == null ? '' : bank.get('account')).replaceAll('[^0-9]', '');
        if (String.isBlank(name)) throw new HubException(400, 'Add the name on the bank account.');
        if (country(countryCode) == 'NZ') {
            // NZ: bank (2) + branch (4) + account (7) + suffix (2 or 3) = 15 or 16 digits, e.g. 12-3456-7890123-00
            if (acct.length() != 15 && acct.length() != 16) throw new HubException(400, 'New Zealand account numbers have 15 or 16 digits, like 12-3456-7890123-00.');
            if (!NZ_BANKS.contains(acct.left(2))) throw new HubException(400, 'The first two digits (' + acct.left(2) + ') are not a New Zealand bank code. Check the account number.');
            l.Account_Name__c = name.left(30); l.Bank_Account_Number__c = acct; l.BSB__c = null; l.Account_Number__c = null;
            return;
        }
        if (bsb.length() != 6) throw new HubException(400, 'BSBs have 6 digits.');
        if (acct.length() < 6 || acct.length() > 10) throw new HubException(400, 'Australian account numbers have 6 to 10 digits.');
        l.Account_Name__c = name.left(30); l.BSB__c = bsb; l.Account_Number__c = acct;
    }

    /** New Zealand bank codes (first two digits of an account number). Source: en.wikipedia.org/wiki/New_Zealand_bank_account_number */
    static final Set<String> NZ_BANKS = new Set<String>{ '01','02','03','04','05','06','08','10','11','12','13','14','15','16','17','18','19','20','21','22','23','24','25','27','29','30','31','38','88' };

    static void stampBank(Entry__c e, Lead l) {
        e.Consumer_Account_Name_Stamp__c = l.Account_Name__c;
        e.Consumer_BSB_Stamp__c = l.BSB__c;
        e.Consumer_Account_Number_Stamp__c = l.Account_Number__c;
        e.Consumer_Bank_Account_Number__c = l.Bank_Account_Number__c;
    }

    public static final String DUPLICATE_EMAIL = 'There is already a claim with this email address. Use "Get my link" to open it.';
    public static final String DUPLICATE_SERIAL = 'This serial number is already on another claim. Our team has been told and will be in touch.';

    /** A positive amount from what the claimant typed ("$4,299.00", 4299), or null. */
    @TestVisible static Decimal price(Object v) {
        if (v == null) return null;
        String s = String.valueOf(v).replaceAll('[^0-9.]', '');
        if (String.isBlank(s)) return null;
        try { Decimal d = Decimal.valueOf(s); return d > 0 && d < 1000000 ? d.setScale(2, RoundingMode.HALF_UP) : null; } catch (Exception ex) { return null; }
    }

    static Id idOrNull(Object v) {
        try { return v == null ? null : Id.valueOf(String.valueOf(v)); } catch (Exception ex) { return null; }
    }

    static Date dateOrNull(Object v) {
        try { return v == null ? null : Date.valueOf(String.valueOf(v)); } catch (Exception ex) { return null; }
    }

    /** Inserts claim products; a serial already saved on another hub claim (even a moment ago) is refused by the unique key. */
    static void insertSerials(List<Entry_Product__c> eps) {
        try { insert eps; }
        catch (DmlException ex) {
            if (ex.getDmlType(0) == StatusCode.DUPLICATE_VALUE) throw new HubException(409, DUPLICATE_SERIAL);
            throw ex;
        }
    }

    /** Flags (does not refuse) a claim whose bank account is already on another claim in the same promotion. */
    static void flagSharedBank(Id entryId, Id campaignId, Lead l) {
        List<Entry__c> others;
        if (String.isNotBlank(l.Bank_Account_Number__c)) {
            others = [SELECT Name FROM Entry__c WHERE Promotional_Campaign__c = :campaignId AND Id != :entryId AND Consumer_Bank_Account_Number__c = :l.Bank_Account_Number__c LIMIT 3];
        } else if (String.isNotBlank(l.Account_Number__c)) {
            others = [SELECT Name FROM Entry__c WHERE Promotional_Campaign__c = :campaignId AND Id != :entryId AND Consumer_Account_Number_Stamp__c = :l.Account_Number__c AND Consumer_BSB_Stamp__c = :l.BSB__c LIMIT 3];
        }
        if (others == null || others.isEmpty()) return;
        List<String> names = new List<String>();
        for (Entry__c o : others) names.add(o.Name);
        ClaimHubLog.event(entryId, 'System', 'Needs review: bank account on another claim', 'Same account as ' + String.join(names, ', '));
    }

    static String req(Map<String, Object> m, String key) {
        Object v = m == null ? null : m.get(key);
        if (v == null || String.isBlank(String.valueOf(v))) throw new HubException(400, 'Missing ' + key);
        return String.valueOf(v);
    }

    public static String last3(String v) {
        if (String.isBlank(v)) return null;
        String d = v.replaceAll('[^0-9A-Za-z]', '');
        return d.length() <= 3 ? d : d.right(3);
    }

    public static String maskEmail(String email) {
        if (String.isBlank(email) || !email.contains('@')) return email;
        String local = email.substringBefore('@');
        return local.left(1) + '•••@' + email.substringAfter('@');
    }

    static String hash(String s) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(s)));
    }
}
