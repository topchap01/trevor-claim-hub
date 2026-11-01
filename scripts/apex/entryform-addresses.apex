// Wizard only. decisions.md #16: sandbox campaigns live at https://<brand>.test.entryform.claims/<campaign>.
// Sets the hub root domain and moves the three demo campaigns to their brand addresses. Safe to run again.
// Fold into wizard-setup.apex once that file is on main.
Claim_Hub_Settings__c s = Claim_Hub_Settings__c.getOrgDefaults();
if (s == null || s.Id == null) s = new Claim_Hub_Settings__c(SetupOwnerId = UserInfo.getOrganizationId());
s.Hub_Root_Domain__c = 'test.entryform.claims';
upsert s;

Map<String, String> bases = new Map<String, String>{
    'aeg-nz-cashback' => 'https://aeg.test.entryform.claims',
    'electrolux-cross-category' => 'https://electrolux.test.entryform.claims',
    'electrolux-kitchen-refresh' => 'https://electrolux.test.entryform.claims'
};
List<Promotional_Campaign__c> cs = [SELECT Id, Hub_Slug__c, Hub_Base_URL__c FROM Promotional_Campaign__c WHERE Hub_Slug__c IN :bases.keySet()];
for (Promotional_Campaign__c c : cs) c.Hub_Base_URL__c = bases.get(c.Hub_Slug__c);
update cs;
for (Promotional_Campaign__c c : cs) System.debug('address ' + ClaimHubSettings.pageUrl(c.Hub_Base_URL__c, c.Hub_Slug__c));
System.debug('root=' + ClaimHubSettings.rootDomain() + ' campaigns moved=' + cs.size());
