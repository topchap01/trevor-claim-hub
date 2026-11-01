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
