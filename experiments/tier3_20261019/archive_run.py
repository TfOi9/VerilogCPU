"""Preserve candidate sources and bounded run evidence without generated binaries."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

p = argparse.ArgumentParser()
p.add_argument('--root', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
root = a.root.resolve()
files = set()
for path in root.iterdir():
    if path.is_symlink():
        continue
    if path.is_file() and path.suffix in ('.json', '.py', '.patch', '.txt'):
        files.add(path)
    if not path.is_dir():
        continue
    if (path/'rtl').is_dir():
        for name in ('.gitignore', 'Makefile', 'README.md', 'rv32im_defs.vh'):
            if (path/name).is_file():
                files.add(path/name)
        for name in ('rtl', 'tb', 'tools', 'docs', 'experiments/tier3_20261019', 'verilog'):
            files.update(x for x in (path/name).rglob('*') if x.is_file() and not x.is_symlink() and '__pycache__' not in x.parts)
    if 'gates' in path.name or path.name == 'evidence-stage':
        files.update(x for x in path.iterdir() if x.is_file() and x.suffix in ('.json', '.log'))
    for name in ('results.json', 'suite-results.json', 'screen-results.json', 'snapshot.json', 'configuration.json'):
        if (path/name).is_file():
            files.add(path/name)
    if (path/'opt/report.json').is_file():
        for name in ('report.json', 'stat.json', 'synth.log', 'elaborate.log', 'synth.ys', 'timing.log', 'timing.tcl'):
            if (path/'opt'/name).is_file():
                files.add(path/'opt'/name)
    if 'native-runtime' in path.name:
        files.update(x for x in path.rglob('*') if x.is_file() and x.suffix in ('.json', '.stdout', '.stderr'))
files = sorted(files)
manifest = {str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in files}
a.out.parent.mkdir(parents=True, exist_ok=True)
assert not a.out.exists(), a.out
with tarfile.open(a.out, 'w:gz') as archive:
    for x in files:
        archive.add(x, arcname=str(x.relative_to(root)), recursive=False)
assert all(hashlib.sha256((root/n).read_bytes()).hexdigest()==h for n,h in manifest.items())
a.out.with_suffix(a.out.suffix+'.manifest.json').write_text(json.dumps(dict(completed=True, files=manifest, archive_sha256=hashlib.sha256(a.out.read_bytes()).hexdigest()),indent=2)+'\n')
print(json.dumps(dict(files=len(files),bytes=a.out.stat().st_size,sha256=hashlib.sha256(a.out.read_bytes()).hexdigest())))
