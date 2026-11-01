// Brings the Wizard sandbox's demo campaigns to the state the docs describe. Safe to run again.
// Run by the "Deploy to Wizard" GitHub job after each deploy, or: sf apex run -o wizard -f scripts/apex/wizard-setup.apex
// Sandbox only: stops in any org that is not a sandbox.
System.assert([SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox, 'wizard-setup.apex runs in sandboxes only.');

// Electrolux and AEG campaigns ask for the postal address and the store (decisions.md #13).
// Store lists: the retailers used on the 2026 one-off Electrolux cashbacks in production (AU Cross Category, NZ Kitchen),
// spelt as Entry_Receipt__c.Retailer__c holds them. "Other" is added by the hub.
Map<String, String> storesByCountry = new Map<String, String>{
    'AU' => 'Harvey Norman\nThe Good Guys\nBing Lee\nE & S Trading\nAPPLIANCES ONLINE\nRetravision\nJoyce Mayne\nBetta Electrical\nWinning Appliances\nDomayne\nJB Hi-Fi',
    'NZ' => 'Harvey Norman\nNoel Leeming\nHEATHCOTES\n100% APPLIANCES\nAPPLIANCEPLUS' };
List<Promotional_Campaign__c> cs = [SELECT Id, Hub_Slug__c, Hub_Country__c FROM Promotional_Campaign__c
                                    WHERE Hub_Slug__c IN ('electrolux-cross-category', 'electrolux-kitchen-refresh', 'aeg-nz-cashback')];
for (Promotional_Campaign__c c : cs) {
    String country = String.isBlank(c.Hub_Country__c) ? 'AU' : c.Hub_Country__c.trim().toUpperCase();
    c.Hub_Collect_Address__c = true;
    c.Hub_Collect_Store__c = true;
    c.Hub_Stores__c = storesByCountry.get(country);
}
update cs;
for (Promotional_Campaign__c c : cs) System.debug('Address and store on: ' + c.Hub_Slug__c + ' (' + c.Hub_Country__c + ')');
System.debug('Campaigns set: ' + cs.size());

// ---- decisions.md #16: hub root domain and the demo campaigns' brand addresses
{
// Wizard only. decisions.md #16: sandbox campaigns live at https://<brand>.test.entryform.claims/<campaign>.
// Sets the hub root domain and moves the three demo campaigns to their brand addresses. Safe to run again.

Claim_Hub_Settings__c hubSet = Claim_Hub_Settings__c.getOrgDefaults();
if (hubSet == null || hubSet.Id == null) hubSet = new Claim_Hub_Settings__c(SetupOwnerId = UserInfo.getOrganizationId());
hubSet.Hub_Root_Domain__c = 'test.entryform.claims';
upsert hubSet;

Map<String, String> hubBases = new Map<String, String>{
    'aeg-nz-cashback' => 'https://aeg.test.entryform.claims',
    'electrolux-cross-category' => 'https://electrolux.test.entryform.claims',
    'electrolux-kitchen-refresh' => 'https://electrolux.test.entryform.claims'
};
List<Promotional_Campaign__c> hubCs = [SELECT Id, Hub_Slug__c, Hub_Base_URL__c FROM Promotional_Campaign__c WHERE Hub_Slug__c IN :hubBases.keySet()];
for (Promotional_Campaign__c hubC : hubCs) hubC.Hub_Base_URL__c = hubBases.get(hubC.Hub_Slug__c);
update hubCs;
for (Promotional_Campaign__c hubC : hubCs) System.debug('address ' + ClaimHubSettings.pageUrl(hubC.Hub_Base_URL__c, hubC.Hub_Slug__c));
System.debug('root=' + ClaimHubSettings.rootDomain() + ' campaigns moved=' + hubCs.size());
}
