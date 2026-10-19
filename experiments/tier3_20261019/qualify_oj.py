#!/usr/bin/env python3
"""Qualify an unmodified OJ executable in a bounded read-only Linux container."""
import argparse
import ast
import hashlib
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--framework', type=Path, required=True)
    parser.add_argument('--cases', type=Path, required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--platform', default='linux/amd64')
    parser.add_argument('--seconds', type=int, default=100)
    parser.add_argument('--trace', action='store_true')
    args = parser.parse_args()
    package = args.package.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(args.framework/'scripts'))
    from oj_io import prepare_case, compare_output
    inputs = [p for directory in ('rtl', 'verilog', 'third_party') for p in (package/directory).rglob('*') if p.is_file() and p.suffix in ('.v', '.vh', '.sv', '.f', '.py', '.cpp')]
    inputs += [package/'Makefile', package/'rv32im_defs.vh', package/'third_party/cpu2026/Makefile']
    source_hashes = {str(p.relative_to(package)): digest(p) for p in inputs}
    result = {'completed': False, 'passed': False, 'source_sha256': source_hashes, 'code_sha256': digest(package/'code'),
              'runner_sha256': digest(Path(__file__)), 'platform': args.platform, 'memory_limit_bytes': 320*1024*1024,
              'filesystem_read_only': True, 'file_size_limit_bytes': 0, 'network': 'none', 'trace_enabled': args.trace,
              'per_case_seconds': args.seconds, 'cases': []}
    def save():
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    save()
    try:
        inspect = subprocess.check_output(['docker', 'image', 'inspect', args.image], text=True)
        (out/'image.json').write_text(inspect)
        result['image_id'] = json.loads(inspect)[0]['Id']
        for case in sorted(args.cases.iterdir()):
            if not (case/'program.data').is_file():
                continue
            data, expected = prepare_case(case, 30_000_000, 10)
            (out/(case.name+'.in')).write_text(data)
            (out/(case.name+'.ans')).write_text(expected)
            name = 'verilogcpu-oj-'+str(time.time_ns())
            command = ['docker', 'run', '--rm', '--name', name, '--platform', args.platform,
                       '--network', 'none', '--read-only', '--cap-drop', 'ALL',
                       '--security-opt', 'no-new-privileges', '--pids-limit', '128',
                       '--memory', '320m', '--memory-swap', '320m', '--ulimit', 'fsize=0:0', '--user', '65534:65534',
                       '-i', '-v', str(package)+':/work:ro', '-w', '/work', args.image,
                       '/usr/bin/time', '-v']
            if args.trace:
                command += ['strace', '-f', '-qq', '-e', 'trace=%file,write,writev,pwrite64,pwritev']
            command += ['./code']
            (out/(case.name+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
            started = time.monotonic()
            try:
                process = subprocess.run(command, input=data, text=True, capture_output=True,
                                         timeout=args.seconds+30)
            except subprocess.TimeoutExpired as error:
                subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=15)
                (out/(case.name+'.stdout')).write_bytes(error.stdout or b'')
                (out/(case.name+'.stderr')).write_bytes(error.stderr or b'')
                raise
            elapsed = time.monotonic()-started
            (out/(case.name+'.stdout')).write_text(process.stdout)
            (out/(case.name+'.stderr')).write_text(process.stderr)
            assert process.returncode == 0, (case.name, process.returncode, process.stderr[-2000:])
            assert compare_output(process.stdout, expected) is None, case.name
            program_stderr = process.stderr
            if args.trace:
                writes = re.findall(r'write\(2, ("(?:[^"\\]|\\.)*"),', process.stderr)
                program_stderr = ''.join(ast.literal_eval(value) for value in writes)
            cycles = re.search(r'CPU2026 cycles=(\d+)', program_stderr)
            rss = re.search(r'Maximum resident set size \(kbytes\): (\d+)', process.stderr)
            assert cycles and rss, case.name
            assert int(rss[1])*1024 <= result['memory_limit_bytes'], case.name
            assert elapsed <= args.seconds, (case.name, elapsed)
            if args.trace:
                assert not re.search(r'\bO_(?:WRONLY|RDWR|CREAT|TRUNC|APPEND)\b', process.stderr), case.name
                assert not re.search(r'\b(?:creat|unlink|unlinkat|rename|renameat|renameat2|mkdir|mkdirat|rmdir|truncate|chmod|fchmodat|chown|lchown|link|linkat|symlink|symlinkat|mknod|mknodat|utime|utimes|utimensat)\(', process.stderr), case.name
                for match in re.finditer(r'\b(?:write|writev|pwrite64|pwritev)\((\d+),', process.stderr):
                    assert int(match[1]) in (1, 2), (case.name, match[0])
            row = {'name': case.name, 'passed': True, 'cycles': int(cycles[1]),
                   'maximum_rss_bytes': int(rss[1])*1024, 'elapsed_seconds_including_container': elapsed,
                   'input_sha256': digest(out/(case.name+'.in')),
                   'stdout_sha256': digest(out/(case.name+'.stdout')),
                   'stderr_sha256': digest(out/(case.name+'.stderr'))}
            if case.name.startswith('perf_'):
                row['dynamic_instructions'] = json.loads((case/'metrics.json').read_text())['dynamic_instructions']
                row['ipc'] = row['dynamic_instructions']/row['cycles']
            result['cases'].append(row)
            save()
            print('PASS OJ', case.name, row['cycles'], row['maximum_rss_bytes'], round(elapsed, 3), flush=True)
        assert len(result['cases']) == 25
        perf = [c['ipc'] for c in result['cases'] if 'ipc' in c]
        assert len(perf) == 6
        result['ipc_geomean'] = math.exp(sum(map(math.log, perf))/6)
        assert digest(package/'code') == result['code_sha256']
        assert all(digest(package/p) == h for p, h in source_hashes.items())
        result.update(completed=True, passed=True)
    except BaseException as error:
        result.update(completed=True, passed=False, error=type(error).__name__+': '+str(error))
        raise
    finally:
        save()
    print('PASS OJ Linux', len(result['cases']), result['ipc_geomean'], flush=True)


if __name__ == '__main__':
    main()
