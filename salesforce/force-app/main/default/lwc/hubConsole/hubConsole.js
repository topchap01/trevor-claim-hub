import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import campaigns from '@salesforce/apex/ClaimHubConsole.campaigns';
import summary from '@salesforce/apex/ClaimHubConsole.summary';
import approve from '@salesforce/apex/ClaimHubConsole.approve';
import reject from '@salesforce/apex/ClaimHubConsole.reject';
import reasons from '@salesforce/apex/ClaimHubConsole.reasons';
import invoiceLink from '@salesforce/apex/ClaimHubConsole.invoiceLink';

export default class HubConsole extends NavigationMixin(LightningElement) {
    options = [];
    campaignId;
    s;
    error;
    busy = false;
    reasonOptions = [];
    rejecting;
    reason;

    @wire(reasons) wiredReasons({ data }) { if (data) this.reasonOptions = data; }

    async connectedCallback() {
        try {
            this.options = await campaigns();
            if (this.options.length) { this.campaignId = this.options[0].value; await this.load(); }
        } catch (e) { this.error = this.msg(e); }
    }

    async load() {
        this.busy = true; this.error = undefined;
        try { this.s = await summary({ campaignId: this.campaignId }); } catch (e) { this.error = this.msg(e); }
        this.busy = false;
    }

    get hasCampaign() { return !!this.s; }
    get noCampaigns() { return !this.busy && this.options.length === 0; }
    get queueCount() { return this.s ? this.s.queue.length : 0; }
    get readyCount() { return this.s ? this.s.ready.length : 0; }
    get issueCount() { return this.s ? this.s.issues.length : 0; }
    get stateClass() { return 'state ' + (this.s && this.s.state === 'Open for claims' ? 'open' : 'shut'); }
    get readyRows() {
        return (this.s?.ready || []).map((r) => ({ ...r, isRejecting: this.rejecting === r.id, invCls: r.clean ? 'pill ok' : 'pill warn' }));
    }

    pick(e) { this.campaignId = e.detail.value; this.load(); }
    refresh() { this.load(); }
    newFromTerms() { this[NavigationMixin.Navigate]({ type: 'standard__navItemPage', attributes: { apiName: 'Hub_Campaign_Builder' } }); }
    openCampaign() { this.openRecord(this.s.id, 'Promotional_Campaign__c'); }
    openClaim(e) { e.preventDefault(); this.openRecord(e.currentTarget.dataset.id, 'Entry__c'); }
    openRecord(recordId, objectApiName) {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }

    async doApprove(e) {
        this.busy = true;
        try { await approve({ entryId: e.currentTarget.dataset.id }); await this.load(); } catch (x) { this.error = this.msg(x); this.busy = false; }
    }
    async viewInvoice(e) {
        try {
            const url = await invoiceLink({ entryId: e.currentTarget.dataset.id });
            if (!url) { this.error = 'No invoice file on this claim yet.'; return; }
            this[NavigationMixin.Navigate]({ type: 'standard__webPage', attributes: { url } });
        } catch (x) { this.error = this.msg(x); }
    }
    startReject(e) { this.rejecting = e.currentTarget.dataset.id; this.reason = undefined; }
    cancelReject() { this.rejecting = undefined; }
    pickReason(e) { this.reason = e.detail.value; }
    async doReject() {
        this.busy = true;
        try { await reject({ entryId: this.rejecting, reason: this.reason }); this.rejecting = undefined; await this.load(); }
        catch (x) { this.error = this.msg(x); this.busy = false; }
    }

    msg(e) { return e?.body?.message || e?.message || 'Something went wrong.'; }
}
