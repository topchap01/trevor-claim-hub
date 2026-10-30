trigger PromotionalCampainCreation on Promotional_Campaign__c(BEFORE INSERT) {
	// todo CREATE new record type with the Campaign name

	// read the Trigger.New.CloneForm__c value

	// todo CREATE new Entry Layout optionally as a clone of the clone_from

	// update the entry_record_type with the newly created record type value
	// System.debug('** KW DEBUG ** Call UiApiService ');

	// Map<String, Schema.RecordTypeInfo> recordTypes = SObjectType.Entry__c.getRecordTypeInfosByDeveloperName();
	// System.debug('** KW DEBUG ** Call Trigger  ' + Trigger);
	System.debug('** KW DEBUG ** Call Trigger.isAfter  ' + Trigger.isAfter);
	System.debug('** KW DEBUG ** Call Trigger.isBefore  ' + Trigger.isBefore);
	List<String> recordTypeIds = new List<String>();
	List<String> recordTypeNames = new List<String>();
	if(Trigger.isBefore) {
		System.debug('** KW DEBUG ** Call Trigger.new  ' + Trigger.new);
		Map<Id, Schema.RecordTypeInfo> recordTypes = SObjectType.Entry__c.getRecordTypeInfosById();

		for (Promotional_Campaign__c campaign :Trigger.new) {
			Schema.RecordTypeInfo theRecordType = recordTypes.get(campaign.Entry_Record_Type_ID__c);
			System.debug('** KW DEBUG ** get theRecordType  ' + theRecordType);
			if (theRecordType == null) continue; // claim hub campaigns share the Claim Hub record types and have none of their own
			recordTypeIds.add(String.valueOf(theRecordType.getRecordTypeId()));
			recordTypeNames.add(String.valueOf(theRecordType.getDeveloperName()));
		}
	}


	// if(recordTypeIds.size() > 0) {
	// 	System.debug('** KW DEBUG ** call UiApiService.fixEntryRecordTypePermissions(' + recordTypeIds + ', +' + recordTypeNames + '+)');

	// 	UiApiService.fixEntryRecordTypePermissions(recordTypeIds, recordTypeNames);
	// }

	// for (Promotional_Campaign__c campaign :Trigger.new) {
	//         campaign.addError('stop');
	//     }





	// get entry fields list
	// Map<String, Schema.SObjectField> fields = Schema.SObjectType.Entry__c.fields.getMap();


	// SOQL check if campaign user has permision to all



	// SOQL update permissions? 


}