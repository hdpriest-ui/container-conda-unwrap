# Design: Apptainer-Based Conda Environment Build

## Overview

This project uses an Apptainer container built on Ubuntu 24.04 to construct a portable
conda environment. The container provides a controlled OS baseline that matches the target
deployment system, ensuring dependency compatibility. The built environment is then packaged
with `conda-pack`, moved out of the container, and unpacked at the final destination.

---

## 1. Container Definition File (`pecan-build.def`)

The Apptainer definition file (`.def`) will produce a container with:

- **Base**: `ubuntu:24.04` (pulled from Docker Hub via `Bootstrap: docker`)
- **System packages**: build tools and libraries needed by conda/R/GDAL at compile time
- **Miniforge**: installed to `/opt/miniforge` — provides `conda` and `mamba`
- No conda environment is built during `%post`; the container is purely a build environment

### Proposed `.def` structure

```
Bootstrap: docker
From: ubuntu:24.04

%post
    apt-get update && apt-get install -y \
        curl wget git build-essential ca-certificates \
        libssl-dev libcurl4-openssl-dev libxml2-dev \
        libgdal-dev libgeos-dev libproj-dev \
        libpq-dev libnetcdf-dev \
        && rm -rf /var/lib/apt/lists/*

    curl -L \
        https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
        -o /tmp/miniforge.sh
    bash /tmp/miniforge.sh -b -p /opt/miniforge
    rm /tmp/miniforge.sh
    /opt/miniforge/bin/conda init bash

%environment
    export PATH="/opt/miniforge/bin:$PATH"
    export CONDA_PREFIX="/opt/miniforge"

%runscript
    exec /bin/bash "$@"

%labels
    Description Ubuntu 24.04 build environment for PEcAn conda pack
    Version 1.0
```

### Building the container image

Building a `.sif` from a `.def` file requires either root or fakeroot:

```bash
# With root
sudo apptainer build pecan-build.sif pecan-build.def

# Without root (HPC-friendly)
apptainer build --fakeroot pecan-build.sif pecan-build.def
```

---

## 2. Bind-Mount Strategy

Rather than building the conda environment inside the container's read-only filesystem
(which would require `--writable-tmpfs` with RAM-backed storage — impractical for large
environments), the environment is built on **bind-mounted host directories**.

Two host directories are bind-mounted into the container at runtime:

| Host path                          | Container path  | Purpose                         |
|------------------------------------|-----------------|----------------------------------|
| `/path/on/host/envs/`              | `/mnt/envs/`    | Conda environment build location |
| `/path/on/host/packed/`            | `/mnt/packed/`  | Destination for packed tarball   |

Both directories must exist on the host before running the container.

---

## 3. Install File for Container Use (`pecan_install_container.txt`)

This is a container-adapted version of `pecan_install_all_03182026.txt`. The only
differences are the path variables at the top and one corrected symlink line.

### Path changes

| Variable         | Original (HPC)                                                    | Container version                          |
|------------------|-------------------------------------------------------------------|--------------------------------------------|
| `CONDA_ENV_NAME` | `/project/60007/hpriest/environments/pecan-all-03172026`         | `/mnt/envs/pecan-all-03172026`             |
| `LIB_LOCATION`   | `/project/60007/hpriest/environments/pecan-all-03172026/lib/R/library` | `/mnt/envs/pecan-all-03172026/lib/R/library` |
| `PACK_LOCATION`  | `${HOME}/hpriest/packed-environments/pecan-all-03172026.tar.gz`  | `/mnt/packed/pecan-all-03172026.tar.gz`    |

### Bug fix: quarto symlink (line 29 in original)

The original line:
```bash
ln -s ~/lib/quarto-1.9.35/bin/quarto "${CONDA_ENV_NAME}"/bin/quarto
```

`~/lib/` is incorrect — quarto was extracted to `"${CONDA_ENV_NAME}"/lib/`. The corrected line:
```bash
ln -s "${CONDA_ENV_NAME}/lib/quarto-1.9.35/bin/quarto" "${CONDA_ENV_NAME}/bin/quarto"
```

This fix applies equally to both the original file and the container version.

---

## 4. Pack / Move / Unpack Workflow

### Step 1 — Build and Pack (inside container)

The install file already ends with a `conda pack` invocation. Running the full install
through the container produces the packed tarball at the bind-mounted output path.

```bash
# Create host directories
mkdir -p /path/on/host/envs /path/on/host/packed

# Run the install file inside the container
apptainer exec \
    --bind /path/on/host/envs:/mnt/envs \
    --bind /path/on/host/packed:/mnt/packed \
    pecan-build.sif \
    bash run_install_file.sh pecan_install_container.txt
```

When this completes, the packed tarball exists on the host at:
`/path/on/host/packed/pecan-all-03172026.tar.gz`

### Step 2 — Move

The tarball is a self-contained, relocatable archive. Transfer it to the target system
using whatever mechanism is available (scp, rsync, shared filesystem, Globus, etc.):

```bash
rsync -avP \
    /path/on/host/packed/pecan-all-03172026.tar.gz \
    user@target-host:/scratch/transfer/
```

### Step 3 — Unpack at Target

`conda-pack` archives embed a post-unpack activation script (`conda-unpack`) that rewrites
hardcoded prefix paths to the new installation location.

```bash
TARGET_ENV="/project/60007/hpriest/environments/pecan-all-03172026"

mkdir -p "${TARGET_ENV}"
tar -xzf pecan-all-03172026.tar.gz -C "${TARGET_ENV}"

# Rewrite embedded paths to the new prefix
source "${TARGET_ENV}/bin/activate"
conda-unpack
```

After `conda-unpack` completes, the environment is fully functional at the target path
without requiring conda to be installed on the target system.

### Step 4 — Verify

```bash
source "${TARGET_ENV}/bin/activate"
Rscript -e 'library(PEcAn.all)'
```

---

## 5. File Inventory (proposed)

```
container-conda-unwrap/
├── DESIGN.md                          # This document
├── pecan-build.def                    # Apptainer definition file
├── pecan_install_all_03182026.txt     # Original install script (HPC paths)
├── pecan_install_container.txt        # Container-adapted install script
└── run_install_file.sh                # Execution harness (unchanged)
```

---

## 6. Key Design Decisions

**Why bind-mount the env directory rather than build inside the container?**
Conda environments for this workload exceed what `--writable-tmpfs` (RAM-backed) can hold.
Building on a bind-mounted host path keeps the environment on disk, makes intermediate
state inspectable, and avoids needing a writable SIF or sandbox.

**Why Ubuntu 24.04?**
The target deployment environment is Ubuntu 24.x. Using the same OS in the container
ensures that compiled libraries (GDAL, libpq, netcdf) are compatible with the system
libraries present at the deployment site.

**Why not bake the conda env into the container image?**
The packed tarball is the deliverable, not the container. Baking the env into the image
would double the storage requirement and make the image non-portable to non-Apptainer
systems. The container is purely a reproducible build tool.

**Why `conda-pack`?**
`conda-pack` produces a tarball that is fully relocatable — it rewrites `RPATH` and
prefix strings so the environment works at any installation path. This is essential when
the build path (`/mnt/envs/...`) differs from the deployment path (`/project/60007/...`).
