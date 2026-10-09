#!/usr/bin/env python3
"""Inspect the archive; optionally tolerate only the preview's missing URL."""
import argparse
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--allow-missing-repository', action='store_true')
args = parser.parse_args()
result = subprocess.run(['dart', 'pub', 'publish', '--dry-run'], capture_output=True, text=True)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
combined = result.stdout + result.stderr
expected = 'It\'s strongly recommended to include a "homepage" or "repository" field'
if (args.allow_missing_repository and result.returncode == 65
        and 'Package has 1 warning.' in combined and expected in combined):
    print('Preview archive checked. Publication still requires the owner repository/homepage URL.', file=sys.stderr)
    sys.exit(0)
sys.exit(result.returncode)
