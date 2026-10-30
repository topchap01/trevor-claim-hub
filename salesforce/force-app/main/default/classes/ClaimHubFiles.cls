/**
 * Invoice files kept outside Salesforce (private Vercel Blob storage), so claim photos do not use org file storage.
 * Staff open a file through a short-lived ticket: Salesforce issues a random ticket and keeps only its hash;
 * the web app's /api/file route swaps the ticket for the file's storage key through the claim hub API and streams the file.
 * Files stored the old way (Salesforce Files) open in Salesforce as before.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubFiles {

    public static final Integer TICKET_MINUTES = 10;

    /** A link staff can open for the claim's invoice, or null if there is no file. */
    public static String invoiceLink(Id entryId) {
        List<Entry_Receipt__c> rs = [SELECT Id, Hub_File_Key__c, Entry__r.Promotional_Campaign__r.Hub_Base_URL__c FROM Entry_Receipt__c
                                     WHERE Entry__c = :entryId ORDER BY LastModifiedDate DESC LIMIT 1];
        if (rs.isEmpty()) return null;
        Entry_Receipt__c r = rs[0];
        if (String.isBlank(r.Hub_File_Key__c)) {
            List<ContentDocumentLink> docs = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :r.Id ORDER BY SystemModstamp DESC LIMIT 1];
            return docs.isEmpty() ? null : '/lightning/r/ContentDocument/' + docs[0].ContentDocumentId + '/view';
        }
        String base = String.isNotBlank(ClaimHubSettings.fileBaseUrl()) ? ClaimHubSettings.fileBaseUrl() : r.Entry__r.Promotional_Campaign__r.Hub_Base_URL__c;
        if (String.isBlank(base)) throw new ClaimHubService.HubException(500, 'No web app address is set for invoice links.');
        String ticket = ClaimAccessToken.newToken();
        update new Entry_Receipt__c(Id = r.Id, Hub_File_Ticket_Hash__c = hash(ticket), Hub_File_Ticket_Expires__c = Datetime.now().addMinutes(TICKET_MINUTES));
        ClaimHubLog.event(entryId, 'Team', 'Internal: invoice opened', UserInfo.getName());
        return base.removeEnd('/') + '/api/file?t=' + ticket;
    }

    /** API: the storage key for a valid ticket. Unknown and expired tickets look the same. */
    public static Map<String, Object> resolve(String ticket) {
        if (String.isBlank(ticket) || ticket.length() < 40 || ticket.length() > 64) throw new ClaimHubService.HubException(404, 'Not found');
        List<Entry_Receipt__c> rs = [SELECT Hub_File_Key__c, Hub_File_Ticket_Expires__c FROM Entry_Receipt__c WHERE Hub_File_Ticket_Hash__c = :hash(ticket) LIMIT 1];
        if (rs.isEmpty() || rs[0].Hub_File_Ticket_Expires__c == null || rs[0].Hub_File_Ticket_Expires__c < Datetime.now() || String.isBlank(rs[0].Hub_File_Key__c)) {
            throw new ClaimHubService.HubException(404, 'Not found');
        }
        return new Map<String, Object>{ 'key' => rs[0].Hub_File_Key__c };
    }

    static String hash(String s) { return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(s))); }
}
