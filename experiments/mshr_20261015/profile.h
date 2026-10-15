#include "Vstudent_top___024root.h"
#include <array>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>

double sc_time_stamp() { return 0; }
#define DC(n) r.student_top__DOT__dcache__DOT__##n
#define LSQ(n) r.student_top__DOT__core__DOT__lsq__DOT__##n
#define ROB(n) r.student_top__DOT__core__DOT__rob__DOT__##n
#define BR(n) r.student_top__DOT__bridge__DOT__arbiter__DOT__##n

struct Profile {
    std::map<std::string, uint64_t> counts;
    std::map<uint64_t, uint64_t> load_latency, store_latency;
    std::array<uint64_t, 4> accepted{};
    std::array<bool, 4> live{}, write{}, mmio{};
    void sample(Vstudent_top &top) {
        if (top.reset) return;
        auto &r = *top.rootp;
        const uint64_t cycle = ++counts["cycles"];
        counts["retired"] += __builtin_popcount(unsigned(ROB(commit_fire_reg)));
#if CONFIG_MSHRS == 2
        const unsigned occupied = __builtin_popcount(unsigned(DC(m_valid)));
        counts["miss_allocations"] += DC(m_allocate);
        counts["merged_requests"] += DC(m_join);
        counts["blocked_second_miss"] += DC(miss_active) && DC(s2_miss) && !DC(m_accept);
        counts["joined_while_delivering"] += DC(m_join) && DC(m_delivery) &&
            DC(m_match_slot) == DC(m_delivery_slot);
#else
        const unsigned occupied = DC(miss_active) ? 1 : 0;
        counts["miss_allocations"] += DC(mode) == 0 && DC(s2_miss);
        counts["blocked_second_miss"] += DC(miss_active) && DC(s2_miss);
#endif
        ++counts["mshr_occupancy_"+std::to_string(occupied)];
        counts["s1_set_locked"] += DC(s1_valid) && DC(s1_locked);
        counts["two_d_reads_in_bridge"] += BR(read_count) == 2 &&
            BR(read_owner)[0] == 1 && BR(read_owner)[1] == 1;
        counts["refills"] += DC(memory_request_valid_o) && DC(memory_request_ready_i) && !DC(memory_request_write_o);
        counts["writebacks"] += DC(memory_request_valid_o) && DC(memory_request_ready_i) && DC(memory_request_write_o);
        counts["refill_installations"] += DC(refill_install);
        counts["hit_responses_under_miss"] += occupied && DC(s2_valid) && !DC(s2_miss) &&
            DC(pipeline_run) && DC(cache_response_push);
        counts["store_confirmations"] += DC(store_confirm_valid_o);
        if (LSQ(cache_response_valid_i) && LSQ(cache_response_ready_o)) {
            const unsigned id = LSQ(cache_response_id_i);
            if (!live[id]) throw std::runtime_error("response without a live request");
            if (!mmio[id]) {
                ++(write[id] ? store_latency : load_latency)[cycle-accepted[id]];
                ++counts[write[id] ? "ram_store_responses" : "ram_load_responses"];
            }
            live[id] = false;
        }
        if (LSQ(cache_request_valid_o) && LSQ(cache_request_ready_i)) {
            const unsigned id = LSQ(cache_request_id_o);
            if (live[id]) throw std::runtime_error("request ID reused before response");
            live[id] = true;
            accepted[id] = cycle;
            write[id] = LSQ(request_write);
            mmio[id] = LSQ(request_mmio);
            if (!mmio[id]) ++counts[write[id] ? "ram_store_requests" : "ram_load_requests"];
        }
    }
    void report() {
        std::cerr << "PROFILE {\"counts\":{";
        bool first = true;
        for (const auto &entry : counts) {
            if (!first) std::cerr << ',';
            first = false;
            std::cerr << '"' << entry.first << "\":" << entry.second;
        }
        std::cerr << '}';
        auto emit = [&](const char *name, const std::map<uint64_t, uint64_t> &hist) {
            std::cerr << ",\"" << name << "\":{";
            bool first_value = true;
            for (const auto &entry : hist) {
                if (!first_value) std::cerr << ',';
                first_value = false;
                std::cerr << '"' << entry.first << "\":" << entry.second;
            }
            std::cerr << '}';
        };
        emit("load_latency", load_latency);
        emit("store_latency", store_latency);
        std::cerr << "}\n";
    }
};
