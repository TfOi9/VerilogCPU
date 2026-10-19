import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--package', type=Path, required=True)
p.add_argument('--image', required=True)
p.add_argument('--platform', required=True)
p.add_argument('--seconds', type=int, default=1800)
a = p.parse_args()
root = a.package.resolve()
out = root.parent / (root.name + '-build')
out.mkdir(exist_ok=False)
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
inputs = [x for x in root.rglob('*') if x.is_file()]
before = {str(x.relative_to(root)): digest(x) for x in inputs}
name = 'verilogcpu-build-' + str(time.time_ns())
command = ['docker', 'run', '--rm', '--name', name, '--platform', a.platform,
           '--network', 'none', '--pids-limit', '512', '--memory', '4g',
           '-v', str(root) + ':/work', '-w', '/work', a.image, 'make']
result = dict(completed=False, passed=False, command=command, source_sha256=before)
def save():
    (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
save()
started = time.monotonic()
try:
    with (out/'build.log').open('w') as log:
        process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=a.seconds)
    result.update(returncode=process.returncode, sources_unchanged=all(digest(root/n)==h for n,h in before.items()))
    assert process.returncode == 0 and result['sources_unchanged']
    result.update(code_sha256=digest(root/'code'), completed=True, passed=True)
except BaseException as error:
    subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=15)
    result.update(completed=True, passed=False, error=repr(error))
    raise
finally:
    result['elapsed_seconds'] = time.monotonic()-started
    save()
print('PASS standalone default make', a.platform, result['elapsed_seconds'], flush=True)
