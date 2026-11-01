/**
 * Terms to campaign. Claude reads a promotion's terms and conditions and returns the campaign set-up as data
 * (dates, tiers, products, rules, deadlines) plus a list of problems it found in the terms. A person reviews that,
 * picks new dates if needed, and the builder creates the Promotional_Campaign__c, cashback tiers and product list.
 *
 * Deadlines after the promotion closes keep the same calendar offsets as the source terms ("as per normal"):
 * if the terms give claims close one month after the promotion, serials three months after and bank details four
 * months after, a new end date of 31 December gives 31 January, 31 March and 30 April.
 */
/* Staff-only: reachable from the Campaign from Terms screen, which needs the Claim Hub Admin permission set.
 * Creates the campaign, tiers and product records in system mode so a staff member without create rights on the
 * product master can still build a campaign. Record sharing still applies (with sharing). */
@SuppressWarnings('PMD.ApexCRUDViolation')
public with sharing class ClaimHubTerms {

    public class TermsException extends Exception {}

    static final String BRIEF =
        'You are setting up a cashback promotion in a claims system from its terms and conditions (above). ' +
        'Read every clause. Reply with ONLY one JSON object, no prose, with exactly these keys:\n' +
        '{\n' +
        ' "promotionName": string, "brand": string (consumer brand, e.g. AEG), "promoter": string (legal entity),\n' +
        ' "country": "AU"|"NZ", "currency": "AUD"|"NZD", "timezone": IANA zone for the stated times (e.g. Pacific/Auckland),\n' +
        ' "retailers": [string] (eligible retailer brands; [] if any retailer),\n' +
        ' "purchaseStart": "YYYY-MM-DD", "purchaseEnd": "YYYY-MM-DD" (the promotional period for purchases),\n' +
        ' "claimsOpen": "YYYY-MM-DDTHH:mm" local, "claimsClose": "YYYY-MM-DDTHH:mm" local (end of the redemption or claim period),\n' +
        ' "serialDeadline": "YYYY-MM-DDTHH:mm" local or null (last time to add serial numbers after claiming without them),\n' +
        ' "bankDeadline": "YYYY-MM-DDTHH:mm" local or null (last time to fix invalid bank details),\n' +
        ' "minProducts": integer, "maxProducts": integer or null, "minSpend": number or null, "singleTransaction": boolean,\n' +
        ' "tierBasis": "spend"|"quantity"|"percent" (percent = cashback is a share of the price paid),\n' +
        ' "tiers": [{"minSpend": number|null, "maxSpend": number|null, "minQty": integer|null, "maxQty": integer|null (null = no upper limit), "amount": number|null (fixed cashback), "percent": number|null (e.g. 15 for 15% of the price paid for the participating products)}],\n' +
        ' "maxCashback": number or null (cap per claim, if the terms set one),\n' +
        ' "mechanicSupported": boolean, "mechanicNote": string (one sentence on how the cashback is worked out; if not supported, why),\n' +
        ' "products": [{"model": string, "group": string (product group exactly as written), "category": one of "Oven","Cooking","Rangehoods","Dishwasher","Refrigeration","Laundry","Food Preservation","Other"}],\n' +
        ' "excludedSerialPrefixes": [string] (serial prefixes the terms exclude, e.g. second-quality stock),\n' +
        ' "onePerHousehold": boolean, "paymentMethod": string, "paymentPromise": string (time phrase only, e.g. "within 6 to 8 weeks", it is followed by "of approval" in messages),\n' +
        ' "claimantMustProvide": [string],\n' +
        ' "summary": string (120 to 200 words of plain English for a help assistant: who can claim, what to buy, where, how much, what to provide, exclusions. Do NOT include any dates. No em or en dashes),\n' +
        ' "issues": [{"clause": string (clause number or heading), "severity": "high"|"medium"|"low", "issue": string (one or two sentences: what is wrong and why it matters)}],\n' +
        ' "quotes": {"claimsClose": string, "serialDeadline": string, "bankDeadline": string} (the exact words each date came from, max 30 words each)\n' +
        '}\n' +
        'The claims system can run: a fixed amount by number of products; a fixed amount by spend band; a percentage of the price paid by number of products and/or spend band; ' +
        'with an optional minimum spend, cap per claim, retailer list and excluded serial prefixes. Anything else (different amounts per product, a choice of reward, gift with purchase, ' +
        'instant win, a prize draw) is "mechanicSupported": false. Each tier sets exactly one of amount or percent. ' +
        'Flag as an issue anything the cashback calculation needs that the terms leave undefined (e.g. what "price paid" includes, whether discounts or delivery count, whether there is a cap). ' +
        'List EVERY participating model in "products", exactly as written, once each. ' +
        'For "issues", look hard for: dates or deadlines that contradict each other (e.g. a stated number of days that does not match the stated date), ' +
        'periods referred to by the wrong name or date, product groups in the eligibility clause that do not match the model table, wrong or foreign legal entities, ' +
        'wrong time zone abbreviations, garbled or incomplete sentences, missing information a claims team needs, and anything else that would cause a dispute. ' +
        'When the terms contradict themselves, use the explicit calendar date for the field and record the contradiction as an issue. ' +
        'Never invent a value: use null and add an issue if something is missing.';

    // ------------------------------------------------------------------ Lightning (Trevor side)
    @AuraEnabled
    public static String readTerms(String termsText, String pdfBase64) {
        if (String.isBlank(termsText) && String.isBlank(pdfBase64)) throw new AuraHandledException('Paste the terms or attach a PDF.');
        try { return JSON.serialize(extract(termsText, pdfBase64)); }
        catch (Exception ex) { throw aura(ex); }
    }

    @AuraEnabled
    public static String schedule(String specJson, String newStart, String newEnd) {
        try { return JSON.serialize(scheduleFor((Map<String, Object>) JSON.deserializeUntyped(specJson), Date.valueOf(newStart), Date.valueOf(newEnd))); }
        catch (Exception ex) { throw aura(ex); }
    }

    static AuraHandledException aura(Exception ex) {
        AuraHandledException a = new AuraHandledException(ex.getMessage());
        a.setMessage(ex.getMessage());
        return a;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> templates() {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Promotional_Campaign__c c : [SELECT Id, Name, Job_Number__c FROM Promotional_Campaign__c
                                          WHERE Campaign_Type__c = 'Cashback' AND Entry_Record_Type_ID__c != null ORDER BY CreatedDate DESC LIMIT 200]) {
            out.add(new Map<String, Object>{ 'label' => c.Name + (c.Job_Number__c == null ? '' : ' (' + c.Job_Number__c + ')'), 'value' => c.Id });
        }
        return out;
    }

    @AuraEnabled
    public static Id create(String specJson, String optionsJson) {
        try { return build((Map<String, Object>) JSON.deserializeUntyped(specJson), (Map<String, Object>) JSON.deserializeUntyped(optionsJson)); }
        catch (Exception ex) { throw aura(ex); }
    }

    // ------------------------------------------------------------------ extraction
    public static Map<String, Object> extract(String termsText, String pdfBase64) {
        Map<String, Object> spec = ClaimHubVision.extract(BRIEF, termsText, pdfBase64);
        if (spec.containsKey('error')) throw new TermsException('Claude could not read the terms: ' + spec.get('error'));
        // Our own checks on top of Claude's reading
        List<Object> issues = spec.get('issues') == null ? new List<Object>() : (List<Object>) spec.get('issues');
        Set<String> seen = new Set<String>();
        List<Object> products = spec.get('products') == null ? new List<Object>() : (List<Object>) spec.get('products');
        for (Object o : products) {
            String m = String.valueOf(((Map<String, Object>) o).get('model')).trim().toUpperCase();
            if (!seen.add(m)) issues.add(issue('Products', 'medium', 'Model ' + m + ' is listed more than once.'));
        }
        if (products.isEmpty()) issues.add(issue('Products', 'high', 'No participating models were found.'));
        if (spec.get('serialDeadline') == null) issues.add(issue('Deadlines', 'high', 'No deadline for adding serial numbers was found.'));
        if (spec.get('bankDeadline') == null) issues.add(issue('Deadlines', 'medium', 'No deadline for correcting bank details was found.'));
        spec.put('issues', issues);
        spec.put('productCount', products.size());
        return spec;
    }

    static Map<String, Object> issue(String clause, String severity, String text) {
        return new Map<String, Object>{ 'clause' => clause, 'severity' => severity, 'issue' => text, 'source' => 'Builder check' };
    }

    // ------------------------------------------------------------------ dates
    /**
     * Moves the promotion to newStart..newEnd and carries every later deadline forward by the same number of calendar
     * months it sat after the original promotion close (falls back to the same number of days when the day of month differs).
     */
    public static Map<String, Object> scheduleFor(Map<String, Object> spec, Date newStart, Date newEnd) {
        if (newEnd < newStart) throw new TermsException('The end date is before the start date.');
        String tz = String.valueOf(spec.get('timezone') == null ? 'Australia/Sydney' : spec.get('timezone'));
        Date origEnd = Date.valueOf(String.valueOf(spec.get('purchaseEnd')));
        Map<String, Object> out = new Map<String, Object>{ 'timezone' => tz,
            'purchaseStart' => String.valueOf(newStart), 'purchaseEnd' => String.valueOf(newEnd),
            'claimsOpen' => String.valueOf(newStart) + 'T00:00' };
        for (String k : new List<String>{ 'claimsClose', 'serialDeadline', 'bankDeadline' }) {
            if (spec.get(k) == null) { out.put(k, null); continue; }
            String v = String.valueOf(spec.get(k));
            Date d = Date.valueOf(v.left(10));
            String hhmm = v.length() >= 16 ? v.substring(11, 16) : '23:59';
            Date nd;
            Integer months = origEnd.monthsBetween(d);
            if (d.day() == origEnd.day() || (isMonthEnd(origEnd) && isMonthEnd(d))) {
                nd = newEnd.addMonths(months);
                if (isMonthEnd(newEnd)) nd = Date.newInstance(nd.year(), nd.month(), Date.daysInMonth(nd.year(), nd.month()));
                out.put(k + 'Rule', months + ' month' + (months == 1 ? '' : 's') + ' after the promotion closes');
            } else {
                Integer days = origEnd.daysBetween(d);
                nd = newEnd.addDays(days);
                out.put(k + 'Rule', days + ' days after the promotion closes');
            }
            out.put(k, String.valueOf(nd) + 'T' + hhmm);
        }
        return out;
    }

    static Boolean isMonthEnd(Date d) { return d.day() == Date.daysInMonth(d.year(), d.month()); }

    /** "YYYY-MM-DDTHH:mm" wall-clock time in tz, as a real instant. */
    public static Datetime localToInstant(String local, String tz) {
        Date d = Date.valueOf(local.left(10));
        Integer hh = Integer.valueOf(local.substring(11, 13)), mm = Integer.valueOf(local.substring(14, 16));
        Datetime asGmt = Datetime.newInstanceGmt(d, Time.newInstance(hh, mm, 0, 0));
        TimeZone zone = TimeZone.getTimeZone(tz);
        Datetime guess = asGmt.addSeconds(-zone.getOffset(asGmt) / 1000);
        return asGmt.addSeconds(-zone.getOffset(guess) / 1000); // second pass settles daylight-saving edges
    }

    // ------------------------------------------------------------------ build
    /**
     * options: name, slug, start (YYYY-MM-DD), end, brand (subdomain on the hub root domain; sets the base URL and prefixes the slug),
     * baseUrl (only when no brand is given), sender, brandColor, headline, termsUrl, enable (Boolean),
     * accountId (optional), compareCampaignId (optional: a past campaign whose product list is checked against the terms),
     * entryRecordTypeId / productRecordTypeId (optional: only for campaigns that must also run on the old claim forms).
     * By default hub campaigns share the Claim Hub record types.
     */
    public static Id build(Map<String, Object> spec, Map<String, Object> o) {
        Date newStart = Date.valueOf(str(o, 'start')), newEnd = Date.valueOf(str(o, 'end'));
        Map<String, Object> sch = scheduleFor(spec, newStart, newEnd);
        String tz = String.valueOf(sch.get('timezone'));
        String slug = str(o, 'slug').toLowerCase().trim();
        // Brand subdomain (decisions.md #16): the campaign is served at https://brand.root/slug-without-brand
        String brandKey = o.get('brand') == null ? '' : String.valueOf(o.get('brand')).toLowerCase().trim();
        String baseUrl = o.get('baseUrl') == null || String.isBlank(String.valueOf(o.get('baseUrl'))) ? null : String.valueOf(o.get('baseUrl'));
        if (String.isNotBlank(brandKey)) {
            if (!Pattern.matches('^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$', brandKey)) throw new TermsException('The brand web address can use lower-case letters, numbers and dashes only, up to 32 characters.');
            if (ClaimHubSettings.rootDomain() == null) throw new TermsException('Set the hub root domain in Claim Hub Settings before building a campaign on a brand address.');
            if (!slug.startsWith(brandKey + '-')) slug = brandKey + '-' + slug;
            baseUrl = 'https://' + brandKey + '.' + ClaimHubSettings.rootDomain();
        }
        if (!Pattern.matches('^[a-z0-9-]{3,60}$', slug)) throw new TermsException('The web address name can use lower-case letters, numbers and dashes only.');
        if (![SELECT Id FROM Promotional_Campaign__c WHERE Hub_Slug__c = :slug LIMIT 1].isEmpty()) throw new TermsException('Web address name ' + slug + ' is already used.');
        if (spec.get('mechanicSupported') == false) throw new TermsException('The hub cannot run this cashback mechanic yet: ' + spec.get('mechanicNote'));

        String compareId = o.get('compareCampaignId') != null ? String.valueOf(o.get('compareCampaignId')) : (o.get('templateCampaignId') == null ? null : String.valueOf(o.get('templateCampaignId')));
        Promotional_Campaign__c t = String.isBlank(compareId) ? null : [SELECT Id, Account__c, Campaign_Email_Address__c, Advertiser_URL__c FROM Promotional_Campaign__c WHERE Id = :compareId];

        // Record types: shared by default. Own set only when asked (old claim forms need the record type to find the campaign).
        Id entryRt = o.get('entryRecordTypeId') == null ? null : (Id) String.valueOf(o.get('entryRecordTypeId'));
        Id productRt = o.get('productRecordTypeId') == null ? null : (Id) String.valueOf(o.get('productRecordTypeId'));
        if (entryRt != null && ![SELECT Id FROM Promotional_Campaign__c WHERE Entry_Record_Type_ID__c = :entryRt LIMIT 1].isEmpty()) {
            throw new TermsException('That record type already belongs to another campaign.');
        }

        // Client account
        Id accountId = o.get('accountId') == null ? null : (Id) String.valueOf(o.get('accountId'));
        if (accountId == null && t != null) accountId = t.Account__c;
        if (accountId == null) {
            String brand = String.valueOf(spec.get('brand') == null ? '' : spec.get('brand'));
            List<Account> accs = String.isBlank(brand) ? new List<Account>() : [SELECT Id FROM Account WHERE Name = :brand OR Name LIKE :(brand + '%') ORDER BY CreatedDate LIMIT 1];
            if (accs.isEmpty()) { Account a = new Account(Name = String.isBlank(brand) ? String.valueOf(spec.get('promoter')) : brand); insert a; accountId = a.Id; }
            else accountId = accs[0].Id;
        }

        String countryCode = String.valueOf(spec.get('country') == null ? 'AU' : spec.get('country'));
        List<Object> retailers = spec.get('retailers') == null ? new List<Object>() : (List<Object>) spec.get('retailers');
        List<String> rs = new List<String>(); for (Object r : retailers) rs.add(String.valueOf(r));
        List<Object> excl = spec.get('excludedSerialPrefixes') == null ? new List<Object>() : (List<Object>) spec.get('excludedSerialPrefixes');
        List<String> xs = new List<String>(); for (Object x : excl) xs.add(String.valueOf(x).trim().toUpperCase());

        Promotional_Campaign__c c = new Promotional_Campaign__c(
            Name = str(o, 'name').left(80), Account__c = accountId, Active__c = true, Status__c = 'Active', Campaign_Type__c = 'Cashback',
            Entry_Record_Type_ID__c = entryRt, First_Product_RecordType_ID__c = productRt, Next_Product_RecordType_ID__c = productRt,
            Is_Receipt_Required__c = true, Campaign_Email_Address__c = o.get('sender') == null ? (t == null ? null : t.Campaign_Email_Address__c) : String.valueOf(o.get('sender')),
            Advertiser_URL__c = t == null ? null : t.Advertiser_URL__c,
            Minimum_Number_Of_Products__c = num(spec.get('minProducts')), Maximum_Number_Of_Products__c = num(spec.get('maxProducts')) == null ? 10 : num(spec.get('maxProducts')),
            Maximum_Number_Of_Receipts__c = spec.get('singleTransaction') == true ? 1 : 10,
            Sales_From__c = newStart, Sales_To__c = newEnd,
            Date_start__c = localToInstant(String.valueOf(sch.get('claimsOpen')), tz),
            Date_end__c = sch.get('claimsClose') == null ? null : localToInstant(String.valueOf(sch.get('claimsClose')), tz),
            Hub_Serial_Deadline__c = sch.get('serialDeadline') == null ? null : localToInstant(String.valueOf(sch.get('serialDeadline')), tz),
            Hub_Bank_Deadline__c = sch.get('bankDeadline') == null ? null : localToInstant(String.valueOf(sch.get('bankDeadline')), tz),
            Use_Email_For_Duplicate_Validation__c = true,
            Duplicate_Message__c = spec.get('onePerHousehold') == true ? 'Only one claim per person or household is permitted.' : null,
            Purchase_Requirement__c = ('Built from terms by the claim hub builder. ' + (o.get('note') == null ? '' : String.valueOf(o.get('note')))).left(255),
            Hub_Enabled__c = o.get('enable') == true, Hub_Slug__c = slug,
            Hub_Headline__c = o.get('headline') == null ? null : String.valueOf(o.get('headline')),
            Hub_Brand_Color__c = o.get('brandColor') == null ? '#111111' : String.valueOf(o.get('brandColor')),
            Hub_Brand_Name__c = spec.get('brand') == null ? null : String.valueOf(spec.get('brand')),
            Hub_Terms_URL__c = o.get('termsUrl') == null ? null : String.valueOf(o.get('termsUrl')),
            Hub_Base_URL__c = baseUrl,
            Hub_Sender_Address__c = o.get('sender') == null ? (t == null ? null : t.Campaign_Email_Address__c) : String.valueOf(o.get('sender')),
            Hub_Payment_Promise__c = spec.get('paymentPromise') == null ? null : String.valueOf(spec.get('paymentPromise')).left(255),
            Hub_Timezone__c = tz, Hub_Country__c = countryCode,
            Hub_Retailers__c = rs.isEmpty() ? null : String.join(rs, ', ').left(255),
            Hub_Excluded_Serial_Prefixes__c = xs.isEmpty() ? null : String.join(xs, ','),
            Hub_Min_Spend__c = num(spec.get('minSpend')), Hub_Max_Cashback__c = num(spec.get('maxCashback')),
            Hub_Single_Transaction__c = spec.get('singleTransaction') == true,
            Hub_Collect_Address__c = o.get('collectAddress') == true, Hub_Collect_Store__c = o.get('collectStore') == true,
            Hub_Stores__c = o.get('stores') == null || String.isBlank(String.valueOf(o.get('stores'))) ? null : String.valueOf(o.get('stores')).left(32768),
            Hub_Terms_Summary__c = spec.get('summary') == null ? null : String.valueOf(spec.get('summary')),
            Hub_Spec__c = JSON.serializePretty(new Map<String, Object>{ 'fromTerms' => spec, 'schedule' => sch }).left(131072),
            Hub_Terms_Issues__c = issuesText(spec).left(32768));
        c.Final_Submission_Date__c = c.Hub_Serial_Deadline__c == null ? null : c.Hub_Serial_Deadline__c.dateGmt();
        insert c;

        // Cashback tiers: fixed amount or a percentage of what was paid, by number of appliances and/or spend band
        List<Cashback_Range__c> ranges = new List<Cashback_Range__c>();
        String basis = String.valueOf(spec.get('tierBasis'));
        String cur = countryCode == 'NZ' ? 'NZ$' : '$';
        for (Object x : (List<Object>) spec.get('tiers')) {
            Map<String, Object> tier = (Map<String, Object>) x;
            Decimal mn = num(tier.get('minSpend')), mx = num(tier.get('maxSpend')), amt = num(tier.get('amount')), pct = num(tier.get('percent'));
            Decimal q = num(tier.get('minQty')) == null ? num(spec.get('minProducts')) : num(tier.get('minQty'));
            Decimal qx = num(tier.get('maxQty'));
            String who = (mn != null && mn > 0) ? 'Spend ' + cur + mn.format() + (mx == null ? '+' : ' to ' + cur + mx.format())
                       : (q == null ? '' : q.intValue() + (qx == null ? '+' : (qx == q ? '' : ' to ' + qx.intValue())) + ' products');
            String what = pct != null ? pct.stripTrailingZeros().toPlainString() + '% cashback' : cur + (amt == null ? '?' : amt.format()) + ' cashback';
            ranges.add(new Cashback_Range__c(Name = (who + ': ' + what).left(80), Promotional_Campaign__c = c.Id,
                Cashback_Type__c = (mn != null && mn > 0 && basis != 'quantity') ? 'Product Value' : 'Product Quantity',
                Minimum_Value__c = mn, Maximum_Value__c = mx, Minimum_Quantity__c = q, Maximum_Quantity__c = qx,
                Cashback_Value__c = pct != null ? null : amt, Percentage__c = pct));
        }
        insert ranges;

        // Products: reuse the product master where the model already exists, otherwise add it
        Map<String, Object> wanted = new Map<String, Object>();
        for (Object x : (List<Object>) spec.get('products')) {
            Map<String, Object> p = (Map<String, Object>) x;
            wanted.put(String.valueOf(p.get('model')).trim().toUpperCase(), p);
        }
        Map<String, Campaign_Product__c> master = new Map<String, Campaign_Product__c>();
        for (Campaign_Product__c cp : [SELECT Id, Name FROM Campaign_Product__c WHERE Name IN :wanted.keySet() ORDER BY CreatedDate]) {
            if (!master.containsKey(cp.Name.toUpperCase())) master.put(cp.Name.toUpperCase(), cp);
        }
        List<Campaign_Product__c> fresh = new List<Campaign_Product__c>();
        for (String m : wanted.keySet()) {
            if (master.containsKey(m)) continue;
            Map<String, Object> p = (Map<String, Object>) wanted.get(m);
            Campaign_Product__c cp = new Campaign_Product__c(Name = m, Name__c = String.valueOf(p.get('group')).left(255),
                Category__c = String.valueOf(p.get('category')), Manufacturer_Client__c = accountId);
            fresh.add(cp); master.put(m, cp);
        }
        insert fresh;
        List<Promotional_Product__c> links = new List<Promotional_Product__c>();
        for (String m : wanted.keySet()) links.add(new Promotional_Product__c(Promotional_Campaign__c = c.Id, Campaign_Products__c = master.get(m).Id));
        insert links;

        // Cross-check the terms against the product list on a past campaign, when one is given
        List<String> drift = t == null ? new List<String>() : productDrift(t.Id, wanted.keySet());
        if (!drift.isEmpty()) {
            c.Hub_Terms_Issues__c = (c.Hub_Terms_Issues__c + '\n' + String.join(drift, '\n')).trim().left(32768);
            update new Promotional_Campaign__c(Id = c.Id, Hub_Terms_Issues__c = c.Hub_Terms_Issues__c);
        }
        return c.Id;
    }

    /** Models on the template campaign but not in the terms, and the other way round. */
    public static List<String> productDrift(Id templateId, Set<String> inTerms) {
        Set<String> onTemplate = new Set<String>();
        for (Promotional_Product__c pp : [SELECT Campaign_Products__r.Name FROM Promotional_Product__c WHERE Promotional_Campaign__c = :templateId]) {
            onTemplate.add(pp.Campaign_Products__r.Name.trim().toUpperCase());
        }
        List<String> out = new List<String>();
        if (onTemplate.isEmpty()) return out;
        List<String> extra = new List<String>(), missing = new List<String>();
        for (String m : onTemplate) if (!inTerms.contains(m)) extra.add(m);
        for (String m : inTerms) if (!onTemplate.contains(m)) missing.add(m);
        extra.sort(); missing.sort();
        if (!extra.isEmpty()) out.add('[HIGH] Products: ' + String.join(extra, ', ') + ' set up on the template campaign but not in the terms. Claimants could be accepted for a model the terms do not cover.');
        if (!missing.isEmpty()) out.add('[HIGH] Products: ' + String.join(missing, ', ') + ' in the terms but not on the template campaign.');
        return out;
    }

    public static String issuesText(Map<String, Object> spec) {
        List<String> lines = new List<String>();
        if (spec.get('issues') == null) return '';
        for (Object x : (List<Object>) spec.get('issues')) {
            Map<String, Object> i = (Map<String, Object>) x;
            lines.add('[' + String.valueOf(i.get('severity')).toUpperCase() + '] ' + i.get('clause') + ': ' + i.get('issue'));
        }
        return String.join(lines, '\n');
    }

    static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v == null || String.isBlank(String.valueOf(v))) throw new TermsException('Missing ' + k);
        return String.valueOf(v);
    }

    static Decimal num(Object v) {
        if (v == null) return null;
        try { return Decimal.valueOf(String.valueOf(v)); } catch (Exception ex) { return null; }
    }
}
