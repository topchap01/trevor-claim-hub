#!/usr/bin/env bash
# Runs every claim hub Apex test in an org and prints pass/fail and coverage per class.
# Usage: scripts/run-apex-tests.sh <org alias>   (e.g. wizard)
set -euo pipefail
ORG="${1:?org alias}"
cd "$(dirname "$0")/../salesforce"
CLASSES=$(ls force-app/main/default/classes/*Test.cls | xargs -n1 basename | sed 's/\.cls$//' | sed 's/^/--class-names /' | tr '\n' ' ')
OUT=$(mktemp)
# shellcheck disable=SC2086
sf apex run test -o "$ORG" $CLASSES --code-coverage --result-format json --wait 30 > "$OUT" || true
python3 - "$OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); r = d.get('result', d); s = r.get('summary', {})
print(f"Tests: {s.get('testsRan')} ran, {s.get('passing')} passed, {s.get('failing')} failed, {s.get('testExecutionTime')}")
for t in r.get('tests', []):
    if t['Outcome'] != 'Pass':
        print('FAIL', t['FullName'], '|', (t.get('Message') or '')[:300], '|', (t.get('StackTrace') or '')[:200])
rows = [c for c in r.get('coverage', {}).get('coverage', []) if c['name'].startswith(('ClaimHub', 'ClaimAccess'))]
cov = sum(c['totalCovered'] for c in rows); tot = sum(c['totalLines'] for c in rows)
for c in sorted(rows, key=lambda c: c['name']): print(f"  {c['name']:<28} {c['coveredPercent']:>3}%  ({c['totalCovered']}/{c['totalLines']})")
print(f"Claim hub coverage: {round(100*cov/max(tot,1))}% ({cov}/{tot} lines)")
sys.exit(1 if s.get('failing') else 0)
PY
