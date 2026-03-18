# Critique: container-conda-unwrap

## Summary Verdict

With the constraint clarified — workload schedulers (e.g., SLURM) on many HPCs don't accept job submissions from within containerized environments, so a native conda environment is required — the core design is well-motivated and the approach is legitimate. The remaining concerns are implementation-level rather than architectural.

The intended workflow (build locally in container → pack → ship to HPC → unpack as native conda env) is a reasonable solution to a real problem. Shipping a `.sif` file would not help if the HPC's scheduler can't run jobs from inside it.

---

## Remaining Issues

### 1. The install file uses HPC paths, not local build paths

`pecan_install_all_03182026.txt` hardcodes HPC-specific paths:

```
CONDA_ENV_NAME="/project/60007/hpriest/environments/pecan-all-03172026"
PACK_LOCATION="${HOME}/hpriest/packed-environments/pecan-all-03172026.tar.gz"
```

If the container runs locally on a build machine with bind-mounted local directories, these paths won't exist. The bind-mount paths (e.g., `/mnt/envs/`) described in DESIGN.md don't match what the install file actually uses. Either:

- The install file needs to use the container-internal mount paths, or
- There need to be two separate install files (one for local/container builds, one for direct HPC builds), or
- This particular file is meant to be run directly on the HPC without the container

This is an inconsistency worth resolving explicitly in the design, since it determines whether the tool actually achieves local reproducible builds.

### 2. conda-pack + R packages is known-problematic

conda-pack rewrites prefix strings and RPATH entries, but R has additional complexities:

- Compiled R packages (`.so` files) may hardcode install-time paths via `RUNPATH` in ways conda-pack doesn't fully handle
- The `--ignore-missing-files` flag in the pack command suppresses errors that may indicate broken linking — worth understanding *why* files are missing before normalizing that flag
- R's lazy-loading bytecode cache (`.rdb`/`.rdx`) files embed absolute paths
- The manual `R_LIBS='' R_HOME='' R_LIBS_SITE='' ...` environment clearing when calling `Rscript` works around a real tension between conda's R setup and R's own package management — but it may cause issues post-relocation if the cleared variables affect how R discovers libraries at runtime

Plan for a debugging round after first unpack on target system, especially for `terra`, `sf`, and anything that directly links GDAL.

### 3. The core container artifact doesn't exist yet

The Apptainer `.def` file is described in DESIGN.md but not created. The project is currently a design doc, a generic script runner, and an install command list. The novel part — the container definition — is absent. Until the `.def` file exists and produces a working container, the build-locally story is theoretical.

### 4. `eval` in `run_install_file.sh` is fragile

The command loop uses `eval "$LINE"` to execute each line. This breaks silently on lines with unquoted special characters, command substitutions in unexpected contexts, or multi-line constructs. Consider just sourcing the file with `set -e` and `set -o pipefail` instead.

### 5. File-date versioning is a maintenance trap

`pecan_install_all_03182026.txt` embeds a date in the filename. This pattern accumulates dated copies and creates ambiguity about which is current. Git handles this better.

---

## What's Well-Motivated

- The bind-mount strategy (build to host disk, not container RAM) is the right call for environments this large
- Using the container as a build tool rather than a deliverable keeps the workflow clean
- conda-pack is the correct mechanism for relocatable environments when the target can't run containers
- OS version pinning (Ubuntu 24.04 to match target) is necessary given compiled library dependencies (GDAL, libpq, netcdf)

---

## Remaining Alternative Worth Considering

**`conda-lock`** is complementary, not a replacement: it would lock the exact package versions used in the build, so the environment can be rebuilt reproducibly later even if conda-pack tarballs are large to store long-term. Using both together is reasonable — conda-lock for reproducibility, conda-pack for deployment.
