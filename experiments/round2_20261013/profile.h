#include "Vstudent_top___024root.h"
#include <map>
#include <string>
#include <deque>
#include <algorithm>
#include <iostream>
#include <stdexcept>

double sc_time_stamp() { return 0; }

#define CORE(n) r.student_top__DOT__core__DOT__##n
#define FETCH(n) CORE(fetch_pipeline__DOT__##n)
#define ROB(n) CORE(rob__DOT__##n)
#define LSQ(n) CORE(lsq__DOT__##n)
#define IC(n) r.student_top__DOT__icache__DOT__##n
#define DC(n) r.student_top__DOT__dcache__DOT__##n
#define BR(n) r.student_top__DOT__bridge__DOT__arbiter__DOT__##n
#define DIS(n) CORE(dispatch_pipeline__DOT__##n)
#define IRS(n) CORE(int_rs__DOT__##n)
#define MRS(n) CORE(mul_rs__DOT__reservation_station__DOT__##n)
#define DRS(n) CORE(div_rs__DOT__reservation_station__DOT__##n)

struct Profile {
    std::map<std::string, uint64_t> count;
    std::map<std::string, std::map<uint64_t, uint64_t>> hist;
    uint64_t cycle = 0, last_request = 0, request_start = 0, line_start = 0;
    bool request_store = false;
    int line_owner = 0;
    unsigned read_outstanding = 0, write_outstanding = 0;
    uint64_t previous_response = 0;
    bool request_pending = false;
    struct StoreTiming {
        bool active = false, retired = false;
        unsigned generation = 0;
        uint64_t ready = 0, head = 0, request = 0, array_commit = 0, response = 0;
    } stores[8];
    void interval(const std::string &name, uint64_t start, uint64_t end) {
        if (start && end) {
            if (end < start) throw std::runtime_error("negative profile interval");
            ++hist[name][end-start];
        }
    }
    void sample(Vstudent_top &top) {
        if (top.reset) return;
        auto &r = *top.rootp;
        ++cycle;
        ++count["cycles"];
        unsigned retired = __builtin_popcount(unsigned(ROB(commit_fire_reg)));
        count["retired"] += retired;
        ++hist["retirement_width"][retired];
        count["dispatched"] += FETCH(dequeue_count);
        ++hist["dispatch_width"][FETCH(dequeue_count)];
        ++hist["rob_occupancy"][ROB(occupancy_reg)];
        ++hist["lsq_occupancy"][CORE(lsq_occupancy)];
        ++hist["int_rs_occupancy"][CORE(int_rs__DOT__occupancy_reg)];
        ++hist["fetch_occupancy"][FETCH(queue_occupancy_reg)];
        ++hist["free_phys"][CORE(dispatch_pipeline__DOT__rename_unit__DOT__free_count_reg)];
        unsigned issued = __builtin_popcount(unsigned(CORE(int_rs__DOT__issue_fire_reg)));
        issued += CORE(mul_rs__DOT__multiplier__DOT__request_fire);
        issued += CORE(div_rs__DOT__divider__DOT__request_fire);
        issued += CORE(load_address_valid) && CORE(lsq_load_address_ready) && (CORE(issue_grant) & (1u << (PROFILE_BE+2)));
        issued += CORE(store_address_valid) && CORE(lsq_store_address_ready) && (CORE(issue_grant) & (1u << (PROFILE_BE+3)));
        count["issued"] += issued;
        ++hist["issue_width"][issued];
        count["mul_issued"] += CORE(mul_rs__DOT__multiplier__DOT__request_fire);
        count["div_issued"] += CORE(div_rs__DOT__divider__DOT__request_fire);
        bool recovery = ROB(recovery_busy_reg);
        count["recovery_cycles"] += recovery;
        count["mispredict_events"] += ROB(mispredict_found_reg);
        count["rolled_back"] += ROB(rollback_count);
        count["predicted_taken_events"] += FETCH(response_enqueue_fire) && FETCH(predicted_redirect);
        count["fetch_empty_cycles"] += FETCH(queue_occupancy_reg) == 0;
        count["fetch_empty_not_recovery"] += FETCH(queue_occupancy_reg) == 0 && !recovery;
        count["dispatch_blocked_nonempty"] += FETCH(queue_occupancy_reg) != 0 && FETCH(dequeue_count) == 0 && !recovery;
        bool blocked = FETCH(queue_occupancy_reg) != 0 && FETCH(dequeue_count) == 0 && !recovery;
        unsigned selected = __builtin_popcount(unsigned(DIS(selected_valid)));
        bool prefix_stall = !recovery && selected < PROFILE_BE &&
            (DIS(candidate_valid) & (1u << selected));
        bool prefix_resources[8] = {};
        if (prefix_stall) {
            unsigned cls = (DIS(decode_class) >> (selected*4)) & 15;
            bool legal = (DIS(decode_legal) & (1u << selected)) && !(DIS(candidate_error) & (1u << selected));
            bool integer = legal && (cls == 1 || cls == 4 || cls == 5);
            bool load = legal && cls == 2, store = legal && cls == 3;
            prefix_resources[0] = DIS(phys_needed) + bool(DIS(effective_writes_rd) & (1u << selected)) > DIS(free_count_o);
            prefix_resources[1] = DIS(rob_needed) + 1 > PROFILE_ROB-CORE(rob_occupancy);
            prefix_resources[2] = DIS(int_needed) + integer > 8-CORE(int_occupancy);
            prefix_resources[3] = DIS(mul_needed) + (legal && cls == 6) > 4-CORE(mul_occupancy);
            prefix_resources[4] = DIS(div_needed) + (legal && cls == 7) > 4-CORE(div_occupancy);
            prefix_resources[5] = DIS(load_needed) + load > 8-CORE(load_occupancy);
            prefix_resources[6] = DIS(store_needed) + store > 8-CORE(store_occupancy);
            prefix_resources[7] = DIS(lsq_needed) + (load || store) > 8-CORE(lsq_occupancy);
            ++count["dispatch_prefix_limited_cycles"];
            count["dispatch_prefix_full_stall"] += selected == 0;
            count["dispatch_prefix_partial_stall"] += selected != 0;
            count["rs_unused_turnover_int"] += prefix_resources[2] &&
                DIS(int_needed) + integer <= 8-CORE(int_occupancy)+__builtin_popcount(unsigned(IRS(issue_remove_mask_reg)));
            count["rs_unused_turnover_mul"] += prefix_resources[3] &&
                DIS(mul_needed) + (legal && cls == 6) <= 4-CORE(mul_occupancy)+__builtin_popcount(unsigned(MRS(issue_remove_mask_reg)));
            count["rs_unused_turnover_div"] += prefix_resources[4] &&
                DIS(div_needed) + (legal && cls == 7) <= 4-CORE(div_occupancy)+__builtin_popcount(unsigned(DRS(issue_remove_mask_reg)));
        }
        bool resources[] = {
            !DIS(rename_ready), !CORE(rob_alloc_ready),
            bool(CORE(int_dispatch_valid)) && !CORE(int_dispatch_ready),
            bool(CORE(mul_dispatch_valid)) && !CORE(mul_dispatch_ready),
            bool(CORE(div_dispatch_valid)) && !CORE(div_dispatch_ready),
            bool(CORE(load_dispatch_valid)) && !CORE(load_dispatch_ready),
            bool(CORE(store_dispatch_valid)) && !CORE(store_dispatch_ready),
            bool(CORE(lsq_alloc_valid)) && !CORE(lsq_alloc_ready)};
        const char *names[] = {"rename", "rob", "int_rs", "mul_rs", "div_rs", "load_rs", "store_rs", "lsq"};
        bool primary = false;
        for (unsigned i = 0; i < 8; ++i) {
            count[std::string("dispatch_prefix_overlap_")+names[i]] += prefix_stall && prefix_resources[i];
            resources[i] = resources[i] || (prefix_stall && selected == 0 && prefix_resources[i]);
        }
        for (unsigned i = 0; i < 8; ++i) if (blocked && resources[i]) {
            ++count[std::string("dispatch_block_overlap_") + names[i]];
            if (!primary) ++count[std::string("dispatch_block_primary_") + names[i]];
            primary = true;
        }
        if (blocked && !primary) ++count["dispatch_block_primary_other"];
        unsigned free_int = 8-IRS(occupancy_reg), free_mul = 4-MRS(occupancy_reg), free_div = 4-DRS(occupancy_reg);
        unsigned need_int = __builtin_popcount(unsigned(CORE(int_dispatch_valid)));
        unsigned need_mul = __builtin_popcount(unsigned(CORE(mul_dispatch_valid)));
        unsigned need_div = __builtin_popcount(unsigned(CORE(div_dispatch_valid)));
        bool reuse_int = need_int > free_int && need_int <= free_int + __builtin_popcount(unsigned(IRS(issue_remove_mask_reg)));
        bool reuse_mul = need_mul > free_mul && need_mul <= free_mul + __builtin_popcount(unsigned(MRS(issue_remove_mask_reg)));
        bool reuse_div = need_div > free_div && need_div <= free_div + __builtin_popcount(unsigned(DRS(issue_remove_mask_reg)));
        count["rs_reuse_opportunity_int"] += reuse_int && !recovery;
        count["rs_reuse_opportunity_mul"] += reuse_mul && !recovery;
        count["rs_reuse_opportunity_div"] += reuse_div && !recovery;
        count["dispatch_uses_released_slot"] += FETCH(dequeue_count) && (reuse_int || reuse_mul || reuse_div);
        count["dispatch_blocked_reuse_opportunity"] += blocked && (reuse_int || reuse_mul || reuse_div);
        count["lsq_full_cycles"] += CORE(lsq_occupancy) == 8;
        count["rob_full_cycles"] += ROB(occupancy_reg) == PROFILE_ROB;
        count["lsq_inflight_cycles"] += LSQ(inflight);
        count["ready_load_waiting_inflight"] += LSQ(inflight) && int32_t(LSQ(request_candidate)) >= 0;
        count["lsq_source_occupied"] += LSQ(source_valid);
        count["lsq_source_candidate_wait"] += LSQ(source_valid) && int32_t(LSQ(source_candidate)) >= 0;
        bool response_fire = LSQ(cache_response_valid_i) && LSQ(cache_response_ready_o);
        count["lsq_response_blocked"] += LSQ(cache_response_valid_i) && !LSQ(cache_response_ready_o);
        count["lsq_request_blocked"] += LSQ(cache_request_valid_o) && !LSQ(cache_request_ready_i);
        count["lsq_completion_blocked"] += LSQ(completion_valid_o) && !LSQ(completion_ready_i);
        count["lsq_turnover_load_opportunity"] += response_fire && !LSQ(request_valid) && int32_t(LSQ(request_candidate)) >= 0;
        count["lsq_response_error"] += response_fire && LSQ(cache_response_error_i);
        count["lsq_response_discard"] += response_fire && (LSQ(inflight_discard) || !LSQ(inflight_match));
        bool blocked_load = false, unknown_store = false, partial_forward = false;
        for (int i = 0; i < 8; ++i) {
            if (LSQ(busy)[i] && !LSQ(is_store)[i] && LSQ(address_valid)[i] && !LSQ(started)[i] && !LSQ(report_sent)[i]) {
                blocked_load |= LSQ(load_blocked)[i];
                unsigned mask = LSQ(forwarding_mask)[i], size = LSQ(entry_size)[i];
                partial_forward |= mask && mask != (15u >> (4-size));
                for (int j = 0; j < 8; ++j)
                    unknown_store |= LSQ(busy)[j] && LSQ(is_store)[j] && !LSQ(address_valid)[j] && LSQ(entry_distance)[j] < LSQ(entry_distance)[i];
            }
        }
        count["load_blocked_cycles"] += blocked_load;
        count["load_unknown_store_cycles"] += unknown_store;
        count["load_partial_forward_cycles"] += partial_forward;
        unsigned h = ROB(head_reg), op = ROB(entry_op)[h];
        for (unsigned i = 0; i < 8; ++i) {
            auto &s = stores[i];
            if (s.active && (!LSQ(busy)[i] || s.generation != LSQ(generation)[i])) {
                if (!s.retired) ++count["store_tracking_canceled"];
                s = StoreTiming{};
            }
            if (LSQ(busy)[i] && LSQ(is_store)[i]) {
                s.active = true;
                s.generation = LSQ(generation)[i];
                if (!s.ready && LSQ(address_valid)[i] && LSQ(data_valid)[i]) s.ready = cycle;
            }
        }
        if (!recovery && ROB(entry_busy)[h] && op >= 16 && op <= 18 && ROB(entry_lsq_valid)[h]) {
            unsigned slot = ROB(entry_lsq_tag)[h] & 7;
            auto &s = stores[slot];
            if (!s.head) s.head = cycle;
            if (!retired) {
                std::string phase;
                if (!LSQ(address_valid)[slot] || !LSQ(data_valid)[slot]) phase = "operands";
                else if (!ROB(entry_complete)[h]) phase = "completion";
                else if (LSQ(write_done)[slot]) phase = "retirement";
                else if (!LSQ(write_requested)[slot]) phase = "schedule";
                else if (LSQ(request_valid) && LSQ(request_write)) phase = "request_handshake";
                else if (LSQ(inflight) && LSQ(inflight_write)) phase = DC(mode) == 0 ? "cache_run" : "cache_miss_or_mmio";
                else phase = "other";
                ++count["store_head_phase_"+phase];
            }
        }
        std::string reason;
        if (retired) reason = "retire";
        else if (recovery) reason = "recovery";
        else if (!ROB(entry_busy)[h]) reason = "rob_empty";
        else if (!ROB(entry_complete)[h]) {
            if (op >= 11 && op <= 15) reason = "head_load_incomplete";
            else if (op >= 16 && op <= 18) reason = "head_store_incomplete";
            else if (op >= 3 && op <= 10) reason = "head_branch_incomplete";
            else reason = "head_other_incomplete";
        } else if (op >= 16 && op <= 18) reason = "head_store_response";
        else reason = "other";
        ++count["partition_" + reason];
        if (!retired && ROB(entry_busy)[h] && !recovery) ++hist["blocked_head_pc"][ROB(entry_pc)[h]];
        for (unsigned i = 0; i < PROFILE_BE; ++i) if (ROB(commit_fire_reg) & (1u << i)) {
            unsigned slot = (h+i) % PROFILE_ROB;
            ++hist["retired_op"][ROB(entry_op)[slot]];
            ++hist["retired_pc"][ROB(entry_pc)[slot]];
        }
        count["icache_miss_pending_cycles"] += IC(mode) == 0 && IC(s2_miss);
        count["dcache_miss_transactions"] += DC(mode) == 0 && DC(s2_miss);
        count["icache_hit_events"] += IC(hit_event_o);
        count["dcache_hit_events"] += DC(hit_event_o);
        count["icache_nonrun_cycles"] += IC(mode) != 0;
        count["dcache_nonrun_cycles"] += DC(mode) != 0;
        count["dcache_port_conflict_cycles"] += DC(array_read_conflict);
        count["icache_orphan_cycles"] += IC(memory_orphan);
        count["icache_flush_cycles"] += FETCH(icache_flush_reg);
        if (LSQ(cache_request_valid_o) && LSQ(cache_request_ready_i)) {
            if (request_pending) throw std::runtime_error("multiple LSQ requests in flight");
            request_pending = true;
            if (last_request) ++hist["lsq_request_gap"][cycle-last_request];
            if (previous_response) ++hist["lsq_response_to_next_request"][cycle-previous_response];
            last_request = request_start = cycle;
            request_store = LSQ(request_write);
            ++count[request_store ? "cache_store_requests" : "cache_load_requests"];
            if (request_store) stores[LSQ(request_lsq_tag) & 7].request = cycle;
            count["cache_mmio_requests"] += LSQ(request_mmio);
        }
        if (DC(store_commit) && LSQ(inflight) && LSQ(inflight_write))
            stores[LSQ(inflight_lsq_tag) & 7].array_commit = cycle;
        if (LSQ(cache_response_valid_i) && LSQ(cache_response_ready_o)) {
            if (!request_pending) throw std::runtime_error("LSQ response without request");
            request_pending = false;
            previous_response = cycle;
            ++count["cache_responses"];
            ++hist[request_store ? "cache_store_latency" : "cache_load_latency"][cycle-request_start];
            if (request_store) stores[LSQ(inflight_lsq_tag) & 7].response = cycle;
        }
        for (unsigned i = 0; i < PROFILE_BE; ++i) if (ROB(commit_fire_reg) & (1u << i)) {
            unsigned slot = (h+i) % PROFILE_ROB, rop = ROB(entry_op)[slot];
            if (rop >= 16 && rop <= 18 && ROB(entry_lsq_valid)[slot]) {
                auto &s = stores[ROB(entry_lsq_tag)[slot] & 7];
                interval("store_ready_to_request", s.ready, s.request);
                interval("store_head_to_request", s.head, s.request);
                interval("store_request_to_array_commit", s.request, s.array_commit);
                interval("store_request_to_response", s.request, s.response);
                interval("store_response_to_retire", s.response, cycle);
                interval("store_head_to_retire", s.head, cycle);
                s.retired = true;
                ++count["stores_retired"];
            }
        }
        if (BR(memory_request_valid_o) && BR(memory_request_ready_i)) {
            line_start = cycle;
            line_owner = BR(selected_owner);
            ++count["line_requests_owner_" + std::to_string(line_owner)];
        }
        if (BR(memory_response_valid_i) && BR(memory_response_ready_o))
            ++hist["line_latency_owner_" + std::to_string(line_owner)][cycle-line_start];
        if (BR(busy)) ++count["bridge_busy_owner_" + std::to_string(BR(owner))];
        if (top.arvalid && top.arready) { ++read_outstanding; ++count["axi_reads"]; }
        if (top.rvalid && top.rready) { if (!read_outstanding) throw std::runtime_error("unexpected AXI R"); --read_outstanding; ++count["axi_read_responses"]; }
        if (top.awvalid && top.awready) { ++write_outstanding; ++count["axi_writes"]; }
        if (top.bvalid && top.bready) { if (!write_outstanding) throw std::runtime_error("unexpected AXI B"); --write_outstanding; ++count["axi_write_responses"]; }
        ++hist["axi_read_outstanding"][read_outstanding];
        ++hist["axi_write_outstanding"][write_outstanding];
    }
    void report(Vstudent_top &top) {
        auto &r = *top.rootp;
        count["counter_schema_version"] = 2;
        count["end_axi_read_outstanding"] = read_outstanding;
        count["end_axi_write_outstanding"] = write_outstanding;
        count["end_lsq_request_pending"] = request_pending;
        for (const auto &s : stores) count["end_stores_not_retired"] += s.active && !s.retired;
        count["predictor_control_total"] = FETCH(predictor__DOT__control_total_reg);
        count["predictor_control_correct"] = FETCH(predictor__DOT__control_correct_reg);
        count["predictor_conditional_total"] = FETCH(predictor__DOT__conditional_total_reg);
        count["predictor_conditional_correct"] = FETCH(predictor__DOT__conditional_correct_reg);
        count["predictor_jalr_total"] = FETCH(predictor__DOT__jalr_total_reg);
        count["predictor_jalr_correct"] = FETCH(predictor__DOT__jalr_correct_reg);
        std::cerr << "PROFILE {\"counts\":{";
        bool first = true;
        for (const auto &v : count) { if (!first) std::cerr << ','; first=false; std::cerr << '"' << v.first << "\":" << v.second; }
        std::cerr << "},\"histograms\":{";
        first=true;
        for (const auto &h : hist) {
            if (!first) std::cerr << ','; first=false;
            std::cerr << '"' << h.first << "\":{";
            bool inner=true;
            for (const auto &v : h.second) { if (!inner) std::cerr << ','; inner=false; std::cerr << '"' << v.first << "\":" << v.second; }
            std::cerr << '}';
        }
        std::cerr << "}}\n";
    }
};
