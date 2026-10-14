#!/usr/bin/env python3
"""Stage an isolated next-line prefetch candidate without editing formal RTL."""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT/'build/deep-20261014/prefetch-source-v2'
assert not DEST.exists()
shutil.copytree(ROOT/'rtl', DEST/'rtl')
shutil.copytree(ROOT/'verilog', DEST/'verilog')
p = DEST/'rtl/rv32_l1_data_cache.v'
s = p.read_text()
s = s.replace('    reg [2:0] mode;', '''    reg pf_candidate_valid;
    reg [31:0] pf_candidate_address;
    reg pf_pending;
    reg [31:0] pf_pending_address;
    reg pf_poison;
    reg pf_valid;
    reg [31:0] pf_address;
    reg [127:0] pf_line;
    wire pf_select;
    wire pf_hit;
    wire cached_refill;
    wire [127:0] effective_refill_data;
    wire effective_response_error;

    reg [2:0] mode;''', 1)
s = s.replace('merge_word(memory_response_read_data_i,', 'merge_word(effective_refill_data,')
s = s.replace('        memory_response_read_data_i;', '        effective_refill_data;', 1)
start = s.index('    assign memory_request_valid_o =')
end = s.index('\n    always @* begin', start)
s = s[:start] + '''    assign pf_select = mode == RUN && !s2_miss && pf_candidate_valid && !pf_pending;
    assign pf_hit = pf_valid && !pf_pending && pf_address == miss_line_address;
    assign cached_refill = mode == REFILL_WAIT && pf_hit && !pf_pending;
    assign effective_refill_data = cached_refill ? pf_line : memory_response_read_data_i;
    assign effective_response_error = !cached_refill && memory_response_error_i;
    assign memory_request_valid_o = !reset_i && !pf_pending &&
        ((mode == WRITEBACK_REQUEST) || (mode == REFILL_REQUEST && !pf_hit) || pf_select);
    assign memory_request_write_o = mode == WRITEBACK_REQUEST;
    assign memory_request_address_o = pf_select ? pf_candidate_address :
        (mode == WRITEBACK_REQUEST ? victim_address : miss_line_address);
    assign memory_request_write_data_o = mode == WRITEBACK_REQUEST ? victim_line : 128'd0;
    assign memory_request_byte_enable_o = mode == WRITEBACK_REQUEST ? 16'hffff : 16'd0;
    assign memory_response_ready_o = !reset_i && (pf_pending ||
        (mode == WRITEBACK_WAIT) || (mode == REFILL_WAIT && !pf_hit));
    assign memory_response_fire = cached_refill ||
        (memory_response_valid_i && memory_response_ready_o && !pf_pending);
    assign refill_install = !reset_i && mode == REFILL_WAIT &&
        memory_response_fire && !effective_response_error;

    always @(posedge clk_i) begin
        if (reset_i) begin
            pf_candidate_valid <= 0; pf_candidate_address <= 0;
            pf_pending <= 0; pf_pending_address <= 0; pf_poison <= 0;
            pf_valid <= 0; pf_address <= 0; pf_line <= 0;
        end else begin
            if (pf_select && memory_request_valid_o && memory_request_ready_i) begin
                pf_pending <= 1; pf_pending_address <= pf_candidate_address;
                pf_poison <= 0; pf_candidate_valid <= 0;
            end
            if (pf_pending && memory_response_valid_i && memory_response_ready_o) begin
                pf_pending <= 0; pf_valid <= !memory_response_error_i && !pf_poison;
                pf_address <= pf_pending_address; pf_line <= memory_response_read_data_i;
            end
            if (cached_refill) pf_valid <= 0;
            if (refill_install && miss_line_address < 32'h0ffffff0) begin
                pf_candidate_valid <= 1;
                pf_candidate_address <= miss_line_address + 16;
            end
            // A prefetched external copy must not replace newer dirty cache data.
            if (store_commit || (mode == RUN && s2_miss && s2_line_valid && s2_line_dirty)) begin
                if ((store_commit ? {s2_address[31:4],4'b0} :
                        {s2_tag,s2_set,4'b0}) == pf_address) pf_valid <= 0;
                if ((store_commit ? {s2_address[31:4],4'b0} :
                        {s2_tag,s2_set,4'b0}) == pf_pending_address) begin
                    pf_poison <= 1;
                    if (pf_pending && memory_response_valid_i && memory_response_ready_o)
                        pf_valid <= 0;
                end
            end
        end
    end
''' + s[end:]
s = s.replace('if (memory_response_error_i) begin', 'if (effective_response_error) begin')
s = s.replace('miss_error <= memory_response_error_i;', 'miss_error <= effective_response_error;')
s = s.replace('miss_data <= memory_response_error_i || s2_write ?', 'miss_data <= effective_response_error || s2_write ?')
s = s.replace('32\'d0 : memory_response_read_data_i[', '32\'d0 : effective_refill_data[')
s = s.replace('                    if (memory_request_valid_o && memory_request_ready_i)\n                        mode <= REFILL_WAIT;', '                    if (pf_hit || (memory_request_valid_o && memory_request_ready_i))\n                        mode <= REFILL_WAIT;')
p.write_text(s)
print(DEST)
