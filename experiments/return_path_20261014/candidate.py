#!/usr/bin/env python3
"""Build isolated valid-independent payload routing candidates."""
import argparse
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--variant', choices=('metadata', 'metadata-wb', 'rs-retain', 'metadata-wb-rs'), required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    for name in ('rtl', 'verilog'):
        shutil.copytree(args.source/name, args.out/name)
    path = args.out/'rtl/rv32_load_store_queue.v'
    text = path.read_text()
    old = '    wire response_bypass;'
    assert text.count(old) == 1
    text = text.replace(old, old+'\n    wire response_payload;')
    old = '    assign response_bypass = '
    assert text.count(old) == 1
    text = text.replace(old, '    assign response_payload = LOAD_FALLTHROUGH != 0 && !source_valid;\n'+old)
    for old in ('completion_rob_tag_o = response_bypass ?', 'completion_value_o = response_bypass ?',
                'completion_exception_valid_o = response_bypass ?',
                'completion_exception_cause_o = response_bypass ?',
                'completion_exception_tval_o = response_bypass ?'):
        assert text.count(old) == 1, old
        text = text.replace(old, old.replace('response_bypass', 'response_payload'))
    if args.variant != 'rs-retain':
        path.write_text(text)
    if args.variant in ('metadata-wb', 'metadata-wb-rs'):
        path = args.out/'rtl/rv32_completion_writeback_network.v'
        text = path.read_text()
        old = '''        writeback_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        writeback_value_reg = {(BE_WIDTH*32){1'b0}};'''
        assert text.count(old) == 1
        text = text.replace(old, '''        writeback_phys_reg = SOURCE_AUTH != 0 ? selected_phys : completion_phys_i;
        writeback_value_reg = completion_value_reg;''')
        old = '''                    writeback_phys_reg[writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] = selected_phys[
                        writeback_lane_index*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH];
                    writeback_value_reg[writeback_lane_index*32 +: 32] =
                        completion_value_reg[writeback_lane_index*32 +: 32];'''
        assert text.count(old) == 1
        text = text.replace(old, '')
        old = '''                writeback_phys_reg[
                    writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = completion_phys_i[
                    writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH];
                writeback_value_reg[
                    writeback_lane_index*32 +: 32] =
                    completion_value_reg[
                    writeback_lane_index*32 +: 32];'''
        assert text.count(old) == 1
        text = text.replace(old, '')
        path.write_text(text)
    if args.variant in ('rs-retain', 'metadata-wb-rs'):
        path = args.out/'rtl/rv32_integer_reservation_station.v'
        text = path.read_text()
        start = text.index('                end else if (issue_remove_mask_reg[\n')
        end = text.index('            end\n        end\n    end', start)
        text = text[:start]+'''                end else begin
                    if (issue_remove_mask_reg[sequential_entry_index])
                        entry_busy[sequential_entry_index] <= 1'b0;
                    if (entry_busy[sequential_entry_index]) begin
                        if (!entry_lhs_ready[sequential_entry_index] &&
                                effective_lhs_ready[sequential_entry_index]) begin
                            entry_lhs_ready[sequential_entry_index] <= 1'b1;
                            entry_lhs_value[sequential_entry_index] <=
                                effective_lhs_value[sequential_entry_index];
                        end
                        if (!entry_rhs_ready[sequential_entry_index] &&
                                effective_rhs_ready[sequential_entry_index]) begin
                            entry_rhs_ready[sequential_entry_index] <= 1'b1;
                            entry_rhs_value[sequential_entry_index] <=
                                effective_rhs_value[sequential_entry_index];
                        end
                    end
                end
'''+text[end:]
        path.write_text(text)
    print('PASS isolated candidate', args.variant, args.out)


if __name__ == '__main__':
    main()
