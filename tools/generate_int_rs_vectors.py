#!/usr/bin/env python3

import argparse
import random


OP_ADD = 28
OP_ADDI = 19
OP_BEQ = 5
OPS = (OP_ADD, OP_ADDI, OP_BEQ)


def pack(values, width):
    result = 0
    mask = (1 << width) - 1
    for lane, value in enumerate(values):
        result |= (value & mask) << (lane * width)
    return result


class IntegerRsModel:
    def __init__(self, entries, width, phys_regs, rob_entries):
        self.entries = entries
        self.width = width
        self.phys_regs = phys_regs
        self.rob_entries = rob_entries
        self.slots = [None for _ in range(entries)]
        self.locks = [None for _ in range(width)]

    def effective_operand(self, ready, value, phys, broadcasts):
        if ready:
            return True, value
        for valid, broadcast_phys, broadcast_value in broadcasts:
            if valid and broadcast_phys == phys:
                ready = True
                value = broadcast_value
        return ready, value

    def evaluate(self, stimulus):
        reset = stimulus["reset"]
        flush = stimulus["flush"]
        recover = stimulus["recover"]
        broadcasts = stimulus["broadcasts"]
        head = stimulus["head"]
        issue_ready = stimulus["issue_ready"]

        effective = []
        for slot in self.slots:
            if slot is None:
                effective.append(None)
                continue
            lhs_ready, lhs_value = self.effective_operand(
                slot["lhs_ready"], slot["lhs_value"], slot["lhs_phys"],
                broadcasts)
            rhs_ready, rhs_value = self.effective_operand(
                slot["rhs_ready"], slot["rhs_value"], slot["rhs_phys"],
                broadcasts)
            value = dict(slot)
            value["lhs_ready"] = lhs_ready
            value["lhs_value"] = lhs_value
            value["rhs_ready"] = rhs_ready
            value["rhs_value"] = rhs_value
            effective.append(value)

        selected = [None for _ in range(self.width)]
        reserved = set()
        if not reset and not flush and not recover:
            for port, locked_slot in enumerate(self.locks):
                if locked_slot is not None:
                    selected[port] = locked_slot
                    reserved.add(locked_slot)

            for port in range(self.width):
                if self.locks[port] is not None:
                    continue
                candidates = []
                for slot_index, slot in enumerate(effective):
                    if slot is None or slot_index in reserved:
                        continue
                    if not slot["lhs_ready"] or not slot["rhs_ready"]:
                        continue
                    rob_index = slot["tag"] % self.rob_entries
                    distance = (rob_index - head) % self.rob_entries
                    candidates.append((distance, slot_index))
                if candidates:
                    _, winner = min(candidates)
                    selected[port] = winner
                    reserved.add(winner)

        issue_valid = [int(slot is not None) for slot in selected]
        issue_payload = []
        issue_remove = set()
        for port, slot_index in enumerate(selected):
            if slot_index is None:
                issue_payload.append({
                    "op": 0, "lhs_value": 0, "rhs_value": 0,
                    "pc": 0, "immediate": 0, "tag": 0,
                })
                continue
            issue_payload.append(effective[slot_index])
            if issue_ready[port]:
                issue_remove.add(slot_index)

        available = [
            index for index, slot in enumerate(self.slots)
            if slot is None or index in issue_remove
        ]
        dispatches = stimulus["dispatches"]
        dispatch_count = sum(int(item is not None) for item in dispatches)
        dispatch_ready = int(
            not reset and not flush and not recover and
            len(available) >= dispatch_count)
        allocation = [None for _ in range(self.width)]
        if dispatch_ready:
            free_iter = iter(available)
            for lane, item in enumerate(dispatches):
                if item is not None:
                    allocation[lane] = next(free_iter)

        result = {
            "dispatch_ready": dispatch_ready,
            "occupancy": 0 if reset or flush else sum(
                int(slot is not None) for slot in self.slots),
            "issue_valid": issue_valid,
            "issue_payload": issue_payload,
            "selected": selected,
            "issue_remove": issue_remove,
            "allocation": allocation,
            "effective": effective,
        }
        return result

    def update(self, stimulus, result):
        if stimulus["reset"] or stimulus["flush"]:
            self.slots = [None for _ in range(self.entries)]
            self.locks = [None for _ in range(self.width)]
            return

        if stimulus["recover"]:
            rollback_tags = set(stimulus["rollback_tags"])
            removed = set()
            for index, slot in enumerate(self.slots):
                if slot is not None and slot["tag"] in rollback_tags:
                    self.slots[index] = None
                    removed.add(index)
            for port, locked_slot in enumerate(self.locks):
                if locked_slot in removed:
                    self.locks[port] = None
            return

        for port, selected in enumerate(result["selected"]):
            if self.locks[port] is not None:
                if selected is not None and stimulus["issue_ready"][port]:
                    self.locks[port] = None
            elif selected is not None and not stimulus["issue_ready"][port]:
                self.locks[port] = selected

        allocated_slots = set()
        if stimulus["dispatch_fire"] and result["dispatch_ready"]:
            for lane, slot_index in enumerate(result["allocation"]):
                if slot_index is None:
                    continue
                item = dict(stimulus["dispatches"][lane])
                item["lhs_ready"], item["lhs_value"] = self.effective_operand(
                    item["lhs_ready"], item["lhs_value"], item["lhs_phys"],
                    stimulus["broadcasts"])
                item["rhs_ready"], item["rhs_value"] = self.effective_operand(
                    item["rhs_ready"], item["rhs_value"], item["rhs_phys"],
                    stimulus["broadcasts"])
                self.slots[slot_index] = item
                allocated_slots.add(slot_index)

        for slot_index in result["issue_remove"]:
            if slot_index not in allocated_slots:
                self.slots[slot_index] = None

        for slot_index, slot in enumerate(self.slots):
            if slot is None or slot_index in allocated_slots:
                continue
            effective = result["effective"][slot_index]
            slot["lhs_ready"] = effective["lhs_ready"]
            slot["lhs_value"] = effective["lhs_value"]
            slot["rhs_ready"] = effective["rhs_ready"]
            slot["rhs_value"] = effective["rhs_value"]


def random_dispatch(rng, phys_regs, rob_entries, used_indexes):
    free_indexes = [index for index in range(rob_entries)
                    if index not in used_indexes]
    if not free_indexes:
        return None
    rob_index = rng.choice(free_indexes)
    generation = rng.randrange(4)
    tag = (generation * rob_entries) + rob_index
    lhs_ready = rng.random() < 0.55
    rhs_ready = rng.random() < 0.55
    return {
        "op": rng.choice(OPS),
        "pc": rng.getrandbits(32) & ~3,
        "immediate": rng.getrandbits(32),
        "tag": tag,
        "lhs_ready": lhs_ready,
        "lhs_value": rng.getrandbits(32),
        "lhs_phys": rng.randrange(1, phys_regs),
        "rhs_ready": rhs_ready,
        "rhs_value": rng.getrandbits(32),
        "rhs_phys": rng.randrange(1, phys_regs),
    }


def make_stimulus(rng, model, cycle):
    reset = int(cycle == 0)
    flush = int(cycle > 0 and rng.random() < 0.015)
    recover = int(not flush and cycle > 0 and rng.random() < 0.08)

    waiting_phys = []
    for slot in model.slots:
        if slot is None:
            continue
        if not slot["lhs_ready"]:
            waiting_phys.append(slot["lhs_phys"])
        if not slot["rhs_ready"]:
            waiting_phys.append(slot["rhs_phys"])
    rng.shuffle(waiting_phys)
    broadcasts = []
    used_broadcasts = set()
    for _ in range(model.width):
        valid = False
        phys = 0
        if not reset and not flush and not recover and rng.random() < 0.55:
            candidates = [value for value in waiting_phys
                          if value not in used_broadcasts]
            if candidates and rng.random() < 0.8:
                phys = rng.choice(candidates)
            else:
                candidates = [value for value in range(1, model.phys_regs)
                              if value not in used_broadcasts]
                phys = rng.choice(candidates)
            valid = True
            used_broadcasts.add(phys)
        broadcasts.append((int(valid), phys, rng.getrandbits(32)))

    rollback_tags = []
    if recover:
        live_tags = [slot["tag"] for slot in model.slots if slot is not None]
        rng.shuffle(live_tags)
        rollback_tags.extend(live_tags[:rng.randrange(model.width + 1)])
        while len(rollback_tags) < model.width and rng.random() < 0.25:
            stale = rng.randrange(model.rob_entries * 4)
            if stale not in rollback_tags:
                rollback_tags.append(stale)

    used_indexes = {
        slot["tag"] % model.rob_entries
        for slot in model.slots if slot is not None
    }
    dispatches = [None for _ in range(model.width)]
    if not reset and not flush and not recover:
        for lane in range(model.width):
            if rng.random() < 0.55:
                item = random_dispatch(
                    rng, model.phys_regs, model.rob_entries, used_indexes)
                if item is not None:
                    dispatches[lane] = item
                    used_indexes.add(item["tag"] % model.rob_entries)

    return {
        "reset": reset,
        "flush": flush,
        "recover": recover,
        "dispatches": dispatches,
        "dispatch_fire": 0,
        "broadcasts": broadcasts,
        "head": rng.randrange(model.rob_entries),
        "rollback_tags": rollback_tags,
        "issue_ready": [rng.randrange(2) for _ in range(model.width)],
    }


def packed_stimulus(stimulus, result, width, phys_width, rob_tag_width):
    dispatches = []
    for item in stimulus["dispatches"]:
        dispatches.append(item or {
            "op": 0, "pc": 0, "immediate": 0, "tag": 0,
            "lhs_ready": 1, "lhs_value": 0, "lhs_phys": 0,
            "rhs_ready": 1, "rhs_value": 0, "rhs_phys": 0,
        })
    broadcasts = stimulus["broadcasts"]
    rollback = stimulus["rollback_tags"] + [0] * (
        width - len(stimulus["rollback_tags"]))
    issue_payload = result["issue_payload"]

    values = [
        stimulus["reset"], stimulus["flush"], stimulus["recover"],
        pack([int(item is not None) for item in stimulus["dispatches"]], 1),
        stimulus["dispatch_fire"],
        pack([item["op"] for item in dispatches], 6),
        pack([item["pc"] for item in dispatches], 32),
        pack([item["immediate"] for item in dispatches], 32),
        pack([item["tag"] for item in dispatches], rob_tag_width),
        pack([item["lhs_ready"] for item in dispatches], 1),
        pack([item["lhs_value"] for item in dispatches], 32),
        pack([item["lhs_phys"] for item in dispatches], phys_width),
        pack([item["rhs_ready"] for item in dispatches], 1),
        pack([item["rhs_value"] for item in dispatches], 32),
        pack([item["rhs_phys"] for item in dispatches], phys_width),
        pack([item[0] for item in broadcasts], 1),
        pack([item[1] for item in broadcasts], phys_width),
        pack([item[2] for item in broadcasts], 32),
        stimulus["head"],
        (1 << len(stimulus["rollback_tags"])) - 1,
        pack(rollback, rob_tag_width),
        pack(stimulus["issue_ready"], 1),
        result["dispatch_ready"], result["occupancy"],
        pack(result["issue_valid"], 1),
        pack([item["op"] for item in issue_payload], 6),
        pack([item["lhs_value"] for item in issue_payload], 32),
        pack([item["rhs_value"] for item in issue_payload], 32),
        pack([item["pc"] for item in issue_payload], 32),
        pack([item["immediate"] for item in issue_payload], 32),
        pack([item["tag"] for item in issue_payload], rob_tag_width),
    ]
    return " ".join(f"{value:x}" for value in values)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--entries", type=int, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--phys-regs", type=int, required=True)
    parser.add_argument("--rob-entries", type=int, required=True)
    parser.add_argument("--cycles", type=int, default=500)
    parser.add_argument("--seed", type=int, default=20260823)
    args = parser.parse_args()

    phys_width = (args.phys_regs - 1).bit_length()
    rob_index_width = (args.rob_entries - 1).bit_length()
    rob_tag_width = rob_index_width + 2
    rng = random.Random(args.seed)
    model = IntegerRsModel(
        args.entries, args.width, args.phys_regs, args.rob_entries)

    lines = []
    for cycle in range(args.cycles):
        stimulus = make_stimulus(rng, model, cycle)
        result = model.evaluate(stimulus)
        stimulus["dispatch_fire"] = int(
            result["dispatch_ready"] and
            any(item is not None for item in stimulus["dispatches"]) and
            rng.random() < 0.8)
        result = model.evaluate(stimulus)
        lines.append(packed_stimulus(
            stimulus, result, args.width, phys_width, rob_tag_width))
        model.update(stimulus, result)

    with open(args.output, "w", encoding="ascii") as output_file:
        output_file.write("\n".join(lines))
        output_file.write("\n")


if __name__ == "__main__":
    main()
