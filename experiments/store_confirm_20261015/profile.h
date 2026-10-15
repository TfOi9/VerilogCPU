#define Profile BaseProfile
#include "base_profile.h"
#undef Profile
#include <array>
#include <stdexcept>

struct Profile : BaseProfile {
    std::map<uint64_t, uint64_t> retired_branch_count, retired_branch_wrong;
    std::map<uint64_t, uint64_t> refill_lines, load_latencies, store_latencies;
    std::array<uint64_t, 4> request_cycle{};
    std::array<bool, 4> request_write{}, request_live{};

    void sample(Vstudent_top &top) {
        BaseProfile::sample(top);
        if (top.reset) return;
        auto &r = *top.rootp;
        uint64_t cycle = counts["cycles"];
        for (unsigned lane = 0; lane < CONFIG_BE; ++lane) {
            if (!((ROB(commit_fire_reg) >> lane) & 1)) continue;
            unsigned slot = (ROB(head_reg) + lane) % CONFIG_ROB;
            unsigned op = ROB(entry_op)[slot];
            if (op < 3 || op > 10) continue;
            uint64_t pc = ROB(entry_pc)[slot];
            ++retired_branch_count[pc];
            bool wrong = ROB(entry_predicted_next_pc)[slot] != ROB(entry_next_pc)[slot];
            retired_branch_wrong[pc] += wrong;
            std::string kind = op == 3 ? "jal" : op == 4 ? "jalr" : "conditional";
            ++counts["detail_retired_" + kind];
            counts["detail_retired_wrong_" + kind] += wrong;
        }
        counts["detail_late_confirmations"] += DC(store_confirm_valid_o);
        counts["detail_live_confirmations"] += LSQ(confirm_live);
        if (LSQ(confirm_live) && (CORE(commit_fire) & 1) &&
            (CORE(commit_lsq_tag) & 31) == LSQ(confirm_lsq_tag))
            ++counts["detail_retired_on_confirmation"];
        counts["detail_second_miss_stall"] += DC(miss_active) && DC(s2_miss);
        counts["detail_s1_same_set_lock"] += DC(s1_valid) && DC(s1_locked);
        counts["detail_s1_same_line_lock"] += DC(s1_valid) && DC(s1_locked) &&
            (DC(s1_address) >> 4) == DC(miss_line_address) / 16;
        counts["detail_second_same_line"] += DC(miss_active) && DC(s2_miss) &&
            (DC(s2_address) >> 4) == DC(miss_line_address) / 16;
        counts["detail_hit_during_miss"] += DC(miss_active) && DC(response_push) && DC(mode) != 5;
        counts["detail_refill_install"] += DC(refill_install);
        if (DC(mode) == 0 && DC(s2_miss))
            ++counts[DC(s2_write) ? "detail_store_misses" : "detail_load_misses"];
        if (DC(request_valid_i) && DC(request_ready_o) && DC(request_write_i)) {
            ++counts["detail_accepted_ram_stores"];
            if (DC(request_irrevocable_o)) ++counts["detail_posted_ram_stores"];
            else if (!DC(hint_match)) ++counts["detail_store_no_hint"];
            else if (DC(older_conflict)) ++counts["detail_store_older_conflict"];
            else ++counts["detail_store_other"];
        }
        if (DC(memory_request_valid_o) && DC(memory_request_ready_i) && !DC(memory_request_write_o))
            ++refill_lines[DC(memory_request_address_o) >> 4];
        // Consume first so same-cycle ID reuse retains the new request.
        if (LSQ(cache_response_valid_i) && LSQ(cache_response_ready_o)) {
            unsigned id = LSQ(cache_response_id_i);
            if (!request_live[id]) throw std::runtime_error("response without request");
            auto &hist = request_write[id] ? store_latencies : load_latencies;
            ++hist[cycle-request_cycle[id]];
            ++counts[request_write[id] ? "detail_store_responses" : "detail_load_responses"];
            request_live[id] = false;
        }
        if (LSQ(cache_request_valid_o) && LSQ(cache_request_ready_i)) {
            unsigned id = LSQ(cache_request_id_o);
            if (request_live[id]) throw std::runtime_error("live request ID reused");
            request_live[id] = true;
            request_cycle[id] = cycle;
            request_write[id] = LSQ(request_write);
        }
    }

    void report() {
        BaseProfile::report();
        std::cerr << "DETAIL {";
        bool first_map = true;
        auto emit = [&](const char *name, const std::map<uint64_t, uint64_t> &values) {
            if (!first_map) std::cerr << ',';
            first_map = false;
            std::cerr << '"' << name << "\":{";
            bool first = true;
            for (const auto &v : values) {
                if (!first) std::cerr << ',';
                first = false;
                std::cerr << '"' << v.first << "\":" << v.second;
            }
            std::cerr << '}';
        };
        emit("retired_branch_count", retired_branch_count);
        emit("retired_branch_wrong", retired_branch_wrong);
        emit("refill_lines", refill_lines);
        emit("load_latencies", load_latencies);
        emit("store_latencies", store_latencies);
        std::cerr << "}\n";
    }
};
