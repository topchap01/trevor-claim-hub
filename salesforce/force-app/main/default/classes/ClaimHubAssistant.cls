/**
 * The help assistant on the claim pages. Answers only from the promotion's terms summary and, on a claim page, that claim;
 * hands over to the team when it cannot. The model is told never to take actions, ask for bank details or invent terms.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubAssistant {

    static final String ASSISTANT_RULES =
        'You are the help assistant for a cashback promotion run by Trevor Services. You are talking to a member of the public on a phone. ' +
        'Reply in plain {LANG} English: warm, brief, 1 to 4 short sentences. No markdown, no lists unless they ask for steps, no emojis, and never use em dashes or en dashes (use a comma or a full stop instead). ' +
        'Answer only from the PROMOTION and CLAIM information below. If the answer is not there, say you do not know and offer to pass them to the team. ' +
        'Never fill a gap in the terms with an assumption, however reasonable (for example whether delivery, installation or warranty counts toward the price, or how discounts are treated): say the terms do not cover it and offer to pass the question to the team. ' +
        'When you work out a cashback amount, show the sum (e.g. 15% of $5,000 is $750) and say it is an estimate until the invoice is checked. ' +
        'You cannot approve or reject claims, change a status, change bank details, extend a deadline or promise a payment date beyond what the terms say. ' +
        'Never ask for, repeat or accept bank details, passwords or security codes in chat. For bank changes, tell them to use "Change bank details" on their claim page, which sends a security code. ' +
        'If they dispute a decision, are upset, mention hardship, report fraud, or ask for a person, hand over. ' +
        'To hand over, end your reply with a final line exactly: HANDOVER: <one-line reason for the team>. ' +
        'Say you are an automated assistant if asked. Rating plate locations are "usually" where stated, not guaranteed.';

    public static Map<String, Object> chatForCampaign(String slug, Map<String, Object> req) {
        Promotional_Campaign__c c = ClaimHubService.campaignBySlug(slug);
        // Before a claim exists there is no claim to count against, so count by (hashed) connection instead
        String ipHash = req.get('_ip') == null ? null : EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(req.get('_ip')) + ':' + UserInfo.getOrganizationId())));
        if (ipHash != null) {
            Integer asked = [SELECT COUNT() FROM Claim_Event__c WHERE Entry__c = null AND Action__c = :PUBLIC_QUESTION AND Detail__c = :ipHash AND CreatedDate = TODAY];
            if (asked >= ClaimHubSettings.chatDailyLimit() / 2) {
                return new Map<String, Object>{ 'reply' => 'You have asked a lot of questions today. Please email the team and they will help.', 'handover' => false };
            }
        }
        Map<String, Object> out = chat(c, null, req);
        if (ipHash != null) ClaimHubLog.event(null, 'Visitor', PUBLIC_QUESTION, ipHash);
        return out;
    }

    static final String PUBLIC_QUESTION = 'Asked the assistant (promotion page)';

    public static Map<String, Object> chatForClaim(String token, Map<String, Object> req) {
        Entry__c e = ClaimHubService.byToken(token);
        Promotional_Campaign__c c = [SELECT Id, Name, Hub_Slug__c, Hub_Terms_Summary__c, Hub_Payment_Promise__c, Hub_Serial_Deadline__c,
                                            Hub_Bank_Deadline__c, Hub_Timezone__c, Hub_Sender_Address__c, Date_end__c, Sales_From__c, Sales_To__c, Hub_Country__c
                                     FROM Promotional_Campaign__c WHERE Id = :e.Promotional_Campaign__c];
        return chat(c, e, req);
    }

    static Map<String, Object> chat(Promotional_Campaign__c c, Entry__c e, Map<String, Object> req) {
        List<Object> incoming = (List<Object>) req.get('messages');
        if (incoming == null || incoming.isEmpty()) throw new ClaimHubService.HubException(400, 'Ask a question.');
        List<Object> msgs = new List<Object>();
        Integer start = Math.max(0, incoming.size() - 12);
        String lastQuestion;
        for (Integer i = start; i < incoming.size(); i++) {
            Map<String, Object> m = (Map<String, Object>) incoming[i];
            String role = m.get('role') == 'assistant' ? 'assistant' : 'user';
            String content = String.valueOf(m.get('content') == null ? '' : m.get('content')).left(600);
            if (String.isBlank(content)) continue;
            if (msgs.isEmpty() && role == 'assistant') continue; // must start with the person
            msgs.add(new Map<String, Object>{ 'role' => role, 'content' => content });
            if (role == 'user') lastQuestion = content;
        }
        if (msgs.isEmpty()) throw new ClaimHubService.HubException(400, 'Ask a question.');
        if (e != null && ClaimHubLog.countToday(e.Id, 'Asked the assistant') >= ClaimHubSettings.chatDailyLimit()) {
            return new Map<String, Object>{ 'reply' => 'You have asked a lot of questions today, so I have passed your claim to the team. Reply to any of our emails and a person will help.', 'handover' => false };
        }

        Promotional_Campaign__c full = [SELECT Name, Hub_Terms_Summary__c, Hub_Payment_Promise__c, Hub_Serial_Deadline__c, Hub_Bank_Deadline__c,
                                               Hub_Timezone__c, Hub_Sender_Address__c, Date_end__c, Sales_From__c, Sales_To__c, Hub_Country__c,
                                               Hub_Brand_Name__c, Hub_Retailers__c, Hub_Min_Spend__c, Hub_Excluded_Serial_Prefixes__c
                                        FROM Promotional_Campaign__c WHERE Id = :c.Id];
        String tz = String.isBlank(full.Hub_Timezone__c) ? (ClaimHubService.country(full.Hub_Country__c) == 'NZ' ? 'Pacific/Auckland' : 'Australia/Sydney') : full.Hub_Timezone__c;
        String promo = 'PROMOTION: ' + full.Name + (full.Hub_Brand_Name__c == null ? '' : ' (brand ' + full.Hub_Brand_Name__c + ')') +
            '\nCountry: ' + (ClaimHubService.country(full.Hub_Country__c) == 'NZ' ? 'New Zealand, amounts in NZ dollars' : 'Australia, amounts in Australian dollars') +
            (String.isBlank(full.Hub_Retailers__c) ? '' : '\nEligible retailers only: ' + full.Hub_Retailers__c) +
            (full.Hub_Min_Spend__c == null ? '' : '\nMinimum combined spend: ' + ClaimHubService.money(full.Hub_Min_Spend__c, full.Hub_Country__c)) +
            (String.isBlank(full.Hub_Excluded_Serial_Prefixes__c) ? '' : '\nExcluded serial number prefixes (second-quality T2 stock): ' + full.Hub_Excluded_Serial_Prefixes__c) +
            '\nTerms summary: ' + full.Hub_Terms_Summary__c +
            '\nClaims close: ' + (full.Date_end__c == null ? 'see terms' : full.Date_end__c.format('h:mma d MMMM yyyy z', tz)) +
            '\nSerial number deadline: ' + (full.Hub_Serial_Deadline__c == null ? 'see terms' : full.Hub_Serial_Deadline__c.format('h:mma d MMMM yyyy z', tz)) +
            '\nPayment: ' + full.Hub_Payment_Promise__c + ' of approval\nTeam email: ' + full.Hub_Sender_Address__c +
            '\nRating plates (general guidance): oven, usually on the frame visible with the door open; cooktop, usually underneath, often a copy sticker in the manual; ' +
            'dishwasher, usually on the side edge of the door; rangehood, usually inside behind the filters; fridge, usually inside on a side wall. ' +
            'Serial numbers are 8 characters; the PNC is the 9-digit product number on the same plate. The claim page has a "Scan the rating plate" button that reads them from a photo.';
        List<String> models = new List<String>();
        for (Promotional_Product__c pp : [SELECT Campaign_Products__r.Name, Campaign_Products__r.Name__c, Campaign_Products__r.Category__c
                                          FROM Promotional_Product__c WHERE Promotional_Campaign__c = :c.Id ORDER BY Campaign_Products__r.Category__c]) {
            models.add(pp.Campaign_Products__r.Name + ' (' + pp.Campaign_Products__r.Name__c + ')');
        }
        promo += '\nParticipating models (only these qualify): ' + String.join(models, ', ');
        String claim = 'CLAIM: none (the person has not opened a claim; for claim-specific questions tell them to use the link in their email or "Email me my link").';
        if (e != null) {
            Map<String, Object> v = ClaimHubService.view(e.Access_Token__c);
            v.remove('timeline');
            claim = 'CLAIM (today is ' + Datetime.now().format('d MMMM yyyy', tz) + '): ' + JSON.serialize(v) +
                '\nStage meanings: awaiting = claimant still needs to add the items in outstanding; review = complete, team checking within 5 business days; approved = payment queued; paid; payment_failed = bank rejected, update bank details; not_approved.';
        }
        String rules = ASSISTANT_RULES.replace('{LANG}', ClaimHubService.country(full.Hub_Country__c) == 'NZ' ? 'New Zealand' : 'Australian');
        String reply = ClaimHubVision.chat(rules + '\n\n' + promo + '\n\n' + claim, msgs);
        if (reply == null) {
            return new Map<String, Object>{ 'reply' => 'Sorry, I can\'t answer right now. Email ' + full.Hub_Sender_Address__c + ' and the team will help.', 'handover' => false };
        }
        Boolean handover = false;
        Matcher m = Pattern.compile('(?m)^\\s*HANDOVER:\\s*(.+)$').matcher(reply);
        String reason;
        if (m.find()) { handover = true; reason = m.group(1).trim(); reply = reply.substring(0, m.start()).trim(); }
        if (e != null) {
            ClaimHubLog.event(e.Id, 'Claimant', 'Asked the assistant', lastQuestion == null ? null : lastQuestion.left(255));
            if (handover) ClaimHubLog.event(e.Id, 'System', 'Needs review: assistant handover', (reason == null ? '' : reason).left(255));
        }
        return new Map<String, Object>{ 'reply' => reply, 'handover' => handover,
            'handoverNote' => handover ? (e != null ? 'I\'ve passed this to the team with your claim details. They\'ll reply by email within 1 business day.'
                                                    : 'Please email ' + full.Hub_Sender_Address__c + ' and the team will help.') : null };
    }
}
