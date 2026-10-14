#include "Vstudent_top___024root.h"
#include <iostream>
#include <map>
#include <string>

double sc_time_stamp() { return 0; }

#define CORE(n) r.student_top__DOT__core__DOT__##n
#define ROB(n) CORE(rob__DOT__##n)
#define LSQ(n) CORE(lsq__DOT__##n)
#define BR(n) r.student_top__DOT__bridge__DOT__arbiter__DOT__##n
#define DP(n) CORE(dispatch_pipeline__DOT__##n)
#define WB(n) CORE(writeback_network__DOT__##n)
#define IC(n) r.student_top__DOT__icache__DOT__##n
#define DC(n) r.student_top__DOT__dcache__DOT__##n

template<class T> uint32_t word(const T &value, unsigned index) {
    return index < 2 ? uint64_t(value) >> (32*index) : 0;
}
template<size_t N> uint32_t word(const VlWide<N> &value, unsigned index) {
    return value[index];
}
struct Profile {
    std::map<std::string, uint64_t> counts;
    std::map<uint64_t, uint64_t> request_gaps;
    std::map<uint64_t, uint64_t> recovery_lengths, rollback_depths;
    uint64_t last_request = 0;
    uint64_t recovery_length = 0, rollback_depth = 0;

    void sample(Vstudent_top &top) {
        if (top.reset) return;
        auto &r = *top.rootp;
        uint64_t cycle = ++counts["cycles"];
        unsigned retired = __builtin_popcount(unsigned(ROB(commit_fire_reg)));
        counts["retired"] += retired;
        counts["inflight_samples"] += LSQ(inflight_count);
        counts["multiple_inflight_cycles"] += LSQ(inflight_count) > 1;
        unsigned head = ROB(head_reg), op = ROB(entry_op)[head];
        std::string reason;
        if (retired) reason = "retire";
        else if (ROB(recovery_busy_reg)) reason = "recovery";
        else if (!ROB(entry_busy)[head]) reason = "rob_empty";
        else if (!ROB(entry_complete)[head]) {
            if (op >= 11 && op <= 15) reason = "head_load";
            else if (op >= 16 && op <= 18) reason = "head_store_address";
            else if (op >= 3 && op <= 10) reason = "head_branch";
            else reason = "head_other";
        } else if (op >= 16 && op <= 18) reason = "head_store_response";
        else reason = "other";
        ++counts["partition_" + reason];
        if (ROB(recovery_busy_reg)) {
            if (!recovery_length) ++counts["recovery_events"];
            ++recovery_length;
            unsigned removed = __builtin_popcount(unsigned(ROB(rollback_valid_reg)));
            rollback_depth += removed;
            counts["rollback_entries"] += removed;
        } else if (recovery_length) {
            ++recovery_lengths[recovery_length];
            ++rollback_depths[rollback_depth];
            recovery_length = rollback_depth = 0;
        }
        counts["fetch_path_corrections"] += CORE(fetch_pipeline__DOT__icache_flush_reg);
        for (unsigned lane = 0; lane < CONFIG_BE; ++lane) {
            if ((CORE(predictor_update_valid) >> lane) & 1) {
                ++counts["accepted_control_completions"];
                unsigned predicted = word(CORE(predictor_update_predicted_next_pc), lane);
                unsigned actual = word(CORE(predictor_update_actual_next_pc), lane);
                counts["accepted_control_mismatches"] += predicted != actual;
                unsigned op = (CORE(predictor_update_op) >> (6*lane)) & 63;
                std::string kind = op == 3 ? "jal" : op == 4 ? "jalr" : "conditional";
                ++counts["control_" + kind];
                counts["mismatch_" + kind] += predicted != actual;
            }
        }
        ++counts["retire_width_" + std::to_string(retired)];
        for (unsigned lane = 0; lane < CONFIG_BE; ++lane) {
            if ((ROB(commit_fire_reg) >> lane) & 1) {
                unsigned slot = (head + lane) % CONFIG_ROB;
                unsigned op = ROB(entry_op)[slot];
                std::string kind = op >= 11 && op <= 15 ? "load" : op >= 16 && op <= 18 ? "store" :
                    op >= 3 && op <= 10 ? "control" : op >= 41 && op <= 44 ? "multiply" :
                    op >= 45 && op <= 48 ? "divide" : "integer";
                ++counts["retired_" + kind];
            }
        }
        bool active = !CORE(pipeline_hold);
        if (active) {
            ++counts["active_cycles"];
            unsigned issues = __builtin_popcount(unsigned(CORE(issue_grant)));
            ++counts["issue_grants_" + std::to_string(issues)];
            unsigned accepted = __builtin_popcount(unsigned(CORE(int_issue_valid) & CORE(int_issue_ready))) +
                bool(CORE(mul_issue_valid) && CORE(mul_issue_ready) && ((CORE(issue_grant) >> CONFIG_BE) & 1)) +
                bool(CORE(div_issue_valid) && CORE(div_issue_ready) && ((CORE(issue_grant) >> (CONFIG_BE+1)) & 1)) +
                bool(CORE(load_address_valid) && CORE(load_address_ready)) +
                bool(CORE(store_address_valid) && CORE(store_address_ready));
            ++counts["issue_width_" + std::to_string(accepted)];
            counts["unused_issue_grants"] += issues - accepted;
            unsigned completed = __builtin_popcount(unsigned(CORE(completion_valid) & CORE(completion_ready)));
            ++counts["completion_width_" + std::to_string(completed)];
            unsigned dispatched = CORE(dispatch_fire) ? __builtin_popcount(unsigned(CORE(dispatch_valid))) : 0;
            ++counts["dispatch_width_" + std::to_string(dispatched)];
            counts["rob_full_active"] += CORE(rob_occupancy) == CONFIG_ROB;
            counts["lsq_full_active"] += CORE(lsq_occupancy) == CONFIG_LSQ;
            counts["int_rs_full_active"] += CORE(int_occupancy) == 8;
            counts["prf_empty_active"] += DP(free_count_o) == 0;
            counts["fetch_empty_active"] += !CORE(fetch_valid);
            counts["fetch_empty_with_rob_empty"] += !CORE(fetch_valid) && !CORE(rob_occupancy);
            counts["rob_occupancy_samples"] += CORE(rob_occupancy);
            counts["lsq_occupancy_samples"] += CORE(lsq_occupancy);
            counts["writeback_backpressure"] += (CORE(source_valid) & ~CORE(source_ready)) != 0;
            counts["load_store_address_collision"] += CORE(load_address_valid) && CORE(store_address_valid);
            bool any_unknown_store = false, any_blocked_load = false, any_eligible_load = false;
            for (unsigned i = 0; i < CONFIG_LSQ; ++i) {
                any_unknown_store |= LSQ(busy)[i] && LSQ(is_store)[i] && !LSQ(address_valid)[i];
                any_blocked_load |= LSQ(busy)[i] && !LSQ(is_store)[i] && LSQ(address_valid)[i] &&
                    !LSQ(started)[i] && !LSQ(report_sent)[i] && LSQ(load_blocked)[i];
                any_eligible_load |= LSQ(busy)[i] && !LSQ(is_store)[i] && LSQ(address_valid)[i] &&
                    !LSQ(started)[i] && !LSQ(report_sent)[i] && !LSQ(load_blocked)[i];
            }
            counts["unknown_store_present"] += any_unknown_store;
            counts["dependent_load_present"] += any_blocked_load;
            counts["eligible_load_present"] += any_eligible_load;
        }
        counts["dcache_nonrun"] += DC(mode) != 0;
        counts["icache_nonrun"] += IC(mode) != 0;
        counts["dcache_array_conflict"] += DC(array_read_conflict);
        unsigned hslot = ROB(entry_lsq_tag)[head] & (CONFIG_LSQ - 1);
        if (reason == "head_store_response") {
            std::string stage;
            if (LSQ(write_done)[hslot]) stage = "done";
            else if (LSQ(request_valid) && LSQ(request_write) &&
                    (LSQ(request_lsq_tag) & (CONFIG_LSQ - 1)) == hslot) stage = "request_queue";
            else if (LSQ(write_requested)[hslot]) stage = "inflight";
            else stage = "prepare";
            ++counts["store_stage_" + stage];
            counts["store_head_dcache_nonrun"] += DC(mode) != 0;
        }
        if (reason == "head_load") {
            std::string stage;
            if (!LSQ(address_valid)[hslot]) stage = "address";
            else if (LSQ(report_sent)[hslot]) stage = "writeback";
            else if (LSQ(request_valid) && !LSQ(request_write) &&
                    (LSQ(request_lsq_tag) & (CONFIG_LSQ - 1)) == hslot) stage = "request_queue";
            else if (LSQ(started)[hslot]) stage = "inflight";
            else if (LSQ(load_blocked)[hslot]) stage = "dependence";
            else stage = "eligible";
            ++counts["load_stage_" + stage];
        }
        counts["fetch_empty"] += CORE(fetch_pipeline__DOT__queue_occupancy_reg) == 0;
        counts["load_candidate_with_inflight"] += LSQ(inflight_count) != 0 &&
            int32_t(LSQ(request_candidate)) >= 0;
        counts["request_backpressure_cycles"] += LSQ(cache_request_valid_o) &&
            !LSQ(cache_request_ready_i);
        counts["inflight_full_cycles"] += LSQ(inflight_count) == 4;
        if (BR(memory_request_valid_o) && BR(memory_request_ready_i)) {
            if (BR(selected_owner) == 0) ++counts["icache_line_reads"];
            else if (BR(selected_owner) == 1)
                ++counts[DC(mode) == 1 ? "dcache_writebacks" : "dcache_refills"];
        }
        if (LSQ(cache_request_valid_o) && LSQ(cache_request_ready_i)) {
            if (last_request) ++request_gaps[cycle - last_request];
            last_request = cycle;
            ++counts[LSQ(request_write) ? "store_requests" : "load_requests"];
        }
    }

    void report() {
        std::cerr << "PROFILE {\"counts\":{";
        bool first = true;
        for (const auto &v : counts) {
            if (!first) std::cerr << ',';
            first = false;
            std::cerr << '"' << v.first << "\":" << v.second;
        }
        std::cerr << "},\"request_gaps\":{";
        first = true;
        for (const auto &v : request_gaps) {
            if (!first) std::cerr << ',';
            first = false;
            std::cerr << '"' << v.first << "\":" << v.second;
        }
        std::cerr << "},\"recovery_lengths\":{";
        first = true;
        for (const auto &v : recovery_lengths) {
            if (!first) std::cerr << ',';
            first = false;
            std::cerr << '"' << v.first << "\":" << v.second;
        }
        std::cerr << "},\"rollback_depths\":{";
        first = true;
        for (const auto &v : rollback_depths) {
            if (!first) std::cerr << ',';
            first = false;
            std::cerr << '"' << v.first << "\":" << v.second;
        }
        std::cerr << "}}\n";
    }
};
