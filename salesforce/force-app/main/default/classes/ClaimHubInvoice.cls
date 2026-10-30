/**
 * Checks an invoice, as read by Claude, against the claim and the promotion's rules. Problems are listed in plain English
 * for the team; nothing here refuses a claim on its own.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubInvoice {

    /** Plain-English problems found on the invoice. Empty list = all checks passed. */
    public static List<String> invoiceChecks(Entry__c e, Map<String, Object> ocr) {
        List<String> issues = new List<String>();
        if (ocr.containsKey('error')) return new List<String>{ 'We could not read the invoice automatically, so our team will check it' };
        if (ocr.get('isInvoice') == false) issues.add('This does not look like an invoice');
        Promotional_Campaign__c c = [SELECT Sales_From__c, Sales_To__c, Hub_Retailers__c, Hub_Min_Spend__c, Hub_Country__c FROM Promotional_Campaign__c WHERE Id = :e.Promotional_Campaign__c];
        try {
            Date d = ocr.get('invoiceDate') == null ? null : Date.valueOf(String.valueOf(ocr.get('invoiceDate')));
            if (d == null) issues.add('Invoice date not readable');
            else if ((c.Sales_From__c != null && d < c.Sales_From__c) || (c.Sales_To__c != null && d > c.Sales_To__c)) issues.add('Invoice date ' + d.format() + ' is outside the promotion dates');
        } catch (Exception ex) { issues.add('Invoice date not readable'); }
        String lines = norm(JSON.serialize(ocr.get('lines')));
        Decimal invoiceSpend = 0; Boolean pricesRead = true;
        for (Entry_Product__c p : e.Entry_Products__r) {
            String model = norm(p.Promotional_Product__r.Campaign_Products__r.Name);
            if (!lines.contains(model)) { issues.add(p.Promotional_Product__r.Campaign_Products__r.Name + ' not found on invoice'); pricesRead = false; continue; }
            Decimal linePrice = priceOnInvoice(ocr, model);
            if (linePrice == null) pricesRead = false; else invoiceSpend += linePrice;
        }
        // Retailer
        if (String.isNotBlank(c.Hub_Retailers__c)) {
            String seen = norm(String.valueOf(ocr.get('retailer')) + ' ' + String.valueOf(ocr.get('store')));
            Boolean ok = false;
            for (String r : c.Hub_Retailers__c.split(',')) if (String.isNotBlank(r) && seen.contains(norm(r))) ok = true;
            if (!ok) issues.add('Retailer on the invoice (' + (ocr.get('retailer') == null ? 'not readable' : String.valueOf(ocr.get('retailer'))) + ') is not ' + c.Hub_Retailers__c);
        }
        // Name on invoice must match the claim
        String onInvoice = ocr.get('customerName') == null ? null : String.valueOf(ocr.get('customerName'));
        if (String.isBlank(onInvoice)) issues.add('Customer name not readable on invoice');
        else if (!norm(onInvoice).contains(norm(e.Consumer_Last_Name_Stamp__c))) issues.add('Name on invoice (' + onInvoice.left(60) + ') does not match the claim');
        // Paid in full
        try {
            Object bd = ocr.get('balanceDue');
            if (bd != null && Decimal.valueOf(String.valueOf(bd)) > 0) issues.add('Invoice shows a balance owing of ' + ClaimHubService.money(Decimal.valueOf(String.valueOf(bd)), c.Hub_Country__c));
        } catch (Exception ex) {
            issues.add('Balance owing not readable');
        }
        // Spend
        if (pricesRead && invoiceSpend > 0) {
            if (c.Hub_Min_Spend__c != null && invoiceSpend < c.Hub_Min_Spend__c) issues.add('Participating appliances on the invoice total ' + ClaimHubService.money(invoiceSpend, c.Hub_Country__c) + ', under the ' + ClaimHubService.money(c.Hub_Min_Spend__c, c.Hub_Country__c) + ' minimum');
            if (e.Purchase_Price__c != null && (invoiceSpend - e.Purchase_Price__c).abs() > 1) issues.add('Claimed spend ' + ClaimHubService.money(e.Purchase_Price__c, c.Hub_Country__c) + ' differs from invoice ' + ClaimHubService.money(invoiceSpend, c.Hub_Country__c));
        }
        return issues;
    }

    static Decimal priceOnInvoice(Map<String, Object> ocr, String normModel) {
        Object ls = ocr.get('lines');
        if (!(ls instanceof List<Object>)) return null;
        for (Object o : (List<Object>) ls) {
            Map<String, Object> ln = (Map<String, Object>) o;
            if (norm(String.valueOf(ln.get('model')) + ' ' + String.valueOf(ln.get('description'))).contains(normModel)) {
                try { return ln.get('price') == null ? null : Decimal.valueOf(String.valueOf(ln.get('price'))); } catch (Exception ex) { return null; }
            }
        }
        return null;
    }

    /** Model codes compared without spaces or dashes, and with look-alike characters treated the same (O/0, I/1, S/5). */
    static String norm(String v) {
        return v == null ? '' : v.toUpperCase().replaceAll('[^A-Z0-9]', '').replace('O', '0').replace('I', '1').replace('S', '5');
    }

    /** Retailer and invoice number, normalised, or null if the invoice number was not read. */
    public static String invoiceKey(Map<String, Object> ocr) {
        if (ocr == null || ocr.containsKey('error') || ocr.get('invoiceNumber') == null) return null;
        String num = norm(String.valueOf(ocr.get('invoiceNumber')));
        if (num.length() < 3) return null;
        return (norm(String.valueOf(ocr.get('retailer'))).left(40) + ':' + num).left(120);
    }

    public static Entry_Receipt__c otherClaimWithInvoice(String invoiceKey, Id entryId) {
        List<Entry_Receipt__c> rs = [SELECT Entry__c, Entry__r.Name FROM Entry_Receipt__c WHERE Hub_Invoice_Key__c = :invoiceKey AND Entry__c != :entryId LIMIT 1];
        return rs.isEmpty() ? null : rs[0];
    }
}
