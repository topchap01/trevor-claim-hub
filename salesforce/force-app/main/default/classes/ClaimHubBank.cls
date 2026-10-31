/**
 * Checks bank details against published rules and registers (decisions.md #11).
 *
 * Refuses only a New Zealand account number that fails its bank's check digit: that number can't be right, and the
 * claimant is on the page to fix it. Anything a register can't confirm is accepted and flagged for review instead,
 * because a register can lag behind a new bank or branch and a real account must not be turned away.
 *
 * Sources:
 *  - NZ check digits: Inland Revenue, Payroll Calculations and Business Rules Specification, section 7
 *    "Bank account number validation" (www.ird.govt.nz, digital service providers). Algorithms A, B, D and F are
 *    implemented. E and G belong to bank codes the Payments NZ register does not list, so numbers on those codes
 *    are flagged rather than checked. The suffix (account type) is not part of any check.
 *  - NZ banks and branches: Payments NZ Bank Branch Register.
 *  - AU BSBs: AusPayNet BSB directory. Australian account numbers have no published check digit.
 * The registers are loaded into Hub_Bank_Branch__c by scripts/load-bank-register.mjs.
 */
/* System mode on purpose: this runs as the API-only integration user, whose profile grants no object access.
 * Access is controlled by who can call the code (ClaimHubApi via the Claim Hub Integration permission set; staff
 * entry points via Claim Hub Admin), not by object permissions. See docs/security.md. */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ClaimHubBank {

    public static final String WRONG_NUMBER = 'That account number doesn\'t check out: a digit may be wrong or two swapped. Check it against your bank statement or banking app.';

    /** What the registers say about an account. review is set when a person should look at it. */
    public class Check {
        public String bankName;
        public String branchName;
        public String review;
    }

    // ---------------------------------------------------------------- New Zealand

    /** Check-digit algorithm by bank code (IRD specification, section 7). Codes not listed have no check. */
    static final Map<String, String> NZ_ALGORITHM = new Map<String, String>{
        '01' => 'A', '02' => 'A', '03' => 'A', '04' => 'A', '06' => 'A', '08' => 'D', '10' => 'A', '11' => 'A',
        '12' => 'A', '13' => 'A', '14' => 'A', '15' => 'A', '16' => 'A', '17' => 'A', '18' => 'A', '19' => 'A',
        '20' => 'A', '21' => 'A', '22' => 'A', '23' => 'A', '24' => 'A', '25' => 'F', '27' => 'A', '30' => 'A',
        '33' => 'F', '35' => 'A', '38' => 'A' };

    /** Weights over the 16 digits bank (2), branch (4), account (7), suffix (3). */
    static final Map<String, List<Integer>> NZ_WEIGHTS = new Map<String, List<Integer>>{
        'A' => new List<Integer>{ 0, 0, 6, 3, 7, 9, 0, 10, 5, 8, 4, 2, 1, 0, 0, 0 },
        'B' => new List<Integer>{ 0, 0, 0, 0, 0, 0, 0, 10, 5, 8, 4, 2, 1, 0, 0, 0 },
        'D' => new List<Integer>{ 0, 0, 0, 0, 0, 0, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0 },
        'F' => new List<Integer>{ 0, 0, 0, 0, 0, 0, 1, 7, 3, 1, 7, 3, 1, 0, 0, 0 } };
    static final Map<String, Integer> NZ_MODULUS = new Map<String, Integer>{ 'A' => 11, 'B' => 11, 'D' => 11, 'F' => 10 };

    /** 15 or 16 digits as 16: a two-digit suffix becomes three. */
    @TestVisible
    static String nz16(String digits) {
        return digits.left(13) + digits.substring(13).leftPad(3, '0');
    }

    /** Which algorithm applies: A becomes B for account numbers from 0990000 up. Null when the bank has no check. */
    @TestVisible
    static String nzAlgorithm(String n) {
        String alg = NZ_ALGORITHM.get(n.left(2));
        if (alg == 'A' && n.substring(6, 13) >= '0990000') alg = 'B';
        return alg;
    }

    /** True when the check digit adds up, or the bank has no published check. n: 16 digits. */
    @TestVisible
    static Boolean nzCheckDigitOk(String n) {
        String alg = nzAlgorithm(n);
        if (alg == null) return true;
        List<Integer> w = NZ_WEIGHTS.get(alg);
        Integer sum = 0;
        for (Integer i = 0; i < 16; i++) sum += w[i] * Integer.valueOf(n.substring(i, i + 1));
        return Math.mod(sum, NZ_MODULUS.get(alg)) == 0;
    }

    /**
     * Checks a New Zealand account number (15 or 16 digits, already length-checked).
     * Throws a 400 when the check digit fails; otherwise returns the bank and branch, or a reason to review.
     */
    public static Check nz(String digits) {
        String n = nz16(digits);
        if (!nzCheckDigitOk(n)) throw new ClaimHubService.HubException(400, WRONG_NUMBER);
        String bank = n.left(2), branch = n.substring(2, 6);
        Check out = new Check();
        Hub_Bank_Branch__c r = find('NZ-' + bank + '-' + branch);
        if (r != null) {
            out.bankName = r.Bank_Name__c;
            out.branchName = r.Branch_Name__c;
        } else if (registerLoaded('NZ')) {
            out.review = 'Bank ' + bank + ', branch ' + branch + ' is not in the Payments NZ Bank Branch Register' +
                (nzAlgorithm(n) == null ? ', and bank ' + bank + ' has no check digit to confirm the number' : '');
        }
        return out;
    }

    // ---------------------------------------------------------------- Australia

    /** Checks a BSB (6 digits, already length-checked) against the AusPayNet directory. */
    public static Check au(String bsb) {
        Check out = new Check();
        Hub_Bank_Branch__c r = find('AU-' + bsb.left(3) + '-' + bsb.right(3));
        String shown = bsb.left(3) + '-' + bsb.right(3);
        if (r != null) {
            out.bankName = r.Bank_Name__c;
            out.branchName = r.Branch_Name__c;
            if (closed(r)) {
                out.review = 'BSB ' + shown + ' is listed as closed in the AusPayNet BSB directory';
            } else if (r.Payments__c != null && !r.Payments__c.contains('E')) {
                out.review = 'BSB ' + shown + ' does not take electronic payments (AusPayNet BSB directory)';
            }
        } else if (registerLoaded('AU')) {
            out.review = 'BSB ' + shown + ' is not in the AusPayNet BSB directory';
        }
        return out;
    }

    // ---------------------------------------------------------------- lookup for the claim form

    /**
     * Bank and branch for the first six digits the claimant has typed (NZ bank and branch, or an AU BSB),
     * so the form can show them back. Register data only; no personal data in or out.
     */
    public static Map<String, Object> lookup(String country, String code) {
        String cc = country == null ? '' : country.toUpperCase();
        if ((cc != 'NZ' && cc != 'AU') || code == null || !Pattern.matches('[0-9]{6}', code)) {
            throw new ClaimHubService.HubException(400, 'Bad request');
        }
        Hub_Bank_Branch__c r = find(cc == 'NZ' ? 'NZ-' + code.left(2) + '-' + code.right(4) : 'AU-' + code.left(3) + '-' + code.right(3));
        if (r == null) return new Map<String, Object>{ 'found' => false, 'registerLoaded' => registerLoaded(cc) };
        Boolean electronic = cc != 'AU' || r.Payments__c == null || r.Payments__c.contains('E');
        return new Map<String, Object>{ 'found' => true, 'bankName' => r.Bank_Name__c, 'branchName' => r.Branch_Name__c, 'electronic' => electronic,
            'closed' => cc == 'AU' && closed(r) };
    }

    /** AusPayNet keeps closed BSBs in the directory with the branch name "Closed" (39 of 17,266 rows, November 2026). */
    static Boolean closed(Hub_Bank_Branch__c r) {
        return r.Branch_Name__c != null && r.Branch_Name__c.trim().equalsIgnoreCase('Closed');
    }

    // ---------------------------------------------------------------- registers

    static Hub_Bank_Branch__c find(String key) {
        List<Hub_Bank_Branch__c> rows = [SELECT Bank_Name__c, Branch_Name__c, Payments__c FROM Hub_Bank_Branch__c WHERE Key__c = :key LIMIT 1];
        return rows.isEmpty() ? null : rows[0];
    }

    static Map<String, Boolean> loaded = new Map<String, Boolean>();

    /** Whether a country's register has been loaded. With no register, nothing is flagged for being missing from it. */
    public static Boolean registerLoaded(String country) {
        if (!loaded.containsKey(country)) {
            String prefix = country + '-%';
            loaded.put(country, [SELECT COUNT() FROM Hub_Bank_Branch__c WHERE Key__c LIKE :prefix LIMIT 1] > 0);
        }
        return loaded.get(country);
    }

    /** Rows per country, for the health check. */
    public static Map<String, Object> registerCounts() {
        Map<String, Object> out = new Map<String, Object>{ 'NZ' => 0, 'AU' => 0 };
        for (AggregateResult ar : [SELECT Country__c c, COUNT(Id) n FROM Hub_Bank_Branch__c GROUP BY Country__c]) {
            if (ar.get('c') != null) out.put((String) ar.get('c'), ar.get('n'));
        }
        return out;
    }

    /** Clears the per-transaction cache (tests load registers part-way through). */
    @TestVisible
    static void forget() { loaded.clear(); }
}
