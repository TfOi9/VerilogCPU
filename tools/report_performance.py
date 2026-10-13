#!/usr/bin/env python3
"""Join verified performance, correctness and opt synthesis results."""

import argparse
import csv
import hashlib
import io
import itertools
import json
import math
from pathlib import Path
import sys

from run_parameter_matrix import REPRESENTATIVES, SEEDS, config_name, parameters
from run_performance import (BASELINE, PARAMETER_VALUES, ROOT, all_configs, case_result,
                             geomean, load_cases, write_json)
from run_synthesis import digest, validate_report


KEYS = tuple(parameters(BASELINE))
TIERS = ((9000, 0.6000, 300), (18000, 0.8450, 300), (36000, 1.0985, 300))
SMOKE_RESULTS = {"smoke_accumulate": 5050, "smoke_core_ooo": 42}


def configuration(row):
    return tuple(row[key] for key in KEYS)


def verify_hashes(hashes, ignored=()):
    if not hashes:
        raise ValueError("missing source provenance")
    ignored = {Path(path).resolve() for path in ignored}
    for name, expected in hashes.items():
        path = Path(name).resolve()
        if path not in ignored and (not path.is_file() or digest(path) != expected):
            raise ValueError("stale or missing input: " + str(path))


def require_passed(report, name):
    if any(report.get(key) is not True for key in ("completed", "passed", "sources_unchanged")):
        raise ValueError(name + " report is incomplete, failed or changed during execution")


def functional_input(result, testcases, limit, latency, prepare_case):
    name = result["case"]
    if name.startswith("smoke_"):
        if name not in SMOKE_RESULTS:
            raise ValueError("unknown local smoke case: " + name)
        program = name[len("smoke_"):]
        image = Path(result["log"]).resolve().parent.parent / "images" / (program + "-widths") / (program + ".image")
        data = "CPU2026-OJ 1\n{} {}\n{}\n".format(limit, latency, image.read_text().rstrip())
        return data, str(SMOKE_RESULTS[name]) + "\n"
    return prepare_case(testcases / name, limit, latency)


def gates(area, ipc, frequency):
    stages = []
    for number, (max_area, min_ipc, min_frequency) in enumerate(TIERS, 1):
        conditions = {"area_pass": area <= max_area, "ipc_pass": ipc >= min_ipc,
                      "frequency_pass": frequency >= min_frequency}
        stages.append(dict(conditions, stage=number, eligible=all(conditions.values())))
    highest = max((s["stage"] for s in stages if s["eligible"]), default=0)
    bonus = (4 if frequency >= 500 else 2 if frequency >= 400 else 0) if highest else 0
    return {"stages": stages, "highest_eligible_stage": highest, "frequency_bonus": bonus,
            "frequency_thresholds": {str(f): frequency >= f for f in (300, 400, 500)}}


def pareto(rows, maximize):
    def dominates(a, b):
        comparisons = [a["area_um2"] <= b["area_um2"]] + [a[k] >= b[k] for k in maximize]
        strict = a["area_um2"] < b["area_um2"] or any(a[k] > b[k] for k in maximize)
        return all(comparisons) and strict
    return [r["configuration"] for r in rows if not any(dominates(other, r) for other in rows)]


def comparison(performance, synthesis, matrix):
    for report, label in ((performance, "performance"), (synthesis, "synthesis"), (matrix, "matrix")):
        require_passed(report, label)
    verify_hashes(performance["source_sha256"])
    # These reporting tools are globbed into the matrix manifest but never executed by it.
    matrix_reporting_tools = [Path(__file__).resolve(), ROOT / "tools/test_performance.py"]
    verify_hashes(matrix["source_sha256"], ignored=matrix_reporting_tools)
    # Makefile targets for measurement do not alter the recorded synthesis command or RTL.
    verify_hashes(synthesis["source_sha256"], ignored=[ROOT / "Makefile"])
    for name, value in performance["hardware_sha256"].items():
        if synthesis["source_sha256"].get(name) != value:
            raise ValueError("performance and synthesis hardware differ: " + name)
        matrix_hashes = {str(Path(p).resolve()): h for p, h in matrix["source_sha256"].items()}
        if matrix_hashes.get(name) != value:
            raise ValueError("performance and correctness hardware differ: " + name)
    framework = Path(performance["framework"])
    sys.path.insert(0, str(framework / "scripts"))
    from build import read_sources
    from fakeram import RAM_SOURCE
    from oj_io import compare_output, prepare_case
    sources = read_sources(Path(performance["filelist"]))
    headers = {h for p in sources for h in p.parent.glob("*.vh")}
    expected_hardware = {str(p): digest(p) for p in sources + sorted(headers) + [RAM_SOURCE]}
    if performance["hardware_sha256"] != expected_hardware:
        raise ValueError("performance hardware manifest is incomplete or stale")
    cases = load_cases(Path(performance["testcases"]), performance["max_cycles"],
                      performance["latency"], prepare_case)
    expected_cases = {c["name"]: c for c in cases}
    manifest = [{"name": c["name"], "dynamic_instructions": c["dynamic_instructions"]} for c in cases]
    if performance["cases"] != manifest:
        raise ValueError("official performance case set or instruction counts changed")
    measured = {}
    for row in performance["results"]:
        current = configuration(row)
        if current in measured or not row["passed"] or not row["build"]["passed"]:
            raise ValueError("duplicate or failed performance configuration")
        verify_hashes({row["simulator"]["path"]: row["simulator"]["sha256"]})
        if len(row["cases"]) != len(cases) or {c["name"] for c in row["cases"]} != set(expected_cases):
            raise ValueError("missing or duplicate performance cases")
        ipcs = []
        for result in row["cases"]:
            case = expected_cases[result["name"]]
            cycles = case_result(Path(result["stdout_path"]).read_text(),
                                 Path(result["stderr_path"]).read_text(), result["returncode"],
                                 case["answer"], performance["max_cycles"], compare_output)
            ipc = case["dynamic_instructions"] / cycles
            if not result["passed"] or result["cycles"] != cycles or result["ipc"] != ipc or \
                    result["dynamic_instructions"] != case["dynamic_instructions"] or \
                    result["input_sha256"] != hashlib.sha256(case["data"].encode()).hexdigest():
                raise ValueError("performance data does not match raw run")
            ipcs.append(ipc)
        if not math.isclose(row["ipc_geomean"], geomean(ipcs), rel_tol=1e-12):
            raise ValueError("incorrect IPC geometric mean")
        measured[current] = row
    if set(measured) != set(all_configs()) or \
            {configuration(c) for c in performance["configurations"]} != set(all_configs()):
        raise ValueError("full representative and sensitivity coverage is required")
    if matrix["testcases_revision"] != performance["testcases_revision"]:
        raise ValueError("correctness and performance testcase revisions differ")
    if matrix["phase"] != "all" or matrix["focused_config"] is not None or \
            {configuration(c) for c in matrix["representatives"]} != set(REPRESENTATIVES):
        raise ValueError("full correctness matrix is required")
    full_matrix = set(itertools.product(*PARAMETER_VALUES))
    if len(matrix["matrix"]) != len(full_matrix) or \
            {configuration(c) for c in matrix["matrix"]} != full_matrix:
        raise ValueError("incomplete static parameter matrix")
    expected_checks = {(c, stage) for c in full_matrix for stage in
                       ("iverilog-2005", "parameter-startup", "verilator", "yosys")}
    expected_checks.update((c, stage) for c in REPRESENTATIVES for stage in
                           ("core-build", "official-build", "functional"))
    expected_checks.update((c, "retirement-{}".format(seed)) for c in REPRESENTATIVES for seed in SEEDS)
    expected_checks.update((None, "generate-{}".format(seed)) for seed in SEEDS)
    actual_checks = [(configuration(c) if all(k in c for k in KEYS) else None, c["stage"])
                     for c in matrix["checks"]]
    if len(actual_checks) != len(expected_checks) or set(actual_checks) != expected_checks:
        raise ValueError("missing or duplicate static/retirement checks")
    expected_functional = {p.name for p in Path(performance["testcases"]).glob("correctness_*") if p.is_dir()}
    expected_functional.update(("perf_multiply", "perf_vvadd"))
    expected_functional.update(SMOKE_RESULTS)
    if len(matrix["functional"]) != len(REPRESENTATIVES):
        raise ValueError("missing functional configurations")
    functional_configs = set()
    for group in matrix["functional"]:
        results = group["results"]
        if not group["completed"] or not group["passed"] or len(results) != len(expected_functional) or \
                {r["case"] for r in results} != expected_functional:
            raise ValueError("missing or duplicate functional cases")
        configs = {(r["fe_width"], r["be_width"], r["phys_regs"], r["rob_entries"]) for r in results}
        if len(configs) != 1 or configs & functional_configs:
            raise ValueError("inconsistent or duplicate functional configuration")
        functional_configs.update(configs)
    if functional_configs != set(REPRESENTATIVES):
        raise ValueError("incomplete functional representative coverage")
    functional = [r for group in matrix["functional"] for r in group["results"]]
    for result in functional:
        data, answer = functional_input(result, Path(performance["testcases"]),
                                        matrix["max_cycles"], matrix["latency"], prepare_case)
        if not result["passed"] or result["expected"] != int(answer) or \
                result["input_sha256"] != hashlib.sha256(data.encode()).hexdigest():
            raise ValueError("correctness input changed or failed")
    if not matrix["checks"] or not all(c["passed"] for c in matrix["checks"]):
        raise ValueError("failed static/retirement check")
    opt = {}
    for row in synthesis["results"]:
        if row["mode"] != "opt":
            continue
        current = configuration(row)
        if current in opt or not row["passed"]:
            raise ValueError("duplicate or failed opt synthesis configuration")
        report = row["report"]
        if json.loads(Path(row["report_path"]).read_text()) != report:
            raise ValueError("synthesis report differs from raw report")
        validate_report(report, "opt", synthesis["clock_period_ns"])
        verify_hashes(row["generated_source_sha256"])
        verify_hashes({i["path"]: i["sha256"] for i in report["inputs"] + report["libraries"]})
        opt[current] = row
    if not set(REPRESENTATIVES) <= set(opt):
        raise ValueError("missing representative opt synthesis results")
    rows = []
    for current in REPRESENTATIVES:
        report = opt[current]["report"]
        area, timing = report["area"], report["timing"]
        ipc = measured[current]["ipc_geomean"]
        frequency = timing["estimated_fmax_mhz"]
        row = dict(parameters(current), configuration=config_name(current), ipc_geomean=ipc,
                   area_um2=area["area_um2"], combinational_area_um2=area["combinational_area_um2"],
                   sequential_area_um2=area["sequential_area_um2"], sram_area_um2=area["sram_area_um2"],
                   fmax_mhz=frequency, minimum_period_ns=timing["minimum_period_ns"],
                   worst_setup_slack_ns=timing["worst_setup_slack_ns"],
                   estimated_mips=ipc * frequency, ipc_per_1000_um2=ipc * 1000 / area["area_um2"],
                   gates=gates(area["area_um2"], ipc, frequency),
                   critical_paths=timing["critical_paths"], synthesis_report=opt[current]["report_path"])
        rows.append(row)
    sensitivity = []
    baseline_ipc = measured[BASELINE]["ipc_geomean"]
    for index, values in enumerate(PARAMETER_VALUES):
        for value in values:
            current = list(BASELINE)
            current[index] = value
            source = measured[tuple(current)]
            baseline_cases = {r["name"]: r["ipc"] for r in measured[BASELINE]["cases"]}
            sensitivity.append({"parameter": KEYS[index], "value": value,
                                "configuration": config_name(tuple(current)),
                                "ipc_geomean": source["ipc_geomean"],
                                "ipc_change_percent": (source["ipc_geomean"] / baseline_ipc - 1) * 100,
                                "case_change_percent": {c["name"]: (c["ipc"] / baseline_cases[c["name"]] - 1) * 100
                                                        for c in source["cases"]}})
    return {"schema_version": 1, "completed": True, "passed": True,
            "testcases_revision": performance["testcases_revision"],
            "latency": performance["latency"], "max_cycles": performance["max_cycles"],
            "hardware_sha256": performance["hardware_sha256"],
            "correctness": {"programs_passed": len(functional), "checks_passed": len(matrix["checks"]),
                            "official_correctness_passed": sum(r["case"].startswith("correctness_") for r in functional),
                            "official_performance_passed": sum(r["case"].startswith("perf_") for r in functional),
                            "local_smoke_passed": sum(r["case"] in SMOKE_RESULTS for r in functional)},
            "provenance_exclusions": {"matrix_non_execution_reporting_tools": [str(p) for p in matrix_reporting_tools],
                                      "synthesis_non_execution_build_targets": [str(ROOT / "Makefile")]},
            "performance": {"configurations_passed": len(measured),
                            "cases_per_configuration": len(cases), "runs_passed": len(cases) * len(measured)},
            "cases": manifest, "rows": rows, "sensitivity_baseline": parameters(BASELINE),
            "sensitivity": sensitivity,
            "pareto": {"area_ipc": pareto(rows, ["ipc_geomean"]),
                       "area_ipc_frequency": pareto(rows, ["ipc_geomean", "fmax_mhz"]),
                       "area_estimated_throughput": pareto(rows, ["estimated_mips"])}}


def markdown(report, performance):
    lines = ["# 第 27 项：性能、面积与频率", "",
             "全部 {} 个配置、每个配置 {} 个官方性能测试通过，共 {} 次运行。".format(
                 report["performance"]["configurations_passed"], report["performance"]["cases_per_configuration"],
                 report["performance"]["runs_passed"]),
             "功能矩阵：{} 个程序、{} 项静态及退休差分检查通过。".format(
                 report["correctness"]["programs_passed"], report["correctness"]["checks_passed"]),
             "其中 {} 次官方正确性、{} 次既有性能回归及 {} 次本地 smoke。".format(
                 report["correctness"]["official_correctness_passed"], report["correctness"]["official_performance_passed"],
                 report["correctness"]["local_smoke_passed"]),
             "", "IPC 使用官方动态指令数 / 原始仿真周期，综合值为全部 perf_* 的几何平均。",
             "主存响应延迟为 {} 周期；测试集版本 `{}`。".format(report["latency"], report["testcases_revision"]),
             "面积和频率均来自同一配置的 opt 网表，包含 FakeRAM 估算 SRAM，排除外部主存。",
             "时序为理想时钟、无布线寄生的 OpenSTA 估算；估算 MIPS = IPC × Fmax，不是实测吞吐量。",
             "", "## 9 个代表配置", "",
             "| FE×BE / PRF / ROB | IPC 几何平均 | 组合 μm² | 时序 μm² | SRAM μm² | 总面积 μm² | Fmax MHz | Setup slack ns | 估算 MIPS |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in report["rows"]:
        lines.append("| {configuration} | {ipc_geomean:.6f} | {combinational_area_um2:.3f} | {sequential_area_um2:.3f} | {sram_area_um2:.3f} | {area_um2:.3f} | {fmax_mhz:.2f} | {worst_setup_slack_ns:+.4f} | {estimated_mips:.3f} |".format(**row))
    lines += ["", "## 官方门槛", "", "每档三个布尔值分别为面积 / IPC / 300 MHz；必须同时通过。频率加分也以达到某档为前提。",
              "", "| 配置 | 9000 / 0.6000 / 300 | 18000 / 0.8450 / 300 | 36000 / 1.0985 / 300 | 300 / 400 / 500 MHz | 达标档位 | 频率加分 |",
              "| --- | --- | --- | --- | --- | ---: | ---: |"]
    flag = lambda value: "通过" if value else "未达"
    for row in report["rows"]:
        checks = row["gates"]
        fields = [" / ".join(flag(s[k]) for k in ("area_pass", "ipc_pass", "frequency_pass"))
                  for s in checks["stages"]]
        frequencies = " / ".join(flag(v) for v in checks["frequency_thresholds"].values())
        lines.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            row["configuration"], *fields, frequencies, checks["highest_eligible_stage"], checks["frequency_bonus"]))
    lines += ["", "## 单参数 IPC 敏感度", "",
              "基准 `2×2 / PRF64 / ROB32`；每行只改变所列参数，其他参数与缓存、主存延迟保持相同。",
              "这些额外对照仅用于 IPC；未综合的配置不填面积或频率，不参与联合 Pareto 比较。",
              "", "| 参数 | 值 | 配置 | IPC 几何平均 | 相对基准 |", "| --- | ---: | --- | ---: | ---: |"]
    for row in report["sensitivity"]:
        lines.append("| {parameter} | {value} | {configuration} | {ipc_geomean:.6f} | {ipc_change_percent:+.3f}% |".format(**row))
    lines += ["", "## Pareto frontier", "",
              "仅比较上述 9 个拥有同源 IPC、面积和时序结果的代表配置，不能视为全部参数空间的全局最优。",
              "支配条件：面积不增大，所列性能指标不降低，且至少一项严格改善。", ""]
    for key, description in (("area_ipc", "面积最小、IPC 最大"),
                             ("area_ipc_frequency", "面积最小、IPC 与频率最大"),
                             ("area_estimated_throughput", "面积最小、估算吞吐量最大")):
        lines.append("- {}：{}。".format(description, "、".join(report["pareto"][key])))
    cases = [c["name"] for c in report["cases"]]
    lines += ["", "## 全部原始 cycles 与 IPC", "",
              "单元格为 `cycles / IPC`；指令数：" + "，".join("{}={}".format(c["name"], c["dynamic_instructions"]) for c in report["cases"]) + "。",
              "", "| 配置 | " + " | ".join(cases) + " | 几何平均 |",
              "| --- | " + " | ".join("---:" for c in cases) + " | ---: |"]
    for row in performance["results"]:
        results = {c["name"]: c for c in row["cases"]}
        values = ["{} / {:.6f}".format(results[c]["cycles"], results[c]["ipc"]) for c in cases]
        lines.append("| {} | {} | {:.6f} |".format(config_name(configuration(row)), " | ".join(values), row["ipc_geomean"]))
    lines += ["", "## 关键路径", "",
              "映射单元起止点详见同配置 opt/timing.rpt；下表列出最差路径。",
              "", "| 配置 | Startpoint | Endpoint | Arrival ns | Slack ns | 最小时钟周期 ns |",
              "| --- | --- | --- | ---: | ---: | ---: |"]
    for row in report["rows"]:
        path = row["critical_paths"][0]
        lines.append("| {} | `{}` | `{}` | {:.3f} | {:+.3f} | {:.6f} |".format(
            row["configuration"], path["startpoint"], path["endpoint"], path["arrival_ns"], path["slack_ns"], row["minimum_period_ns"]))
    return "\n".join(lines) + "\n"


def csv_text(rows, fields):
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--performance", type=Path, default=Path("reports/performance.json"))
    parser.add_argument("--synthesis", type=Path, default=Path("reports/synthesis-matrix.json"))
    parser.add_argument("--matrix", type=Path, default=Path("reports/matrix.json"))
    parser.add_argument("--out", type=Path, default=Path("reports/performance-comparison"))
    args = parser.parse_args()
    output = args.out.resolve()
    try:
        performance = json.loads(args.performance.read_text())
        synthesis = json.loads(args.synthesis.read_text())
        matrix = json.loads(args.matrix.read_text())
        report = comparison(performance, synthesis, matrix)
        report["input_reports_sha256"] = {str(p.resolve()): digest(p) for p in
                                         (args.performance, args.synthesis, args.matrix)}
        write_json(output.with_suffix(".json"), report)
        output.with_suffix(".md").write_text(markdown(report, performance))
        output.with_suffix(".csv").write_text(csv_text(report["rows"],
            ["configuration", *KEYS, "ipc_geomean", "combinational_area_um2", "sequential_area_um2",
             "sram_area_um2", "area_um2", "fmax_mhz", "minimum_period_ns", "worst_setup_slack_ns", "estimated_mips"]))
        rows = [dict(c, configuration=config_name(configuration(row)))
                for row in performance["results"] for c in row["cases"]]
        output.with_name(output.name + "-cases.csv").write_text(csv_text(rows,
            ["configuration", "name", "dynamic_instructions", "cycles", "ipc", "elapsed_seconds"]))
        print("PASS comparison: " + str(output.with_suffix(".md")))
        return 0
    except (ValueError, KeyError, TypeError, OSError) as error:
        write_json(output.with_suffix(".json"), {"completed": False, "passed": False, "error": str(error)})
        output.with_suffix(".md").write_text("# Comparison unavailable\n\n" + str(error) + "\n")
        output.with_suffix(".csv").unlink(missing_ok=True)
        output.with_name(output.name + "-cases.csv").unlink(missing_ok=True)
        print("error: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
