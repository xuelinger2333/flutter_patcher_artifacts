"""Resolve a safe matrix from the single local support table and pins."""
import json
import os
from pathlib import Path
import re

from tools_artifacts import require


def select(requested, versions, pins):
    require(versions and len(set(versions)) == len(versions), 'Invalid support table')
    require(all(re.fullmatch(r'\d+\.\d+\.\d+', item) for item in versions), 'Invalid version')
    require(set(versions) == set(pins), 'Support table and tool pins differ')
    selected = versions if requested == 'all' else [item.strip() for item in requested.split(',')]
    require(len(set(selected)) == len(selected), 'Duplicate Flutter version')
    require(all(item in versions for item in selected), 'Unsupported Flutter version')
    return selected


if __name__ == '__main__':
    repo = Path(__file__).resolve().parents[2]
    versions = (repo / 'supported_versions.txt').read_text().splitlines()
    pins = json.loads((repo / 'tools/versions.json').read_text())
    selected = select(os.environ.get('REQUESTED_VERSION', 'all'), versions, pins)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('matrix=' + json.dumps({'flutter_version': selected}) + '\n')
