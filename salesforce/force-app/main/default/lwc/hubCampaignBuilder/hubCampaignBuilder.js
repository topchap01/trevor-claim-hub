import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import readTerms from '@salesforce/apex/ClaimHubTerms.readTerms';
import schedule from '@salesforce/apex/ClaimHubTerms.schedule';
import create from '@salesforce/apex/ClaimHubTerms.create';
import templates from '@salesforce/apex/ClaimHubTerms.templates';

const fmtLocal = (v) => {
    if (!v) return 'Not stated';
    const d = new Date(v.slice(0, 10) + 'T00:00:00');
    const date = d.toLocaleDateString('en-AU', { day: 'numeric', month: 'long', year: 'numeric' });
    return v.length >= 16 ? `${v.slice(11, 16)} ${date}` : date;
};
const money = (n, c) => (n === null || n === undefined ? '' : (c === 'NZ' ? 'NZ$' : '$') + Number(n).toLocaleString('en-AU'));

export default class HubCampaignBuilder extends NavigationMixin(LightningElement) {
    terms = '';
    pdfBase64;
    pdfName;
    busy = false;
    error;
    spec;
    sched;
    templateOptions = [];
    opts = { name: '', slug: '', start: '', end: '', compareCampaignId: '', baseUrl: 'https://trevor-claim-hub-test.vercel.app', sender: '', brandColor: '#111111', termsUrl: '', enable: true };

    @wire(templates) wiredTemplates({ data }) { if (data) this.templateOptions = data; }

    get hasSpec() { return !!this.spec; }
    get busyText() { return this.spec ? 'Working…' : 'Claude is reading the terms. This takes up to a minute.'; }
    get cannotRead() { return this.busy || (!this.terms && !this.pdfBase64); }
    get cannotCreate() { return this.busy || !this.sched || !this.opts.name || !this.opts.slug || this.unsupported; }
    get unsupported() { return this.spec && this.spec.mechanicSupported === false; }

    get facts() {
        const s = this.spec, c = s.country;
        const tiers = (s.tiers || []).map((t) => {
            const who = t.minSpend > 0 ? `${money(t.minSpend, c)}${t.maxSpend ? ' to ' + money(t.maxSpend, c) : '+'}`
                : `${t.minQty}${t.maxQty ? (t.maxQty === t.minQty ? '' : ' to ' + t.maxQty) : '+'} products`;
            return `${who} → ${t.percent ? t.percent + '% of price paid' : money(t.amount, c)}`;
        }).join('; ') + (s.maxCashback ? `; capped at ${money(s.maxCashback, c)}` : '; no cap');
        return [
            ['Promotion', s.promotionName], ['Brand / promoter', `${s.brand} / ${s.promoter}`],
            ['Country and time zone', `${s.country}, ${s.timezone}`],
            ['Where to buy', (s.retailers || []).length ? s.retailers.join(', ') : 'Any retailer'],
            ['Purchase period', `${fmtLocal(s.purchaseStart)} to ${fmtLocal(s.purchaseEnd)}`],
            ['Claims close', fmtLocal(s.claimsClose)], ['Serial numbers by', fmtLocal(s.serialDeadline)], ['Bank details fixed by', fmtLocal(s.bankDeadline)],
            ['Minimum products', s.minProducts], ['Minimum spend', s.minSpend ? money(s.minSpend, c) + (s.singleTransaction ? ', one transaction' : '') : 'None'],
            ['Cashback', tiers], ['How it is worked out', s.mechanicNote], ['Excluded serial prefixes', (s.excludedSerialPrefixes || []).join(', ') || 'None'],
            ['Payment', `${s.paymentMethod || ''} ${s.paymentPromise || ''}`.trim()], ['Participating models', String((s.products || []).length)]
        ].map(([label, value], i) => ({ key: i, label, value }));
    }

    get issues() {
        return (this.spec.issues || []).map((x, i) => ({ key: i, ...x, cls: `issue ${x.severity}`, sev: (x.severity || '').toUpperCase() }));
    }
    get issueCount() { return (this.spec.issues || []).length; }
    get products() { return (this.spec.products || []).map((p) => ({ key: p.model, ...p })); }

    get schedRows() {
        const s = this.sched;
        if (!s) return [];
        return [
            ['Purchases', `${fmtLocal(s.purchaseStart)} to ${fmtLocal(s.purchaseEnd)}`, ''],
            ['Claims open', fmtLocal(s.claimsOpen), ''],
            ['Claims close', fmtLocal(s.claimsClose), s.claimsCloseRule],
            ['Serial numbers by', fmtLocal(s.serialDeadline), s.serialDeadlineRule],
            ['Bank details fixed by', fmtLocal(s.bankDeadline), s.bankDeadlineRule]
        ].map(([label, value, rule], i) => ({ key: i, label, value, rule }));
    }

    onTerms(e) { this.terms = e.target.value; }
    onFile(e) {
        const f = e.target.files[0];
        if (!f) return;
        if (f.type !== 'application/pdf') { this.error = 'Attach a PDF, or paste the text.'; return; }
        const r = new FileReader();
        r.onload = () => { this.pdfBase64 = String(r.result).split(',')[1]; this.pdfName = f.name; };
        r.readAsDataURL(f);
    }

    async read() {
        this.busy = true; this.error = undefined; this.spec = undefined; this.sched = undefined;
        try {
            this.spec = JSON.parse(await readTerms({ termsText: this.terms, pdfBase64: this.pdfBase64 }));
            const brand = (this.spec.brand || '').toLowerCase().replace(/[^a-z0-9]+/g, '-');
            this.opts = { ...this.opts, name: this.spec.promotionName, slug: `${brand}-cashback`, start: this.spec.purchaseStart, end: this.spec.purchaseEnd };
            await this.recalc();
        } catch (e) { this.error = this.msg(e); }
        this.busy = false;
    }

    async recalc() {
        if (!this.opts.start || !this.opts.end) return;
        try { this.sched = JSON.parse(await schedule({ specJson: JSON.stringify(this.spec), newStart: this.opts.start, newEnd: this.opts.end })); this.error = undefined; }
        catch (e) { this.sched = undefined; this.error = this.msg(e); }
    }

    onOpt(e) {
        const k = e.target.dataset.k;
        const v = e.target.type === 'checkbox' || e.target.type === 'toggle' ? e.target.checked : e.detail?.value ?? e.target.value;
        this.opts = { ...this.opts, [k]: v };
        if (k === 'start' || k === 'end') this.recalc();
    }

    async make() {
        this.busy = true; this.error = undefined;
        try {
            const id = await create({ specJson: JSON.stringify(this.spec), optionsJson: JSON.stringify(this.opts) });
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: id, objectApiName: 'Promotional_Campaign__c', actionName: 'view' } });
        } catch (e) { this.error = this.msg(e); }
        this.busy = false;
    }

    msg(e) { return e?.body?.message || e?.message || 'Something went wrong.'; }
}
