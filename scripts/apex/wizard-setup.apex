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

// ---- decisions.md #16, from scripts/apex/entryform-addresses.apex
{
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
}
