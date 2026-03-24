# Arrow R Package Install — Blocked, Picking Up 2026-03-24

## Problem
Installing the `arrow` R package (v23.0.1.1) from source fails on the login node. Two sequential errors encountered:

### Error 1 — make jobserver (RESOLVED)
```
make[1]: *** internal error: invalid --jobserver-auth string 'fifo:/tmp/GMfifo...'
```
Fixed by wrapping the install in a subshell with `unset MAKELEVEL MFLAGS; export MAKEFLAGS='-j1'`.

### Error 2 — OOM kill (CURRENT BLOCKER)
```
x86_64-conda-linux-gnu-c++: fatal error: Killed signal terminated program cc1plus
compilation terminated.
```
The C++ compiler is being killed by the OOM killer during the `arrow_json` module build. Login node memory is too limited for arrow C++ compilation (~4 GB needed per translation unit at -O2).

## Attempted mitigations
- `-j1` (single-threaded): reduces concurrency, does not reduce per-process memory
- `ARROW_CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS='-O1'"`: lowers per-TU memory, still OOM killed

## Current state of `pecan_install_errored_pkgs.txt` (line 55)
```bash
(unset MAKELEVEL MFLAGS; export MAKEFLAGS='-j1'; NOT_CRAN=true LIBARROW_BINARY=false \
  ARROW_CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS='-O1'" \
  R_LIBS='' R_HOME='' R_LIBS_USER='' R_LIBS_SITE='' \
  Rscript -e "install.packages('arrow', lib = '${TEMP_R_LIB}', repos = ${R_REPOS})")
```

## Options to try next

### Option A — Submit as a compute job
Run the arrow install on a node with 16+ GB RAM. This is the cleanest fix. Wrap Phase 2 (or just the arrow line) in an `salloc`/`sbatch` with `--mem=16G`.

### Option B — Disable arrow JSON module
`-DARROW_JSON=OFF` cuts out the heaviest compilation unit. Risk: may break arrow R functionality if JSON parsing is used. Worth testing.
```bash
ARROW_CMAKE_ARGS="-DARROW_JSON=OFF -DCMAKE_CXX_FLAGS='-O1'"
```

### Option C — Use `-O0` (no optimization)
Maximum memory reduction at compile time, slowest runtime. Try if `-O1` still OOMs.
```bash
ARROW_CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS='-O0 -g0'"
```

## Why conda r-arrow won't work
conda-forge `r-arrow` was only built for R 3.6.x — there is no R 4.3 build. Adding `r-arrow` to the conda create step fails with an unsatisfiable solver conflict because `r-s2 1.1.4` pins `r-base >=4.3`.

## Once arrow is built
Uncomment line 58 (`renv::snapshot(...)`) to snapshot arrow into the renv.lock, then verify the restore step works on the destination with the same `MAKEFLAGS`/`LIBARROW_BINARY` env vars to avoid glibc binary download issues.
