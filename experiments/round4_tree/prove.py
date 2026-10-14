#!/usr/bin/env python3
"""Prove outputs and state inputs for arbitrary shared state at each RTL boundary."""
import concurrent.futures
import json
from stage import ROOT, OUT, CONFIGS, stage, digest
from repair import execute

MODULES = ('rv32_completion_writeback_network', 'rv32_integer_reservation_station',
           'rv32_mdu_reservation_station_core')


def yosys(commands, dest, name):
    script = dest/(name+'.ys')
    script.write_text('\n'.join(commands)+'\n')
    execute([ROOT/'.deps/yosys/bin/yosys', '-Q', '-T', '-s', script], dest/(name+'.log'), 240)


def prepare(path, module, params, dest, name):
    commands = ['read_verilog -D SYNTHESIS -I '+str(OUT/'tree-all/rtl')+' '+str(path),
                'read_verilog '+str(OUT/'tree-all/rtl/rv32_ranked_select.v'),
                'chparam '+' '.join('-set '+k+' '+str(v) for k, v in params.items())+' '+module,
                'hierarchy -check -top '+module, 'proc', 'memory', 'flatten', 'opt',
                'dffunmap', 'techmap', 'opt_clean', 'check -assert',
                'write_json '+str(dest/(name+'.json'))]
    yosys(commands, dest, name)
    return json.loads((dest/(name+'.json')).read_text())['modules'][module]


def state(top):
    cells = {n: c for n, c in top['cells'].items() if c['type'].startswith('$_DFF_')}
    unsupported = [c['type'] for c in top['cells'].values()
                   if c['type'].startswith(('$_DFFE', '$_SDFF', '$_ADFF', '$dff', '$mem', '$_DLATCH'))]
    if unsupported or not cells:
        raise ValueError('unsupported or missing state '+repr(unsupported[:4]))
    by_q = {}
    for name, cell in cells.items():
        if len(cell['connections']['Q']) != 1 or len(cell['connections']['D']) != 1:
            raise ValueError('expected scalar state after techmap')
        q = cell['connections']['Q'][0]
        if q in by_q:
            raise ValueError('multiply driven state')
        by_q[q] = (name, cell)
    aliases = {(n, i): b for n, net in top['netnames'].items() if not net.get('hide_name')
               for i, b in enumerate(net['bits']) if b in by_q}
    return by_q, aliases


def cut(gold, gate, dest, module):
    gstate, ga = state(gold)
    tstate, ta = state(gate)
    common = sorted(ga.keys() & ta.keys())
    pairs = {}
    for alias in common:
        gq, tq = ga[alias], ta[alias]
        if gq in pairs and pairs[gq] != tq:
            raise ValueError('state alias relation changed')
        pairs[gq] = tq
    if set(pairs) != set(gstate) or set(pairs.values()) != set(tstate) or len(gstate) != len(tstate):
        raise ValueError('state correspondence is incomplete')
    ordered = sorted(pairs.items(), key=lambda pair: next(a for a in common if ga[a] == pair[0]))
    def port_names(top):
        return {b: (n, i) for n, p in top['ports'].items() for i, b in enumerate(p['bits'])}
    gp, tp = port_names(gold), port_names(gate)
    if {n: (p['direction'], len(p['bits'])) for n, p in gold['ports'].items()} != {
            n: (p['direction'], len(p['bits'])) for n, p in gate['ports'].items()}:
        raise ValueError('top interface changed')
    correspondence = []
    for i, (gq, tq) in enumerate(ordered):
        gn, gc = gstate[gq]
        tn, tc = tstate[tq]
        if gc['type'] != tc['type'] or gc['parameters'] != tc['parameters']:
            raise ValueError('state type changed')
        if gp.get(gc['connections']['C'][0]) != tp.get(tc['connections']['C'][0]) or gc['connections']['C'][0] not in gp:
            raise ValueError('clock input correspondence differs')
        correspondence.append({'state_id': i, 'alias': next(a for a in common if ga[a] == gq),
                               'gold_cell': gn, 'gate_cell': tn, 'type': gc['type']})
        for top, cell, name, q in ((gold, gc, gn, gq), (gate, tc, tn, tq)):
            top['ports']['proof_state_'+str(i)] = {'direction': 'input', 'bits': [q]}
            top['ports']['proof_next_'+str(i)] = {'direction': 'output', 'bits': cell['connections']['D']}
            del top['cells'][name]
    (dest/'state-correspondence.json').write_text(json.dumps(correspondence, indent=2)+'\n')
    for name, top in (('gold', gold), ('gate', gate)):
        path = dest/(name+'-cut.json')
        path.write_text(json.dumps({'modules': {module: top}})+'\n')
        yosys(['read_json '+str(path), 'hierarchy -check -top '+module,
               'check -assert', 'write_blif '+str(dest/(name+'.blif'))], dest, name+'-cut')
    return correspondence


def prove(job):
    module, config, *extra = job
    op_class = extra[0] if extra else 0
    fe, be, phys, rob = config
    name = '{}x{}-p{}-r{}'.format(*config)
    dest = OUT/'proof'/module/(name+('-div' if op_class else ''))
    dest.mkdir(parents=True, exist_ok=True)
    filename = 'rv32_mdu_reservation_stations.v' if module.startswith('rv32_mdu_') else module+'.v'
    original = ROOT/'build/round3-electrical/combined/rtl'/filename
    modified = OUT/'tree-all/rtl'/filename
    source_hashes = {str(p): digest(p) for p in (original, modified, OUT/'tree-all/rtl/rv32_ranked_select.v')}
    if (dest/'result.json').exists():
        cached = json.loads((dest/'result.json').read_text())
        if cached.get('passed') and cached['source_sha256'] == source_hashes and cached.get('op_class', 0) == op_class:
            return cached
        raise ValueError('proof sources changed')
    params = {'BE_WIDTH': be, 'PHYS_REGS': phys, 'PHYS_REG_ADDR_WIDTH': (phys-1).bit_length(),
              'ROB_TAG_WIDTH': (rob-1).bit_length()+2}
    if module == 'rv32_completion_writeback_network':
        params['SOURCE_COUNT'] = be+2
    else:
        params.update(ROB_ENTRIES=rob, ROB_INDEX_WIDTH=(rob-1).bit_length())
        if module.startswith('rv32_mdu_'):
            params['OP_CLASS'] = op_class
    gold = prepare(original, module, params, dest, 'gold')
    gate = prepare(modified, module, params, dest, 'gate')
    states = cut(gold, gate, dest, module)
    result = execute([ROOT/'.deps/yosys/bin/yosys-abc', '-c', 'cec '+str(dest/'gold.blif')+' '+str(dest/'gate.blif')],
                     dest/'cec.log', 600)
    if 'Networks are equivalent' not in (dest/'cec.log').read_text():
        raise ValueError('arbitrary-state combinational equivalence failed')
    result.update(passed=True, module=module, config=name, state_bits=len(states), op_class=op_class,
                  proof='all primary outputs and each original state D, with shared arbitrary state Q',
                  source_sha256=source_hashes)
    (dest/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PROVEN', module, name, len(states), flush=True)
    return result


if __name__ == '__main__':
    stage()
    jobs = [(m, c) for c in CONFIGS[::-1] for m in MODULES]
    jobs += [('rv32_mdu_reservation_station_core', c, 1) for c in CONFIGS]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(prove, jobs))
    (OUT/'rtl-equivalence.json').write_text(json.dumps(results, indent=2)+'\n')
    stage()
