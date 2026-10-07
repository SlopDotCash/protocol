#!/usr/bin/env python3
"""Check that the published contract ABI manifest matches the current Forge artifacts."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
names = re.findall(r'"([A-Z][A-Za-z0-9]+)"', (root / 'abi/src/contracts.ts').read_text())

def normalized(abi):
    # Solidity's item ordering is not ABI semantics; parameter/component ordering is.
    return sorted(json.dumps(item, sort_keys=True) for item in abi)

failures = []
for name in names:
    built = json.loads((root / 'out' / f'{name}.sol' / f'{name}.json').read_text())['abi']
    exported = json.loads((root / 'abi/json' / f'{name}.json').read_text())
    if normalized(built) != normalized(exported):
        failures.append(name)
if failures:
    raise SystemExit('Exported ABIs differ from compiled source: ' + ', '.join(failures))
print(f'All {len(names)} published ABIs match compiled source.')
