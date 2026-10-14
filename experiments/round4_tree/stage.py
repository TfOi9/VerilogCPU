#!/usr/bin/env python3
"""Stage three isolated tree variants on the previously validated combined RTL."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
EXP = Path(__file__).resolve().parent
OUT = ROOT/'build/round4-tree-v3'
sys.path.insert(0, str(ROOT/'experiments/round3_electrical'))
from combined import stage as previous_stage, CONFIGS
from repair import digest, verify

VARIANTS = ('tree-wb', 'tree-rs', 'tree-all')


def replace_block(text, first, following, replacement):
    begin = text.index(first)
    end = text.index(following, begin+len(first))
    return text[:begin]+replacement+'\n\n'+text[end:]


def writeback(text):
    block = '''    localparam TREE_SLOT_WIDTH = SOURCE_COUNT <= 1 ? 1 : address_width_for_count(SOURCE_COUNT);
    localparam TREE_DATA_WIDTH = ROB_TAG_WIDTH + 103;
    wire [SOURCE_COUNT-1:0] tree_valid;
    wire [(SOURCE_COUNT*TREE_SLOT_WIDTH)-1:0] tree_age;
    wire [(SOURCE_COUNT*TREE_DATA_WIDTH)-1:0] tree_input;
    wire [(BE_WIDTH*TREE_DATA_WIDTH)-1:0] tree_output;
    wire [BE_WIDTH-1:0] tree_selected_valid;
    wire [(BE_WIDTH*SOURCE_COUNT)-1:0] tree_selected_mask;
    genvar tree_source;
    generate
        for (tree_source = 0; tree_source < SOURCE_COUNT;
                tree_source = tree_source + 1) begin: tree_source_data
            wire [31:0] age_full;
            assign tree_valid[tree_source] = buffer_valid[tree_source];
            assign age_full =
                tree_source >= arb_start_index ? tree_source-arb_start_index :
                tree_source+SOURCE_COUNT-arb_start_index;
            assign tree_age[tree_source*TREE_SLOT_WIDTH +: TREE_SLOT_WIDTH] =
                age_full[TREE_SLOT_WIDTH-1:0];
            assign tree_input[tree_source*TREE_DATA_WIDTH +: TREE_DATA_WIDTH] =
                {buffer_exception_tval[tree_source], buffer_exception_cause[tree_source],
                 buffer_exception_valid[tree_source], buffer_next_pc[tree_source],
                 buffer_control_taken[tree_source], buffer_control_valid[tree_source],
                 buffer_value[tree_source], buffer_rob_tag[tree_source]};
        end
    endgenerate
    rv32_ranked_select #(.ENTRIES(SOURCE_COUNT), .PORTS(BE_WIDTH),
        .SLOT_WIDTH(TREE_SLOT_WIDTH), .AGE_WIDTH(TREE_SLOT_WIDTH),
        .DATA_WIDTH(TREE_DATA_WIDTH)) tree_completion (
        .enable_i(!reset_i && !flush_i && !recover_i), .valid_i(tree_valid),
        .age_i(tree_age), .data_i(tree_input), .locked_i({BE_WIDTH{1'b0}}),
        .locked_slot_i({(BE_WIDTH*TREE_SLOT_WIDTH){1'b0}}),
        .valid_o(tree_selected_valid), .slot_o(),
        .mask_o(tree_selected_mask), .data_o(tree_output));

    always @* begin
        arb_start_index = 0;
        for (arb_source_index = 0; arb_source_index < SOURCE_COUNT;
                arb_source_index = arb_source_index + 1)
            if (round_robin_start_reg[arb_source_index])
                arb_start_index = arb_source_index;
    end

    always @* begin
        completion_valid_reg = tree_selected_valid;
        selected_source_lane_reg = tree_selected_mask;
        for (arb_scan_offset = 0; arb_scan_offset < BE_WIDTH;
                arb_scan_offset = arb_scan_offset + 1) begin
            {completion_exception_tval_reg[arb_scan_offset*32 +: 32],
             completion_exception_cause_reg[arb_scan_offset*4 +: 4],
             completion_exception_valid_reg[arb_scan_offset],
             completion_next_pc_reg[arb_scan_offset*32 +: 32],
             completion_control_taken_reg[arb_scan_offset],
             completion_control_valid_reg[arb_scan_offset],
             completion_value_reg[arb_scan_offset*32 +: 32],
             completion_tag_reg[arb_scan_offset*ROB_TAG_WIDTH +: ROB_TAG_WIDTH]} =
                tree_output[arb_scan_offset*TREE_DATA_WIDTH +: TREE_DATA_WIDTH];
        end
    end'''
    return replace_block(text, '    always @* begin\n        completion_valid_reg',
                         '    always @* begin\n        source_pop_mask_reg', block)


def reservation(text, integer_station):
    count = 'INT_RS_ENTRIES' if integer_station else 'RS_ENTRIES'
    width = 'INT_RS_INDEX_WIDTH' if integer_station else 'RS_INDEX_WIDTH'
    ports = 'BE_WIDTH' if integer_station else '1'
    payload = '`RV32_OP_WIDTH + 128 + ROB_TAG_WIDTH' if integer_station else '`RV32_OP_WIDTH + 64 + ROB_TAG_WIDTH'
    data = ('{entry_rob_tag[tree_entry], entry_immediate[tree_entry], entry_pc[tree_entry], '
            'effective_rhs_value[tree_entry], effective_lhs_value[tree_entry], entry_op[tree_entry]}' if integer_station else
            '{entry_rob_tag[tree_entry], effective_rhs_value[tree_entry], effective_lhs_value[tree_entry], entry_op[tree_entry]}')
    lock = '''            assign tree_locked[tree_port] = issue_locked[tree_port];
            assign tree_locked_slot[tree_port*TREE_SLOT_WIDTH +: TREE_SLOT_WIDTH] =
                issue_locked_slot[tree_port];''' if integer_station else '''            assign tree_locked[tree_port] = request_locked;
            assign tree_locked_slot[tree_port*TREE_SLOT_WIDTH +: TREE_SLOT_WIDTH] = request_locked_slot;'''
    block = f'''    localparam TREE_SLOT_WIDTH = {width};
    localparam TREE_ENTRIES = {count};
    localparam TREE_PORTS = {ports};
    localparam TREE_DATA_WIDTH = {payload};
    wire [TREE_ENTRIES-1:0] tree_valid;
    wire [(TREE_ENTRIES*ROB_INDEX_WIDTH)-1:0] tree_age;
    wire [(TREE_ENTRIES*TREE_DATA_WIDTH)-1:0] tree_input;
    wire [(TREE_PORTS*TREE_DATA_WIDTH)-1:0] tree_output;
    wire [TREE_PORTS-1:0] tree_selected_valid;
    wire [(TREE_PORTS*TREE_SLOT_WIDTH)-1:0] tree_selected_slot;
    wire [TREE_PORTS-1:0] tree_locked;
    wire [(TREE_PORTS*TREE_SLOT_WIDTH)-1:0] tree_locked_slot;
    genvar tree_entry, tree_port;
    generate
        for (tree_entry = 0; tree_entry < TREE_ENTRIES;
                tree_entry = tree_entry + 1) begin: tree_candidate
            assign tree_valid[tree_entry] = entry_busy[tree_entry] &&
                effective_lhs_ready[tree_entry] && effective_rhs_ready[tree_entry];
            assign tree_age[tree_entry*ROB_INDEX_WIDTH +: ROB_INDEX_WIDTH] =
                rob_distance(entry_rob_tag[tree_entry][ROB_INDEX_WIDTH-1:0], rob_head_index_i);
            assign tree_input[tree_entry*TREE_DATA_WIDTH +: TREE_DATA_WIDTH] = {data};
        end
        for (tree_port = 0; tree_port < TREE_PORTS;
                tree_port = tree_port + 1) begin: tree_lock
{lock}
        end
    endgenerate
    rv32_ranked_select #(.ENTRIES(TREE_ENTRIES), .PORTS(TREE_PORTS),
        .SLOT_WIDTH(TREE_SLOT_WIDTH), .AGE_WIDTH(ROB_INDEX_WIDTH),
        .DATA_WIDTH(TREE_DATA_WIDTH)) tree_issue (
        .enable_i(!reset_i && !flush_i && !recover_i), .valid_i(tree_valid),
        .age_i(tree_age), .data_i(tree_input), .locked_i(tree_locked),
        .locked_slot_i(tree_locked_slot), .valid_o(tree_selected_valid),
        .slot_o(tree_selected_slot), .mask_o(), .data_o(tree_output));
'''
    if integer_station:
        block += '''    always @* begin
        issue_valid_reg = tree_selected_valid;
        for (selection_port_index = 0; selection_port_index < BE_WIDTH;
                selection_port_index = selection_port_index + 1) begin
            issue_slot_valid_reg[selection_port_index] = tree_selected_valid[selection_port_index];
            issue_slot_reg[selection_port_index] =
                tree_selected_slot[selection_port_index*TREE_SLOT_WIDTH +: TREE_SLOT_WIDTH];
            {issue_rob_tag_reg[selection_port_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH],
             issue_immediate_reg[selection_port_index*32 +: 32],
             issue_pc_reg[selection_port_index*32 +: 32],
             issue_rhs_reg[selection_port_index*32 +: 32],
             issue_lhs_reg[selection_port_index*32 +: 32],
             issue_op_reg[selection_port_index*`RV32_OP_WIDTH +: `RV32_OP_WIDTH]} =
                tree_output[selection_port_index*TREE_DATA_WIDTH +: TREE_DATA_WIDTH];
        end
    end'''
        return replace_block(text, '    always @* begin\n        selection_port_index = 0;',
                             '    always @* begin\n        issue_fire_reg', block)
    block += '''    always @* begin
        request_valid_reg = tree_selected_valid[0];
        request_slot_valid_reg = tree_selected_valid[0];
        request_slot_reg = tree_selected_slot;
        {request_rob_tag_reg, request_rhs_reg, request_lhs_reg, request_op_reg} = tree_output;
    end'''
    return replace_block(text, '    always @* begin\n        selection_entry_index = 0;',
                         '    always @* begin\n        issue_remove_mask_reg', block)


def stage():
    verify()
    source = previous_stage()
    OUT.mkdir(parents=True, exist_ok=True)
    marker = OUT/'manifest.json'
    definition = {str(p): digest(p) for p in (EXP/'stage.py', EXP/'rv32_ranked_select.v')}
    if marker.exists():
        manifest = json.loads(marker.read_text())
        if manifest['definition_sha256'] != definition:
            raise ValueError('experiment definition changed; start a fresh output namespace')
        for hashes in manifest['variants'].values():
            if any(digest(Path(p)) != sha for p, sha in hashes.items()):
                raise ValueError('isolated source changed')
        return manifest
    variants = {}
    for variant in VARIANTS:
        dest = OUT/variant
        shutil.copytree(source/'rtl', dest/'rtl')
        shutil.copytree(source/'tb', dest/'tb')
        shutil.copyfile(source/'generate_int_rs_vectors.py', dest/'generate_int_rs_vectors.py')
        shutil.copyfile(EXP/'rv32_ranked_select.v', dest/'rtl/rv32_ranked_select.v')
        if variant in ('tree-wb', 'tree-all'):
            p = dest/'rtl/rv32_completion_writeback_network.v'
            p.write_text(writeback(p.read_text()))
        if variant in ('tree-rs', 'tree-all'):
            for name, integer in (('rv32_integer_reservation_station.v', True), ('rv32_mdu_reservation_stations.v', False)):
                p = dest/'rtl'/name
                p.write_text(reservation(p.read_text(), integer))
        (dest/'unit').mkdir()
        make = (source/'Makefile.unit').read_text().replace(str(source), str(dest))
        make = make.replace('iverilog ', 'iverilog -y '+str(dest/'rtl')+' ')
        make = make.replace('verilator ', 'verilator -y '+str(dest/'rtl')+' ')
        make = make.replace('read_verilog ', 'read_verilog -D SYNTHESIS '+str(dest/'rtl/rv32_ranked_select.v')+'; read_verilog ')
        (dest/'Makefile.unit').write_text(make)
        names = [Path(p).name for p in (source/'filelist.f').read_text().splitlines()]
        (dest/'filelist.f').write_text('\n'.join(str(dest/'rtl'/n) for n in names+['rv32_ranked_select.v'])+'\n')
        variants[variant] = {str(p): digest(p) for p in sorted(dest.rglob('*')) if p.is_file()}
    manifest = {'base': 'round3 combined', 'definition_sha256': definition, 'variants': variants}
    marker.write_text(json.dumps(manifest, indent=2)+'\n')
    return manifest


if __name__ == '__main__':
    stage()
    print('Three tree snapshots staged')
