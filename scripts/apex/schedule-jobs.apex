// Schedules the claim hub's background jobs. Safe to run again: existing hub jobs are replaced.
// Run: sf apex run -o <org> -f scripts/apex/schedule-jobs.apex
for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Claim hub%']) System.abortJob(ct.Id);
System.schedule('Claim hub reminders (daily 9am)', '0 0 9 * * ?', new ClaimHubReminders());
System.schedule('Claim hub monitor (hourly)', '0 5 * * * ?', new ClaimHubMonitor());
System.debug('Scheduled: ' + [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Claim hub%']);
