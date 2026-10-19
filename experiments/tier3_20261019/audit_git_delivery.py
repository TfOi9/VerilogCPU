"""Bind a committed Git tree to the exact qualified runtime and gate inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--repo', type=Path, required=True)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--runtime', type=Path, required=True)
p.add_argument('--gates', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
def git(*args):
    return subprocess.check_output(['git', '-C', str(a.repo), *args])
commit = git('rev-parse', 'HEAD').decode().strip()
assert not git('status', '--porcelain'), 'The delivery checkout is not clean'
expected = json.loads(a.runtime.read_text())['source_sha256']
for name in ('strict-lint', 'unit-hum', 'suite', 'retirement', 'raw-ppa', 'matrix'):
    gate = json.loads((a.gates/(name+'.exit.json')).read_text())
    assert gate['completed'] and gate['passed'] and gate['sources_unchanged'] and gate['returncode']==0
    for absolute, digest in gate['source_sha256'].items():
        relative = str(Path(absolute).relative_to(a.source))
        if relative in expected:
            assert expected[relative] == digest
        expected[relative] = digest
for name, digest in expected.items():
    assert hashlib.sha256(git('show',commit+':'+name)).hexdigest() == digest, name
result = dict(completed=True, passed=True, commit=commit, branch=git('branch','--show-current').decode().strip(), clean=True, verified_files=len(expected), source_sha256=expected)
a.out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ('passed','commit','branch','clean','verified_files')}))
