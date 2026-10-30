/**
 * Calls Claude to read invoices and rating plates, answer claimant questions and read promotion terms.
 * Uses the API key the org already holds for invoice OCR (Claude_Setting__mdt.Default, via ClaudeInvoiceExtractionBatch).
 * Every method degrades instead of throwing: readers return {"error": ...}, chat returns null, so a Claude outage
 * sends work to the team rather than failing the claimant.
 * Callout time does not count toward the org's concurrent long-running request limit.
 */
public without sharing class ClaimHubVision {

    static final String ENDPOINT = 'https://api.anthropic.com/v1/messages';

    public static Map<String, Object> readPlate(String base64, String mediaType) {
        return ask(base64, mediaType,
            'This is a photo of a home appliance rating plate (Electrolux / AEG / Westinghouse). Read it and reply with ONLY a JSON object: ' +
            '{"serial": string|null (the serial number, labelled S/N or Ser.No, usually 8 digits), "pnc": string|null (the 9-digit product number labelled PNC or Prod.No, digits only), ' +
            '"model": string|null (the model code), "readable": boolean}. Use null for anything you cannot read clearly. Do not guess.');
    }

    public static Map<String, Object> readInvoice(String base64, String mediaType) { return readInvoice(base64, mediaType, 'AU'); }

    public static Map<String, Object> readInvoice(String base64, String mediaType, String country) {
        return ask(base64, mediaType,
            'This is a retail tax invoice or receipt for home appliances in ' + (country == 'NZ' ? 'New Zealand' : 'Australia') + '. Reply with ONLY a JSON object: ' +
            '{"isInvoice": boolean, "retailer": string|null (the retail brand, e.g. Harvey Norman), "store": string|null, "invoiceNumber": string|null, "invoiceDate": "YYYY-MM-DD"|null, ' +
            '"total": number|null, "balanceDue": number|null (amount still owing, 0 if paid in full), ' +
            '"lines": [{"model": string|null, "description": string|null, "price": number|null (the line total paid after any discount, including GST)}], "customerName": string|null}. ' +
            'List every appliance line. Use null for anything you cannot read clearly. Do not guess.');
    }

    /**
     * Sends promotion terms (pasted text, or a PDF as base64) to Claude with an extraction brief and returns the parsed JSON,
     * or {"error": ...}. Used by ClaimHubTerms to draft a campaign from its terms and conditions.
     */
    public static Map<String, Object> extract(String brief, String termsText, String pdfBase64) {
        List<Object> content = new List<Object>();
        if (String.isNotBlank(pdfBase64)) content.add(new Map<String, Object>{ 'type' => 'document',
            'source' => new Map<String, Object>{ 'type' => 'base64', 'media_type' => 'application/pdf', 'data' => pdfBase64 } });
        if (String.isNotBlank(termsText)) content.add(new Map<String, Object>{ 'type' => 'text', 'text' => '<terms>\n' + termsText + '\n</terms>' });
        content.add(new Map<String, Object>{ 'type' => 'text', 'text' => brief });
        return parseJson(post(message(12000, null, new List<Object>{ new Map<String, Object>{ 'role' => 'user', 'content' => content } }), 120000));
    }

    /** Plain chat completion. Returns the reply text, or null if Claude is unavailable. */
    public static String chat(String systemPrompt, List<Object> messages) {
        HttpResponse res = post(message(500, systemPrompt, messages), 60000);
        return res == null || res.getStatusCode() != 200 ? null : text(res);
    }

    static Map<String, Object> ask(String base64, String mediaType, String instruction) {
        Boolean pdf = mediaType != null && mediaType.containsIgnoreCase('pdf');
        Map<String, Object> source = new Map<String, Object>{ 'type' => 'base64',
            'media_type' => pdf ? 'application/pdf' : (String.isBlank(mediaType) ? 'image/jpeg' : mediaType), 'data' => base64 };
        List<Object> content = new List<Object>{
            new Map<String, Object>{ 'type' => pdf ? 'document' : 'image', 'source' => source },
            new Map<String, Object>{ 'type' => 'text', 'text' => instruction } };
        return parseJson(post(message(1200, null, new List<Object>{ new Map<String, Object>{ 'role' => 'user', 'content' => content } }), 60000));
    }

    static Map<String, Object> message(Integer maxTokens, String systemPrompt, List<Object> messages) {
        Map<String, Object> body = new Map<String, Object>{ 'model' => ClaimHubSettings.model(), 'max_tokens' => maxTokens, 'messages' => messages };
        if (systemPrompt != null) body.put('system', systemPrompt);
        return body;
    }

    /** One place for the request. Returns null (and logs) if the call itself fails, e.g. a timeout. */
    static HttpResponse post(Map<String, Object> body, Integer timeoutMs) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT);
        req.setMethod('POST');
        req.setHeader('x-api-key', ClaudeInvoiceExtractionBatch.getApiKey());
        req.setHeader('anthropic-version', '2023-06-01');
        req.setHeader('content-type', 'application/json');
        req.setTimeout(timeoutMs);
        req.setBody(JSON.serialize(body));
        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) ClaimHubLog.warn('Claude returned ' + res.getStatusCode() + ': ' + res.getBody().left(500));
            return res;
        } catch (CalloutException ex) {
            ClaimHubLog.warn('Claude call failed: ' + ex.getMessage());
            return null;
        }
    }

    static String text(HttpResponse res) {
        String out = '';
        Object content = ((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('content');
        if (!(content instanceof List<Object>)) return out;
        for (Object c : (List<Object>) content) {
            Map<String, Object> part = (Map<String, Object>) c;
            if (part.get('type') == 'text') out += (String) part.get('text');
        }
        return out;
    }

    @TestVisible
    static Map<String, Object> parseJson(HttpResponse res) {
        if (res == null) return new Map<String, Object>{ 'error' => 'Reader unavailable (no response)' };
        if (res.getStatusCode() != 200) return new Map<String, Object>{ 'error' => 'Reader unavailable (' + res.getStatusCode() + ')' };
        try {
            String t = text(res);
            Integer a = t.indexOf('{'), b = t.lastIndexOf('}');
            if (a < 0 || b <= a) return new Map<String, Object>{ 'error' => 'Could not read the image' };
            return (Map<String, Object>) JSON.deserializeUntyped(t.substring(a, b + 1));
        } catch (Exception ex) {
            return new Map<String, Object>{ 'error' => 'Could not read the image' };
        }
    }
}
