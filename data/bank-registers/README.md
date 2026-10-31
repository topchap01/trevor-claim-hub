# Bank registers

The public registers the claim hub checks bank details against (decisions.md #11). Merging new files here into `main` runs the **Load bank registers (Wizard)** GitHub job, which loads them into `Hub_Bank_Branch__c` in the Wizard sandbox. The monthly refresh is in docs/runbook.md.

| File | Source | This version |
|---|---|---|
| `nz-bank-branch-register.csv` | Payments NZ Bank Branch Register, CSV download | 1 November 2026: 3,295 branches, all status A |
| `au-bsb-directory.csv` | AusPayNet BSB directory, full version, CSV | Added 31 October 2026: 17,266 BSBs, of which 39 are listed as "Closed" and 398 as "Merged" |
| `au-key-to-abbreviations.csv` *(optional, not yet added)* | AusPayNet *Key to Abbreviations* | Gives full bank names; without it the form shows the short code, e.g. CBA |

Keep the file names the same each month, so the job finds them and git keeps each month's version in the history. These are public reference data: no personal data belongs in this folder.
