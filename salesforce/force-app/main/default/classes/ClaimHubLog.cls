/**
 * Claim audit trail (Claim_Event__c: who did what to a claim, shown to staff and, in part, to the claimant)
 * and technical error logging (Nebula Logger, already installed in the org).
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubLog {

    public static void event(Id entryId, String actor, String action, String detail) {
        insert build(entryId, actor, action, detail);
    }

    public static Claim_Event__c build(Id entryId, String actor, String action, String detail) {
        return new Claim_Event__c(Entry__c = entryId, Actor__c = actor, Action__c = action == null ? null : action.left(80),
                                  Detail__c = detail == null ? null : detail.left(255));
    }

    /** Count of a claim's events with this action since midnight (UTC), for per-claim daily limits. */
    public static Integer countToday(Id entryId, String action) {
        return [SELECT COUNT() FROM Claim_Event__c WHERE Entry__c = :entryId AND Action__c = :action AND CreatedDate = TODAY];
    }

    /** Records an unexpected failure with Nebula Logger and returns the log's transaction id, for support to look up. */
    public static String error(String message, Exception ex) {
        try {
            Logger.error(message, ex);
            Logger.saveLog();
            return Logger.getTransactionId();
        } catch (Exception loggingFailed) {
            System.debug(LoggingLevel.ERROR, message + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
            return null;
        }
    }

    public static void warn(String message) {
        try { Logger.warn(message); Logger.saveLog(); } catch (Exception loggingFailed) { System.debug(LoggingLevel.WARN, message); }
    }
}
