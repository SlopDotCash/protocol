#!/usr/bin/env python3
"""Restore the exact dependency revisions used by foundry.lock, without branch resolution."""
import argparse
import concurrent.futures
import io
import json
from pathlib import Path
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPOS = {
    'continuous-clearing-auction': 'Uniswap/continuous-clearing-auction',
    'forge-std': 'foundry-rs/forge-std',
    'liquidity-launcher': 'Uniswap/liquidity-launcher',
    'metavest': 'MetaLex-Tech/MetaVesT',
    'openzeppelin-contracts': 'OpenZeppelin/openzeppelin-contracts',
    'solady': 'Vectorized/solady',
    'universal-router': 'Uniswap/universal-router',
    'v2-core': 'Uniswap/v2-core',
    'v3-core': 'Uniswap/v3-core',
    'v4-core': 'Uniswap/v4-core',
    'v4-periphery': 'Uniswap/v4-periphery',
}
# Gitlink revisions from the pinned parents; only nested sources reachable under remappings.
NESTED = [
    ('lib/v4-core/lib/solmate', 'transmissions11/solmate', '4b47a19038b798b4a33d9749d25e570443520647'),
    ('lib/v4-periphery/lib/permit2', 'Uniswap/permit2', 'cc56ad0f3439c502c246fc5cfcc3db92bb8b7219'),
    ('lib/universal-router/lib/v3-periphery', 'Uniswap/v3-periphery', 'b325bb0905d922ae61fcc7df85ee802e8df5e96c'),
    ('lib/continuous-clearing-auction/lib/blocknumberish', 'Uniswap/blocknumberish', '38fe20bc0341d5bc2780d41f90dadb70e10f8cea'),
]


def restore(root, path, repo, revision):
    target = root / path
    marker = target / '.dependency-revision'
    if marker.exists() and marker.read_text().strip() == revision:
        return f'{path}: {revision} already installed'
    if target.exists() and any(target.iterdir()):
        raise RuntimeError(f'{target} is not an empty managed destination; preserve it and use a fresh --destination')
    urls = [f'https://codeload.github.com/{repo}/tar.gz/{revision}',
            f'https://api.github.com/repos/{repo}/tarball/{revision}']
    for attempt in range(4):
        try:
            request = urllib.request.Request(urls[attempt % 2], headers={'User-Agent': 'umia-pinned-dependencies'})
            with urllib.request.urlopen(request, timeout=120) as response:
                archive = response.read()
            break
        except Exception:
            if attempt == 3:
                raise
            time.sleep(attempt + 1)
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        members = tar.getmembers()
        prefix = members[0].name.split('/')[0] + '/'
        for member in members:
            if not member.name.startswith(prefix):
                continue
            member.name = member.name[len(prefix):]
            if member.name:
                # Python's data filter rejects traversal and escaping links.
                tar.extract(member, target, filter='data')
    marker.write_text(revision + '\n')
    return f'{path}: installed {revision}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=ROOT, help='project root to receive lib/')
    args = parser.parse_args()
    lock = json.loads((ROOT / 'foundry.lock').read_text())
    parents = [(path, REPOS[Path(path).name], item.get('rev') or item['tag']['rev'])
               for path, item in lock.items()]
    # Parents must finish before nested destinations are populated.
    for batch in (parents, NESTED):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            jobs = [executor.submit(restore, args.destination, *item) for item in batch]
            for job in jobs:
                print(job.result(), flush=True)


if __name__ == '__main__':
    main()
