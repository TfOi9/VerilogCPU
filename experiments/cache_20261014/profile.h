#include "Vstudent_top___024root.h"
#include <iostream>
#include <map>
#include <string>

double sc_time_stamp() { return 0; }

#define CORE(n) r.student_top__DOT__core__DOT__##n
#define ROB(n) CORE(rob__DOT__##n)
#define LSQ(n) CORE(lsq__DOT__##n)
#define BR(n) r.student_top__DOT__bridge__DOT__arbiter__DOT__##n
#define DC(n) r.student_top__DOT__dcache__DOT__##n

struct Profile {
    std::map<std::string, uint64_t> counts;
    std::map<uint64_t, uint64_t> request_gaps;
    uint64_t last_request = 0;

    void sample(Vstudent_top &top) {
        if (top.reset) return;
        auto &r = *top.rootp;
        uint64_t cycle = ++counts["cycles"];
        unsigned retired = __builtin_popcount(unsigned(ROB(commit_fire_reg)));
        counts["retired"] += retired;
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
        counts["fetch_empty"] += CORE(fetch_pipeline__DOT__queue_occupancy_reg) == 0;
        counts["ready_load_waiting_inflight"] += LSQ(inflight) &&
            int32_t(LSQ(request_candidate)) >= 0;
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
        std::cerr << "}}\n";
    }
};
