# Third-party dependencies

Pinned external dependencies and license metadata belong in this directory. Large downloaded dependencies belong in `.deps/` and are ignored by Git.

`synthesis-lock.json` pins the framework Dockerfile's Yosys, ABC, cxxopts,
ASAP7 RVT TT NLDM, OpenSTA, and CUDD revisions, archive SHA-256 values, and extracted Liberty
SHA-256 values. `make synth-setup` verifies these inputs and installs native
dependencies under `.deps/`; it does not modify the official framework.

OpenSTA and CUDD licenses are retained in `.deps/opensta/licenses/`;
Yosys, ABC and cxxopts licenses are in `.deps/yosys/licenses/`;
the ASAP7 license is retained in `.deps/asap7/licenses/`. The OpenSTA archive
build changes only CMake's revision metadata to report the pinned upstream
commit instead of inheriting the enclosing CPU repository's Git revision.

The synthesis runner defaults to the native, pinned Yosys 0.63 and ABC under
`.deps/yosys/bin/`. Yosys is built without Tcl and readline, which the Python
synthesis flow does not use. Explicit `YOSYS` and `ABC` overrides are supported;
reports retain the actual tool versions and input hashes.
