#!/usr/bin/env python3
"""Create an isolated address-to-request bypass candidate for screening."""
import argparse
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--stores', choices=('older', 'any', 'precomputed'), default='older')
    args = parser.parse_args()
    for name in ('rtl', 'verilog'):
        shutil.copytree(args.source/name, args.out/name)
    path = args.out/'rtl/rv32_load_store_queue.v'
    text = path.read_text()
    old = '    integer source_candidate;'
    new = '''    reg incoming_load_blocked;
    integer incoming_store_index;
    wire incoming_load_request = load_address_valid_i && load_address_ready_o &&
        !incoming_load_blocked && !address_fault(load_address_i, width[load_slot], 1'b0);
    integer source_candidate;'''
    assert text.count(old) == 1
    text = text.replace(old, new)
    old = '    always @* begin\n        store_request_candidate = -1;'
    comparison = (' &&\n                    entry_distance[incoming_store_index] <\n'
                  '                        distance_from_head(load_address_rob_tag_i, rob_head_index_i)') if args.stores == 'older' else ''
    new = '''    always @* begin
        incoming_load_blocked = 1'b0;
        for (incoming_store_index = 0; incoming_store_index < LSQ_ENTRIES;
                incoming_store_index = incoming_store_index + 1) begin
            if (busy[incoming_store_index] && is_store[incoming_store_index]'''+comparison+''')
                incoming_load_blocked = 1'b1;
        end
    end

    always @* begin
        store_request_candidate = -1;'''
    assert text.count(old) == 1
    text = text.replace(old, new)
    old = '''                        started[request_candidate] <= 1'b1;
                    end'''
    new = '''                        started[request_candidate] <= 1'b1;
                    end else if (incoming_load_request) begin
                        request_valid <= 1'b1;
                        request_id <= free_pending_slot;
                        request_write <= 1'b0;
                        request_rob_tag <= load_address_rob_tag_i;
                        request_lsq_tag <= load_address_lsq_tag_i;
                        request_address <= {load_address_i[31:2], 2'b00};
                        request_write_data <= 0;
                        request_byte_enable <= 0;
                        request_mmio <= 1'b0;
                        started[load_slot] <= 1'b1;
                    end'''
    assert text.count(old) == 1
    text = text.replace(old, new)
    if args.stores == 'precomputed':
        text = text.replace('    integer incoming_store_index;', '''    integer incoming_store_index;
    integer incoming_load_index;
    reg [LSQ_ENTRIES-1:0] no_older_store;''')
        old = '''        incoming_load_blocked = 1'b0;
        for (incoming_store_index = 0; incoming_store_index < LSQ_ENTRIES;
                incoming_store_index = incoming_store_index + 1) begin
            if (busy[incoming_store_index] && is_store[incoming_store_index])
                incoming_load_blocked = 1'b1;
        end'''
        new = '''        no_older_store = {LSQ_ENTRIES{1'b1}};
        for (incoming_load_index = 0; incoming_load_index < LSQ_ENTRIES;
                incoming_load_index = incoming_load_index + 1) begin
            for (incoming_store_index = 0; incoming_store_index < LSQ_ENTRIES;
                    incoming_store_index = incoming_store_index + 1) begin
                if (busy[incoming_store_index] && is_store[incoming_store_index] &&
                        entry_distance[incoming_store_index] < entry_distance[incoming_load_index])
                    no_older_store[incoming_load_index] = 1'b0;
            end
        end
        incoming_load_blocked = !no_older_store[load_slot];'''
        assert text.count(old) == 1
        text = text.replace(old, new)
    path.write_text(text)


if __name__ == '__main__':
    main()
