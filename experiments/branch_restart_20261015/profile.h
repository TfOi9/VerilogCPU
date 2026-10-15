#define Profile BaseProfile
#include "base_profile.h"
#undef Profile
#include <set>
#include <stdexcept>

#define FE(n) CORE(fetch_pipeline__DOT__##n)
#define IRS(n) CORE(int_rs__DOT__##n)

struct Profile : BaseProfile {
    std::map<std::string, std::map<uint64_t, uint64_t>> histograms;
    std::map<unsigned, uint64_t> first_ready;
    bool restart = false, fetched = false, dispatched = false;
    uint64_t redirect_cycle = 0;
    unsigned target_pc = 0, target_tag = 0;

    void sample(Vstudent_top &top) {
        BaseProfile::sample(top);
        if (top.reset) return;
        auto &r = *top.rootp;
        uint64_t cycle = counts["cycles"];
        constexpr unsigned index_bits = __builtin_ctz(CONFIG_ROB);
        constexpr unsigned tag_bits = index_bits + 2;
        constexpr unsigned tag_mask = (1u << tag_bits) - 1;
        std::set<unsigned> live;
        for (unsigned slot = 0; slot < 8; ++slot) {
            if (!IRS(entry_busy)[slot]) continue;
            unsigned op = IRS(entry_op)[slot];
            if (op < 5 || op > 10) continue;
            unsigned tag = IRS(entry_rob_tag)[slot];
            live.insert(tag);
            if (IRS(effective_lhs_ready)[slot] && IRS(effective_rhs_ready)[slot])
                first_ready.emplace(tag, cycle);
            else
                ++counts["branch_operand_wait_samples"];
        }
        for (auto it = first_ready.begin(); it != first_ready.end();) {
            if (!live.count(it->first)) it = first_ready.erase(it);
            else ++it;
        }
        for (unsigned lane = 0; lane < CONFIG_BE; ++lane) {
            if (!((CORE(int_issue_valid) & CORE(int_issue_ready)) >> lane & 1)) continue;
            unsigned op = (uint64_t(CORE(int_issue_op)) >> (6*lane)) & 63;
            if (op < 5 || op > 10) continue;
            unsigned tag = (uint64_t(CORE(int_issue_rob_tag)) >> (tag_bits*lane)) & tag_mask;
            auto found = first_ready.find(tag);
            if (found == first_ready.end()) throw std::runtime_error("issued branch was not ready");
            ++histograms["branch_ready_to_issue"][cycle-found->second];
            first_ready.erase(found);
        }
        if (ROB(recover_redirect_valid_o)) {
            if (restart) ++counts["restart_superseded"];
            restart = true;
            fetched = dispatched = false;
            redirect_cycle = cycle;
            target_pc = ROB(recover_redirect_pc_o);
            ++counts["restart_events"];
        }
        if (!restart || ROB(recover_redirect_valid_o)) return;
        if (!fetched && FE(response_enqueue_fire) && word(FE(candidate_pc), 0) == target_pc) {
            ++histograms["redirect_to_target_enqueue"][cycle-redirect_cycle];
            fetched = true;
        }
        if (!dispatched && CORE(dispatch_fire)) {
            for (unsigned lane = 0; lane < CONFIG_BE; ++lane) {
                if ((CORE(dispatch_valid) >> lane & 1) && word(CORE(dispatch_pc), lane) == target_pc) {
                    target_tag = (uint64_t(CORE(dispatch_rob_tag)) >> (tag_bits*lane)) & tag_mask;
                    ++histograms["redirect_to_target_dispatch"][cycle-redirect_cycle];
                    dispatched = true;
                    break;
                }
            }
        }
        if (dispatched) {
            for (unsigned lane = 0; lane < CONFIG_BE; ++lane) {
                if (!(ROB(commit_fire_reg) >> lane & 1)) continue;
                unsigned slot = (ROB(head_reg) + lane) % CONFIG_ROB;
                unsigned tag = (unsigned(ROB(entry_generation)[slot]) << index_bits) | slot;
                if (tag == target_tag) {
                    ++histograms["redirect_to_target_retire"][cycle-redirect_cycle];
                    restart = false;
                    break;
                }
            }
        }
    }

    void report() {
        BaseProfile::report();
        std::cerr << "BRANCH {";
        bool first_histogram = true;
        for (const auto &histogram : histograms) {
            if (!first_histogram) std::cerr << ',';
            first_histogram = false;
            std::cerr << '"' << histogram.first << "\":{";
            bool first = true;
            for (const auto &entry : histogram.second) {
                if (!first) std::cerr << ',';
                first = false;
                std::cerr << '"' << entry.first << "\":" << entry.second;
            }
            std::cerr << '}';
        }
        std::cerr << "}\n";
    }
};
