#!/usr/bin/env python3
"""Download pinned ASAP7 libraries and build native OpenSTA under .deps."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("jobs must be positive")
    lock = json.loads((ROOT / "third_party/synthesis-lock.json").read_text())
    deps = ROOT / ".deps"
    downloads = deps / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    if platform.system() == "Darwin":
        brew = Path(subprocess.check_output(["brew", "--prefix"], text=True).strip())
        environment["PATH"] = ":".join(str(brew / "opt" / package / "bin") for package in
                                       ("bison", "flex", "tcl-tk@8")) + ":" + environment["PATH"]
        environment["PKG_CONFIG_PATH"] = str(brew / "opt/libffi/lib/pkgconfig") + ":" + environment.get("PKG_CONFIG_PATH", "")
    for tool in ("curl", "7z", "cmake", "make", "autoreconf", "swig", "bison", "flex", "clang++", "pkg-config"):
        if not shutil.which(tool, path=environment["PATH"]):
            parser.error("missing build dependency: " + tool)

    def run(command, cwd=ROOT, seconds=600):
        subprocess.run(command, cwd=cwd, env=environment, check=True, timeout=seconds)

    for archive in lock["archives"]:
        name = archive["name"]
        path = downloads / name
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != archive["sha256"]:
            repositories = {"opensta": "The-OpenROAD-Project/OpenSTA", "cudd": "ivmai/cudd",
                            "yosys": "YosysHQ/yosys", "abc": "YosysHQ/abc", "cxxopts": "jarro2783/cxxopts"}
            package = name.removesuffix(".tar.gz")
            if package in repositories:
                url = "https://codeload.github.com/" + repositories[package] + "/tar.gz/" + lock[package + "_commit"]
            else:
                url = "https://raw.githubusercontent.com/The-OpenROAD-Project/asap7sc7p5t_28/"
                url += lock["asap7_commit"] + "/LIB/NLDM/" + name
            temporary = path.with_suffix(".download")
            run(["curl", "-fL", "--retry", "2", "--connect-timeout", "10", "--max-time", "300",
                 url, "-o", str(temporary)], seconds=960)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != archive["sha256"]:
                raise ValueError("archive checksum mismatch: " + name)
            temporary.replace(path)
        print("Verified " + name, flush=True)

    libraries = deps / "asap7/lib"
    libraries.mkdir(parents=True, exist_ok=True)
    for archive in downloads.glob("asap7*.lib.7z"):
        run(["7z", "e", "-y", "-o" + str(libraries), str(archive)], seconds=30)
    for entry in lock["libraries"]:
        if hashlib.sha256((libraries / entry["name"]).read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Liberty checksum mismatch: " + entry["name"])

    src = deps / "src"
    src.mkdir(exist_ok=True)
    for name in ("cudd", "opensta", "yosys", "abc", "cxxopts"):
        folder = src / (("OpenSTA" if name == "opensta" else name) + "-" + lock[name + "_commit"])
        marker = folder / ".archive-sha256"
        checksum = next(item["sha256"] for item in lock["archives"] if item["name"] == name + ".tar.gz")
        if not marker.exists() or marker.read_text().strip() != checksum:
            with tarfile.open(downloads / (name + ".tar.gz")) as archive:
                archive.extractall(src, filter="data")
            marker.write_text(checksum + "\n")
    cudd = src / ("cudd-" + lock["cudd_commit"])
    run(["autoreconf", "-fi"], cwd=cudd, seconds=120)
    run(["./configure", "--prefix=" + str(deps / "cudd"), "--enable-shared=no"], cwd=cudd, seconds=120)
    run(["make", "-j" + str(args.jobs)], cwd=cudd)
    run(["make", "install"], cwd=cudd, seconds=60)

    source = src / ("OpenSTA-" + lock["opensta_commit"])
    # Archive builds must not inherit the enclosing CPU repository's revision.
    cmake = source / "CMakeLists.txt"
    text = cmake.read_text()
    old = "get_git_head_revision(GIT_REFSPEC STA_GIT_SHA1)"
    revision = 'set(STA_GIT_SHA1 "' + lock["opensta_commit"] + '")'
    if text.count(old) != 1 and text.count(revision) != 1:
        raise ValueError("unsupported OpenSTA revision metadata")
    if old in text:
        cmake.write_text(text.replace(old, revision))
    command = ["cmake", "-S", str(source), "-B", str(deps / "opensta-build"),
               "-DCMAKE_BUILD_TYPE=Release", "-DCUDD_DIR=" + str(deps / "cudd"),
               "-DCMAKE_INSTALL_PREFIX=" + str(deps / "opensta"),
               "-DUSE_TCL_READLINE=OFF", "-DBUILD_TESTS=OFF"]
    if platform.system() == "Darwin":
        command += ["-DBISON_EXECUTABLE=" + str(brew / "opt/bison/bin/bison"),
                    "-DFLEX_EXECUTABLE=" + str(brew / "opt/flex/bin/flex"),
                    "-DFLEX_INCLUDE_DIR=" + str(brew / "opt/flex/include"),
                    "-DTCL_LIBRARY=" + str(brew / "opt/tcl-tk@8/lib/libtcl8.6.dylib"),
                    "-DTCL_INCLUDE_PATH=" + str(brew / "opt/tcl-tk@8/include")]
    run(command, seconds=120)
    run(["cmake", "--build", str(deps / "opensta-build"), "-j" + str(args.jobs)])
    run(["cmake", "--install", str(deps / "opensta-build")], seconds=60)

    abc = src / ("abc-" + lock["abc_commit"])
    run(["make", "-j" + str(args.jobs), "CC=clang", "CXX=clang++", "ABC_USE_STDINT_H=1",
         "ABC_USE_NO_READLINE=1"], cwd=abc, seconds=900)
    prefix = deps / "yosys"
    (prefix / "bin").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(abc / "abc", prefix / "bin/yosys-abc")
    (prefix / "bin/yosys-abc").chmod(0o755)
    yosys = src / ("yosys-" + lock["yosys_commit"])
    shutil.copytree(src / ("cxxopts-" + lock["cxxopts_commit"]), yosys / "libs/cxxopts", dirs_exist_ok=True)
    options = ["CONFIG=clang", "PREFIX=" + str(prefix), "ABCEXTERNAL=" + str(prefix / "bin/yosys-abc"),
               "ENABLE_TCL=0", "ENABLE_READLINE=0"]
    run(["make", "-j" + str(args.jobs), *options], cwd=yosys, seconds=900)
    run(["make", "install", *options], cwd=yosys, seconds=60)
    licenses = deps / "asap7/licenses"
    licenses.mkdir(parents=True, exist_ok=True)
    license_file = licenses / "LICENSE"
    if not license_file.is_file():
        run(["curl", "-fL", "--max-time", "60", "https://raw.githubusercontent.com/"
             "The-OpenROAD-Project/asap7sc7p5t_28/" + lock["asap7_commit"] + "/LICENSE",
             "-o", str(license_file)], seconds=70)
    (deps / "opensta/licenses").mkdir(exist_ok=True)
    shutil.copyfile(source / "LICENSE", deps / "opensta/licenses/OpenSTA")
    shutil.copyfile(cudd / "LICENSE", deps / "opensta/licenses/CUDD")
    (prefix / "licenses").mkdir(exist_ok=True)
    shutil.copyfile(yosys / "COPYING", prefix / "licenses/Yosys")
    shutil.copyfile(abc / "copyright.txt", prefix / "licenses/ABC")
    shutil.copyfile(yosys / "libs/cxxopts/LICENSE", prefix / "licenses/cxxopts")
    (deps / "synthesis-versions.json").write_text(json.dumps(lock, indent=2) + "\n")
    print("Native synthesis dependencies ready under " + str(deps))


if __name__ == "__main__":
    main()
