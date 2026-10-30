trigger ClaimHubEntryTrigger on Entry__c (after update) {
    ClaimHubEntryHandler.afterUpdate(Trigger.new, Trigger.oldMap);
}
