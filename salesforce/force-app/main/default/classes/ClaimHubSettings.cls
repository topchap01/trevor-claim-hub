/**
 * Operating settings for the claim hub, read from the Claim Hub Settings custom setting with a safe default for every value,
 * so an org with no setting record still runs. Tests can override any value through `current`.
 */
public without sharing class ClaimHubSettings {

    @TestVisible static Claim_Hub_Settings__c current;

    static Claim_Hub_Settings__c s() {
        if (current == null) current = Claim_Hub_Settings__c.getOrgDefaults();
        return current == null ? new Claim_Hub_Settings__c() : current;
    }

    static Integer num(Decimal v, Integer fallback) { return v == null || v < 0 ? fallback : v.intValue(); }

    public static Integer debounceMinutes() { return num(s().Debounce_Minutes__c, 10); }
    public static Integer chatDailyLimit() { return num(s().Chat_Daily_Limit__c, 40); }
    public static Integer linkDailyLimit() { return num(s().Link_Daily_Limit__c, 3); }
    public static Integer uploadDailyLimit() { return num(s().Upload_Daily_Limit__c, 10); }
    public static Integer plateDailyLimit() { return num(s().Plate_Daily_Limit__c, 30); }
    public static Integer claimsPerIpDaily() { return num(s().Claims_Per_IP_Daily__c, 20); }
    /** Claims from one connection in a day at which each new one is flagged for review. */
    public static final Integer IP_FLAG_AT = 3;
    public static String alertEmail() { return s().Alert_Email__c; }
    public static String model() { return String.isBlank(s().Model__c) ? 'claude-sonnet-4-6' : s().Model__c; }
    public static String fileBaseUrl() { return s().File_Base_URL__c; }
}
