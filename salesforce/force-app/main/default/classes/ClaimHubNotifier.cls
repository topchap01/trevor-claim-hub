/**
 * Claim email outbox. Every email is a Claim_Notification__c record first (Queued -> Sent / Failed), so nothing
 * is lost if sending fails, and the team can see exactly what each claimant was sent.
 * Claimant changes made close together are batched into one summary email (DEBOUNCE_MINUTES).
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubNotifier {
    static Boolean dispatchQueued = false;

    public static void enqueueNow(Id entryId, String key) {
        enqueueMany(new Map<Id, String>{ entryId => key });
    }

    /** Queues one email per claim (claim Id => template key) with one query and one insert. */
    public static void enqueueMany(Map<Id, String> keyByEntry) {
        if (keyByEntry.isEmpty()) return;
        List<Claim_Notification__c> ns = new List<Claim_Notification__c>();
        for (Entry__c e : [SELECT Id, Consumer_Email_Stamp__c FROM Entry__c WHERE Id IN :keyByEntry.keySet()]) {
            ns.add(new Claim_Notification__c(Entry__c = e.Id, Template_Key__c = keyByEntry.get(e.Id), Status__c = 'Queued',
                Send_After__c = Datetime.now(), To_Address__c = e.Consumer_Email_Stamp__c, Attempts__c = 0));
        }
        insert ns;
        kick(0);
    }

    public static void addToSummary(Id entryId, String change) {
        List<Claim_Notification__c> pending = [SELECT Id, Changes__c FROM Claim_Notification__c
            WHERE Entry__c = :entryId AND Template_Key__c = 'PROGRESS' AND Status__c = 'Queued' LIMIT 1];
        if (!pending.isEmpty()) {
            pending[0].Changes__c = (pending[0].Changes__c == null ? '' : pending[0].Changes__c + '\n') + change;
            update pending[0];
            return;
        }
        Entry__c e = [SELECT Consumer_Email_Stamp__c FROM Entry__c WHERE Id = :entryId];
        insert new Claim_Notification__c(Entry__c = entryId, Template_Key__c = 'PROGRESS', Status__c = 'Queued', Changes__c = change,
            Send_After__c = Datetime.now().addMinutes(ClaimHubSettings.debounceMinutes()), To_Address__c = e.Consumer_Email_Stamp__c, Attempts__c = 0);
        kick(ClaimHubSettings.debounceMinutes());
    }

    public static void mergePendingSummary(Id entryId) {
        List<Claim_Notification__c> pending = [SELECT Id FROM Claim_Notification__c
            WHERE Entry__c = :entryId AND Template_Key__c = 'PROGRESS' AND Status__c = 'Queued'];
        for (Claim_Notification__c n : pending) { n.Status__c = 'Merged'; n.Last_Error__c = 'Merged into the completion email'; }
        update pending;
    }

    /** Security codes are sent straight away and never stored in readable form. */
    public static void sendCode(Entry__c e, String code) {
        String body = wrap(e, 'Your security code', new List<String>{
            'Your code to change the bank details on claim ' + e.Name + ' is:',
            '<span style="font-size:28px;letter-spacing:6px;font-weight:700">' + code + '</span>',
            'It expires in 10 minutes. We will never ask for this code by phone or email.' }, null, null);
        Claim_Notification__c n = new Claim_Notification__c(Entry__c = e.Id, Template_Key__c = 'CODE', Subject__c = 'Your security code',
            Body__c = '[code not stored]', To_Address__c = e.Consumer_Email_Stamp__c, Attempts__c = 1);
        try {
            send(new List<Messaging.SingleEmailMessage>{ message(e, 'Your security code', body) });
            n.Status__c = 'Sent'; n.Sent_At__c = Datetime.now();
        } catch (Exception ex) {
            n.Status__c = 'Failed'; n.Last_Error__c = ex.getMessage().left(255);
        }
        insert n;
    }

    static void kick(Integer delayMinutes) {
        if (dispatchQueued || Test.isRunningTest() && delayMinutes > 0) return;
        try {
            if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
            AsyncOptions opts = new AsyncOptions();
            opts.MinimumQueueableDelayInMinutes = Math.min(Math.max(delayMinutes, 0), 10);
            System.enqueueJob(new ClaimHubDispatchJob(), opts);
            dispatchQueued = true;
        } catch (Exception ex) {
            // Not fatal: the hourly monitor (ClaimHubMonitor) sends anything left in the queue.
            System.debug(LoggingLevel.WARN, 'Could not queue the email job: ' + ex.getMessage());
        }
    }

    // ------------------------------------------------------------------ sending
    public static void dispatchDue() {
        List<Claim_Notification__c> due = [SELECT Id, Entry__c, Template_Key__c, Changes__c, Attempts__c FROM Claim_Notification__c
            WHERE Status__c = 'Queued' AND Send_After__c <= :Datetime.now() ORDER BY Send_After__c LIMIT 50];
        if (due.isEmpty()) return;
        Set<Id> entryIds = new Set<Id>();
        for (Claim_Notification__c n : due) entryIds.add(n.Entry__c);
        Map<Id, Entry__c> entries = ClaimHubService.loadMany(entryIds);
        List<Messaging.SingleEmailMessage> msgs = new List<Messaging.SingleEmailMessage>();
        List<Claim_Notification__c> sending = new List<Claim_Notification__c>();
        for (Claim_Notification__c n : due) {
            n.Attempts__c = (n.Attempts__c == null ? 0 : n.Attempts__c) + 1;
            try {
                Entry__c e = entries.get(n.Entry__c);
                if (e == null) { n.Status__c = 'Skipped'; n.Last_Error__c = 'Claim no longer exists'; continue; }
                List<String> parts = render(n.Template_Key__c, e, n.Changes__c);
                if (parts == null) { n.Status__c = 'Skipped'; continue; }
                n.Subject__c = parts[0].left(255); n.Body__c = parts[1].left(32000); n.To_Address__c = e.Consumer_Email_Stamp__c;
                msgs.add(message(e, parts[0], parts[1]));
                sending.add(n);
            } catch (Exception ex) {
                n.Status__c = n.Attempts__c >= 3 ? 'Failed' : 'Queued';
                n.Last_Error__c = ex.getMessage().left(255);
            }
        }
        if (!msgs.isEmpty()) {
            List<Messaging.SendEmailResult> results;
            try {
                results = Messaging.sendEmail(msgs, false);
            } catch (Exception ex) {
                for (Claim_Notification__c n : sending) { n.Status__c = n.Attempts__c >= 3 ? 'Failed' : 'Queued'; n.Last_Error__c = ex.getMessage().left(255); }
            }
            if (results != null) {
                for (Integer i = 0; i < results.size(); i++) {
                    Claim_Notification__c n = sending[i];
                    if (results[i].isSuccess()) { n.Status__c = 'Sent'; n.Sent_At__c = Datetime.now(); n.Last_Error__c = null; }
                    else { n.Status__c = n.Attempts__c >= 3 ? 'Failed' : 'Queued'; n.Last_Error__c = results[i].getErrors()[0].getMessage().left(255); }
                }
            }
        }
        update due;
    }

    static void send(List<Messaging.SingleEmailMessage> msgs) {
        Messaging.SendEmailResult[] r = Messaging.sendEmail(msgs, false);
        if (!r[0].isSuccess()) throw new ClaimHubService.HubException(500, r[0].getErrors()[0].getMessage());
    }

    static Map<String, Id> oweaCache = new Map<String, Id>();
    static Messaging.SingleEmailMessage message(Entry__c e, String subject, String html) {
        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        m.setTargetObjectId(e.Customer__c);           // a Lead, so it doesn't use the external single-email allowance
        m.setTreatTargetObjectAsRecipient(true);
        m.setSaveAsActivity(false);
        m.setSubject(subject);
        m.setHtmlBody(html);
        m.setWhatId(null);
        String sender = e.Promotional_Campaign__r.Hub_Sender_Address__c;
        if (String.isNotBlank(sender)) {
            if (!oweaCache.containsKey(sender)) {
                List<OrgWideEmailAddress> o = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :sender LIMIT 1];
                oweaCache.put(sender, o.isEmpty() ? null : o[0].Id);
            }
            if (oweaCache.get(sender) != null) m.setOrgWideEmailAddressId(oweaCache.get(sender));
        }
        return m;
    }

    // ------------------------------------------------------------------ templates
    public static String link(Entry__c e) {
        String base = e.Promotional_Campaign__r.Hub_Base_URL__c == null ? '' : e.Promotional_Campaign__r.Hub_Base_URL__c.removeEnd('/');
        return base + '/c?token=' + e.Access_Token__c + (e.Promotional_Campaign__r.Hub_Slug__c == null ? '' : '&s=' + EncodingUtil.urlEncode(e.Promotional_Campaign__r.Hub_Slug__c, 'UTF-8'));
    }


    static String fmt(Datetime d, Entry__c e) {
        if (d == null) return '';
        String tz = String.isBlank(e.Promotional_Campaign__r.Hub_Timezone__c) ? 'Australia/Sydney' : e.Promotional_Campaign__r.Hub_Timezone__c;
        return d.format('h:mma d MMMM yyyy', tz).replace('AM', 'am').replace('PM', 'pm');
    }

    static List<String> needed(Entry__c e) {
        List<String> out = new List<String>();
        for (String o : ClaimHubService.outstanding(e)) {
            if (o == 'invoice') out.add('a photo of your invoice');
            else if (o == 'bank') out.add('your bank details');
            else out.add('the serial number for your ' + o.substringAfter('serial:'));
        }
        return out;
    }

    static String bullets(List<String> items) {
        String s = '<ul style="padding-left:18px;margin:8px 0">';
        for (String i : items) s += '<li style="margin:4px 0">' + i.escapeHtml4() + '</li>';
        return s + '</ul>';
    }

    /** Returns [subject, html] or null to skip. */
    public static List<String> render(String key, Entry__c e, String changes) {
        String first = e.Consumer_First_Name_Stamp__c == null ? 'there' : e.Consumer_First_Name_Stamp__c.escapeHtml4();
        List<String> need = needed(e);
        String deadline = fmt(e.Promotional_Campaign__r.Hub_Serial_Deadline__c, e);
        String amount = ClaimHubService.money(e.Cashback_Amount__c, e.Promotional_Campaign__r.Hub_Country__c);
        if (key == 'LODGED') {
            List<String> p = new List<String>{ 'Hi ' + first + ', thanks for your claim ' + e.Name + '. Your appliances qualify for <b>' + amount + ' cashback</b>.' };
            if (!need.isEmpty()) { p.add('To finish your claim we still need:' + bullets(need)); p.add('Add them any time before ' + deadline + ' using the button below. No password needed.'); }
            return new List<String>{ need.isEmpty() ? 'Thanks, we\'ve got your claim' : 'Thanks, we\'ve got your claim. ' + need.size() + ' item' + (need.size() == 1 ? '' : 's') + ' to go', wrap(e, 'We\'ve got your claim', p, 'Open my claim', link(e)) };
        }
        if (key == 'PROGRESS') {
            if (ClaimHubService.stage(e) != 'awaiting') return null;
            List<String> got = changes == null ? new List<String>() : changes.split('\n');
            List<String> p = new List<String>{ 'Hi ' + first + ', here\'s what we\'ve received:' + bullets(got) };
            if (!need.isEmpty()) p.add('Still needed:' + bullets(need) + 'Please add ' + (need.size() == 1 ? 'it' : 'them') + ' before ' + deadline + '.');
            return new List<String>{ need.isEmpty() ? 'We\'ve got it' : 'We\'ve got it. ' + need.size() + ' item' + (need.size() == 1 ? '' : 's') + ' still needed', wrap(e, 'Thanks, that\'s saved', p, 'Open my claim', link(e)) };
        }
        if (key == 'COMPLETE') {
            return new List<String>{ 'Your claim is complete and with our team', wrap(e, 'Everything\'s in', new List<String>{
                'Hi ' + first + ', we have everything we need for claim ' + e.Name + '.',
                'Our team checks claims within 5 business days. Once it\'s approved, your ' + amount + ' cashback is paid to your account ending ' + ClaimHubService.last3(ClaimHubService.accountNumber(e)) + '.' }, 'Track my claim', link(e)) };
        }
        if (key == 'VALID') {
            return new List<String>{ 'Your claim has been approved', wrap(e, 'Approved', new List<String>{
                'Good news, ' + first + '. Claim ' + e.Name + ' has been checked and approved.',
                amount + ' will be paid to your account ending ' + ClaimHubService.last3(ClaimHubService.accountNumber(e)) + ' ' + (e.Promotional_Campaign__r.Hub_Payment_Promise__c == null ? 'in the next payment run' : e.Promotional_Campaign__r.Hub_Payment_Promise__c) + '.' }, 'Track my claim', link(e)) };
        }
        if (key == 'PAID') {
            return new List<String>{ 'Your ' + amount + ' cashback has been paid', wrap(e, 'Paid', new List<String>{
                'Hi ' + first + ', we\'ve paid ' + amount + ' to your account ending ' + ClaimHubService.last3(ClaimHubService.accountNumber(e)) + '. It should show within 1 to 2 business days.',
                e.Promotional_Campaign__r.Hub_Brand_Name__c == null ? 'Thanks for taking part.' : 'Thanks for choosing ' + e.Promotional_Campaign__r.Hub_Brand_Name__c.escapeHtml4() + '.' }, null, null) };
        }
        if (key == 'EFT_FAILED') {
            return new List<String>{ 'We couldn\'t pay your cashback', wrap(e, 'Payment didn\'t go through', new List<String>{
                'Hi ' + first + ', the bank rejected the payment to your account ending ' + ClaimHubService.last3(ClaimHubService.accountNumber(e)) + '.',
                'Please check and update your bank details. You\'ll need a security code, which we send when you start the change. Please update them before ' + fmt(e.Promotional_Campaign__r.Hub_Bank_Deadline__c, e) + '.' }, 'Update bank details', link(e)) };
        }
        if (key == 'BANK_CHANGED') {
            return new List<String>{ 'Your bank details were changed', wrap(e, 'Bank details changed', new List<String>{
                'Hi ' + first + ', the bank account on claim ' + e.Name + ' was just changed to an account ending ' + ClaimHubService.last3(ClaimHubService.accountNumber(e)) + '.',
                'If this was you, there\'s nothing to do. If it wasn\'t, reply to this email straight away and we\'ll stop the payment.' }, null, null) };
        }
        if (key == 'INVALID') {
            return new List<String>{ 'An update on your claim', wrap(e, 'Your claim wasn\'t approved', new List<String>{
                'Hi ' + first + ', we\'ve checked claim ' + e.Name + ' and it doesn\'t meet the promotion terms' + (e.Invalid_Reason__c == null ? '.' : ': ' + e.Invalid_Reason__c.escapeHtml4() + '.'),
                'If you think this is wrong, reply to this email and a person will look at it.' }, null, null) };
        }
        if (key == 'REMINDER') {
            if (need.isEmpty() || ClaimHubService.stage(e) != 'awaiting') return null;
            return new List<String>{ 'Reminder: your ' + amount + ' cashback is waiting', wrap(e, 'Your cashback is waiting', new List<String>{
                'Hi ' + first + ', your claim is nearly done. We still need:' + bullets(need),
                'Serial numbers are on the rating plate. Tap the button, then "Scan plate" to read it with your camera.',
                'Deadline: ' + deadline + '. After that we can\'t pay the claim.' }, 'Finish my claim', link(e)) };
        }
        if (key == 'LINK') {
            return new List<String>{ 'Your claim link', wrap(e, 'Here\'s your link', new List<String>{
                'Hi ' + first + ', here\'s a fresh link to claim ' + e.Name + '. Older links no longer work.' }, 'Open my claim', link(e)) };
        }
        return null;
    }

    static String wrap(Entry__c e, String heading, List<String> paras, String button, String url) {
        String color = String.isBlank(e.Promotional_Campaign__r.Hub_Brand_Color__c) ? '#041E50' : e.Promotional_Campaign__r.Hub_Brand_Color__c;
        String h = '<div style="background:#f4f5f7;padding:24px 12px;font-family:Arial,Helvetica,sans-serif;color:#1b1f24">'
            + '<div style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:10px;overflow:hidden">'
            + '<div style="background:' + color + ';color:#ffffff;padding:18px 24px;font-size:13px;letter-spacing:.06em;text-transform:uppercase">' + e.Promotional_Campaign__r.Name.escapeHtml4() + '</div>'
            + '<div style="padding:24px"><h1 style="font-size:22px;margin:0 0 14px">' + heading.escapeHtml4() + '</h1>';
        for (String p : paras) h += '<p style="font-size:15px;line-height:1.5;margin:0 0 12px">' + p + '</p>';
        if (button != null && url != null) {
            h += '<p style="margin:20px 0"><a href="' + url + '" style="background:' + color + ';color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:6px;font-weight:bold;display:inline-block">' + button + '</a></p>'
               + '<p style="font-size:12px;color:#5b6470">This link opens your claim only. Keep it to yourself.</p>';
        }
        h += '</div><div style="padding:14px 24px;font-size:12px;color:#5b6470;border-top:1px solid #e3e6ea">Claim ' + e.Name + '. Reply to this email if you need a hand.</div></div></div>';
        return h;
    }
}
