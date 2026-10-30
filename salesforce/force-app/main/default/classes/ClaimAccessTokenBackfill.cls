/**
 * Gives existing claims a random link code and rebuilds their resume/status links.
 * Run per campaign:  Database.executeBatch(new ClaimAccessTokenBackfill('a08...'), 200);
 * Only touches Access_Token__c, Resume_Url__c and Status_URL__c. Status fields are not changed,
 * so status-change email rules (ISNEW / ISCHANGED) do not fire.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimAccessTokenBackfill implements Database.Batchable<SObject> {
    private final Id campaignId;
    public ClaimAccessTokenBackfill(Id campaignId) { this.campaignId = campaignId; }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Promotional_Campaign__c, Access_Token__c FROM Entry__c
            WHERE Promotional_Campaign__c = :campaignId AND Access_Token__c = null]);
    }

    public void execute(Database.BatchableContext bc, List<Entry__c> scope) {
        Map<Id, Promotional_Campaign__c> campaigns = new Map<Id, Promotional_Campaign__c>(
            [SELECT Id, Edit_URL__c, Status_URL__c FROM Promotional_Campaign__c WHERE Id = :campaignId]);
        ClaimAccessToken.stamp(scope, campaigns);
        update scope;
    }

    public void finish(Database.BatchableContext bc) {}
}
