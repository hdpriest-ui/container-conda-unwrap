#!/usr/bin/env bash
set -euo pipefail

# ---- CONFIG ----
S3_PROFILE="${AWS_PROFILE:-magic}"
S3_BUCKET="s3://carb/environments"
DEFAULT_ENV="${HOME}/.conda/envs/pecan-all"
INSTALL_JOBS="${INSTALL_JOBS:-${SLURM_CPUS_PER_TASK:-2}}"

# ---- HELPERS ----
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

aws_version_ok() {
  command -v aws >/dev/null 2>&1 || return 1
  local ver major minor
  ver=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
  major=$(echo "${ver}" | cut -d. -f1)
  minor=$(echo "${ver}" | cut -d. -f2)
  [[ "${major}" -ge 2 ]] && return 0
  [[ "${major}" -eq 1 && "${minor}" -ge 29 ]] && return 0
  return 1
}

validate() {
  log "Verifying..."
  R_LIBS="${PECAN_ENV}/lib/R/library" \
  R_LIBS_USER="" \
  R_LIBS_SITE="" \
    "${PECAN_ENV}/bin/Rscript" -e "
      library('PEcAn.all')
      library('PEcAn.RothC')
      library('PEcAn.SIPNET')
      library('PEPRMT')
      library('tidyverse')
      library('here')
      library('arrow')
      library('duckdb')
    " || die "Validation failed. Environment at ${PECAN_ENV} may be incomplete."
  log "Validation complete."
}

# ---- ARGS ----
usage() {
  echo "Usage: $0 <VERSION> [ENV_PATH]"
  echo ""
  echo "  VERSION   Required. PEcAn environment version to install (e.g. 1.10)."
  echo "            Resolves to: ${S3_BUCKET}/pecan-all-<VERSION>.tar.gz"
  echo "  ENV_PATH  Optional. Directory to install the environment."
  echo "            Default: ~/.conda/envs/pecan-all"
  echo ""
  echo "Requirements: aws CLI with a configured profile (default: 'magic'), conda on PATH."
  echo "  Override profile: AWS_PROFILE=myprofile $0 <VERSION>"
  echo ""
  echo "  Override parallel R package install jobs (default: \$SLURM_CPUS_PER_TASK, else 2):"
  echo "    INSTALL_JOBS=4 $0 <VERSION>"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ -z "${1:-}" ]] && { usage; die "VERSION is required."; }
PECAN_VERSION="${1}"
PECAN_ENV="${2:-${DEFAULT_ENV}}"
S3_TARBALL="${S3_BUCKET}/pecan-all-${PECAN_VERSION}.tar.gz"

# Download to a temp file; clean up on exit regardless of success or failure.
TARBALL="$(mktemp).tar.gz"
cleanup() { rm -f "${TARBALL}"; }
trap cleanup EXIT

# ---- PREFLIGHT ----
if ! aws_version_ok; then
  log "aws CLI not found or version too old. Attempting to load the aws module..."
  module load aws 2>/dev/null || true
  aws_version_ok || die "aws CLI >= 1.29 (or v2) is required. Install a compatible version or load the aws module before running this script."
fi

if ! grep -qs "\[${S3_PROFILE}\]" "${HOME}/.aws/credentials" 2>/dev/null; then
  die "
       AWS profile '${S3_PROFILE}' not found in ~/.aws/credentials.

       Add a [${S3_PROFILE}] section with aws_access_key_id and aws_secret_access_key.

       Optionally, to use a different profile, set AWS_PROFILE before running:
         AWS_PROFILE=myprofile $0 ${PECAN_VERSION:-<VERSION>}"
fi
if ! grep -qs "\[profile ${S3_PROFILE}\]" "${HOME}/.aws/config" 2>/dev/null; then
  die "
       AWS profile '${S3_PROFILE}' not found in ~/.aws/config.

       Add a [profile ${S3_PROFILE}] section with region and endpoint_url.

       Optionally, to use a different profile, set AWS_PROFILE before running:
         AWS_PROFILE=myprofile $0 ${PECAN_VERSION:-<VERSION>}"
fi
if ! command -v conda >/dev/null 2>&1; then
    log "conda not found. Attempting to load the conda module..."
    module load conda 2>/dev/null || true
    command -v conda >/dev/null 2>&1 || die "conda not found. Install Miniconda or load the conda module before running this script."
fi

if [[ -e "${PECAN_ENV}" ]]; then
  log "Target path already exists: ${PECAN_ENV}. Skipping install — restoring and validating."
  set +u
  eval "$(conda shell.bash hook)"
  conda activate "${PECAN_ENV}"
  set -u
  # Root cause (confirmed against renv's own source, R/graph.R): restore()'s classic
  # installer batches every package it's asked to touch into one renv_graph_install()
  # call, which creates a single shared staging directory for that whole batch. GitHub
  # subdir packages (RemoteSubdir set — modules/data.remote, models/sipnet,
  # modules/assim.sequential) are unpacked into staging/<package> as part of that batch;
  # if the same package is reachable from more than one thing in the same batch (e.g.
  # PEcAn.workflow's Imports and PEcAn.all's Depends both reaching PEcAn.data.remote),
  # it gets queued for that unpack-and-move twice, and the second move fails because
  # the first one's directory is still there ("target file ... already exists").
  # This isn't limited to two packages, and excluding-by-computed-closure kept missing
  # dependents (PEcAn.all first, something else after). Since the bug is fundamentally
  # about batching, the fix is to never batch our own PEcAn.* packages together at all:
  # exclude every one of them from the bulk restore below (a fixed, known list — no
  # dependency graph to get wrong), then install each one individually, one call at a
  # time, in the same order the build itself used. A single-target install() only ever
  # has to resolve for that one package, so there is no second reference to collide
  # with. GitHub-sourced records are pinned to the RemoteSha already recorded in the
  # lockfile (not a floating branch) so they reuse the source tarball already cached at
  # build time under RENV_PATHS_SOURCE instead of hitting the network. This also avoids
  # arrow drifting to a newer version pak would otherwise resolve freely for an
  # unconstrained dependency: everything non-PEcAn (including arrow) is restored,
  # lockfile-pinned, by the bulk call below before any of these packages get installed.
  OURS="PEcAn.logger,PEcAn.utils,PEcAn.settings,PEcAn.DB,PEcAn.remote,PEcAn.priors,PEcAn.MA,PEcAn.emulator,PEcAn.uncertainty,PEcAn.data.remote,PEcAn.data.atmosphere,PEcAn.data.land,PEcAn.benchmark,PEcAn.workflow,PEcAn.assim.batch,PEcAn.all,PEcAn.RothC,PEPRMT,PEcAn.SIPNET,nneo,amerifluxr,PEcAnAssimSequential"
  R_LIBS="${PECAN_ENV}/lib/R/library" \
  R_LIBS_USER="" \
  R_LIBS_SITE="" \
  RENV_PATHS_CACHE="${PECAN_ENV}/renv-source-cache" \
  RENV_PATHS_SOURCE="${PECAN_ENV}/renv-source-cache/sources" \
  RENV_PATHS_LIBRARY="${PECAN_ENV}/lib/R/library" \
  ARROW_HOME="${PECAN_ENV}" \
  PKG_CONFIG_PATH="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
  PKG_CONFIG_LIBDIR="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
  OPENBLAS_NUM_THREADS=1 \
  OMP_NUM_THREADS=1 \
  LIBRARY_PATH="${PECAN_ENV}/lib" \
  LD_LIBRARY_PATH="${PECAN_ENV}/lib" \
  OURS="${OURS}" \
    "${PECAN_ENV}/bin/Rscript" -e "
      options(renv.install.timeout = 21600, renv.config.install.jobs = ${INSTALL_JOBS})
      ours <- strsplit(Sys.getenv('OURS'), ',')[[1]]
      renv::restore(lockfile = '${PECAN_ENV}/renv.lock', exclude = ours, prompt = FALSE)
    "
  R_LIBS="${PECAN_ENV}/lib/R/library" \
  R_LIBS_USER="" \
  R_LIBS_SITE="" \
  RENV_PATHS_CACHE="${PECAN_ENV}/renv-source-cache" \
  RENV_PATHS_SOURCE="${PECAN_ENV}/renv-source-cache/sources" \
  RENV_PATHS_LIBRARY="${PECAN_ENV}/lib/R/library" \
  ARROW_HOME="${PECAN_ENV}" \
  PKG_CONFIG_PATH="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
  PKG_CONFIG_LIBDIR="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
  OPENBLAS_NUM_THREADS=1 \
  OMP_NUM_THREADS=1 \
  LIBRARY_PATH="${PECAN_ENV}/lib" \
  LD_LIBRARY_PATH="${PECAN_ENV}/lib" \
  OURS="${OURS}" \
    "${PECAN_ENV}/bin/Rscript" -e "
      options(renv.install.timeout = 21600, renv.config.install.jobs = ${INSTALL_JOBS}, repos = c(CRAN = 'https://cloud.r-project.org', pecan = 'https://pecanproject.r-universe.dev'), timeout = 600)
      lockfile <- renv:::renv_lockfile_read('${PECAN_ENV}/renv.lock')
      ours <- strsplit(Sys.getenv('OURS'), ',')[[1]]
      for (pkg in ours) {
        rec <- lockfile\$Packages[[pkg]]
        if (is.null(rec)) next
        spec <- if (identical(rec\$Source, 'GitHub')) {
          base <- paste0(rec\$RemoteUsername, '/', rec\$RemoteRepo)
          subdir <- rec\$RemoteSubdir
          if (!is.null(subdir) && nzchar(subdir)) base <- paste0(base, '/', subdir)
          paste0('github::', base, '@', rec\$RemoteSha)
        } else {
          pkg
        }
        renv::install(spec)
      }
    "
  R_LIBS="${PECAN_ENV}/lib/R/library" \
  R_LIBS_USER="" \
  R_LIBS_SITE="" \
  RENV_PATHS_CACHE="${PECAN_ENV}/renv-source-cache" \
  RENV_PATHS_SOURCE="${PECAN_ENV}/renv-source-cache/sources" \
  RENV_PATHS_LIBRARY="${PECAN_ENV}/lib/R/library" \
  ARROW_HOME="${PECAN_ENV}" \
  PKG_CONFIG_PATH="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
  PKG_CONFIG_LIBDIR="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
  OPENBLAS_NUM_THREADS=1 \
  OMP_NUM_THREADS=1 \
  LIBRARY_PATH="${PECAN_ENV}/lib" \
  LD_LIBRARY_PATH="${PECAN_ENV}/lib" \
    "${PECAN_ENV}/bin/Rscript" -e "
      options(renv.install.timeout = 21600, renv.config.install.jobs = ${INSTALL_JOBS})
      renv::restore(lockfile = '${PECAN_ENV}/renv.lock', prompt = FALSE)
    "
  validate
  echo ""
  echo "Activate the environment with:"
  echo "  conda activate ${PECAN_ENV}"
  exit 0
fi

# ---- MAIN ----
log "PEcAn version: ${PECAN_VERSION}"
log "Target environment path: ${PECAN_ENV}"
log "S3 tarball: ${S3_TARBALL}"

# 1. Download
log "Downloading PEcAn environment tarball from S3..."
aws s3 cp --profile "${S3_PROFILE}" "${S3_TARBALL}" "${TARBALL}"

# 2. Unpack
log "Decompressing tarball..."
mkdir -p "${PECAN_ENV}"
tar -xzf "${TARBALL}" -C "${PECAN_ENV}"

# 3. Fix embedded paths
log "Fixing embedded paths (conda-unpack)..."
set +u
eval "$(conda shell.bash hook)"
conda activate "${PECAN_ENV}"
set -u
conda-unpack

# 4. Restore R packages
log "Restoring R packages — this takes 20-40 minutes..."
# Root cause (confirmed against renv's own source, R/graph.R): restore()'s classic
# installer batches every package it's asked to touch into one renv_graph_install()
# call, which creates a single shared staging directory for that whole batch. GitHub
# subdir packages (RemoteSubdir set — modules/data.remote, models/sipnet,
# modules/assim.sequential) are unpacked into staging/<package> as part of that batch;
# if the same package is reachable from more than one thing in the same batch (e.g.
# PEcAn.workflow's Imports and PEcAn.all's Depends both reaching PEcAn.data.remote),
# it gets queued for that unpack-and-move twice, and the second move fails because
# the first one's directory is still there ("target file ... already exists").
# This isn't limited to two packages, and excluding-by-computed-closure kept missing
# dependents (PEcAn.all first, something else after). Since the bug is fundamentally
# about batching, the fix is to never batch our own PEcAn.* packages together at all:
# exclude every one of them from the bulk restore below (a fixed, known list — no
# dependency graph to get wrong), then install each one individually, one call at a
# time, in the same order the build itself used. A single-target install() only ever
# has to resolve for that one package, so there is no second reference to collide
# with. GitHub-sourced records are pinned to the RemoteSha already recorded in the
# lockfile (not a floating branch) so they reuse the source tarball already cached at
# build time under RENV_PATHS_SOURCE instead of hitting the network. This also avoids
# arrow drifting to a newer version pak would otherwise resolve freely for an
# unconstrained dependency: everything non-PEcAn (including arrow) is restored,
# lockfile-pinned, by the bulk call below before any of these packages get installed.
OURS="PEcAn.logger,PEcAn.utils,PEcAn.settings,PEcAn.DB,PEcAn.remote,PEcAn.priors,PEcAn.MA,PEcAn.emulator,PEcAn.uncertainty,PEcAn.data.remote,PEcAn.data.atmosphere,PEcAn.data.land,PEcAn.benchmark,PEcAn.workflow,PEcAn.assim.batch,PEcAn.all,PEcAn.RothC,PEPRMT,PEcAn.SIPNET,nneo,amerifluxr,PEcAnAssimSequential"
R_LIBS="${PECAN_ENV}/lib/R/library" \
R_LIBS_USER="" \
R_LIBS_SITE="" \
RENV_PATHS_CACHE="${PECAN_ENV}/renv-source-cache" \
RENV_PATHS_SOURCE="${PECAN_ENV}/renv-source-cache/sources" \
RENV_PATHS_LIBRARY="${PECAN_ENV}/lib/R/library" \
ARROW_HOME="${PECAN_ENV}" \
PKG_CONFIG_PATH="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
PKG_CONFIG_LIBDIR="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
OPENBLAS_NUM_THREADS=1 \
OMP_NUM_THREADS=1 \
LIBRARY_PATH="${PECAN_ENV}/lib" \
LD_LIBRARY_PATH="${PECAN_ENV}/lib" \
OURS="${OURS}" \
  "${PECAN_ENV}/bin/Rscript" -e "
    options(renv.install.timeout = 21600, renv.config.install.jobs = ${INSTALL_JOBS})
    ours <- strsplit(Sys.getenv('OURS'), ',')[[1]]
    renv::restore(lockfile = '${PECAN_ENV}/renv.lock', exclude = ours, prompt = FALSE)
  "
R_LIBS="${PECAN_ENV}/lib/R/library" \
R_LIBS_USER="" \
R_LIBS_SITE="" \
RENV_PATHS_CACHE="${PECAN_ENV}/renv-source-cache" \
RENV_PATHS_SOURCE="${PECAN_ENV}/renv-source-cache/sources" \
RENV_PATHS_LIBRARY="${PECAN_ENV}/lib/R/library" \
ARROW_HOME="${PECAN_ENV}" \
PKG_CONFIG_PATH="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
PKG_CONFIG_LIBDIR="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
OPENBLAS_NUM_THREADS=1 \
OMP_NUM_THREADS=1 \
LIBRARY_PATH="${PECAN_ENV}/lib" \
LD_LIBRARY_PATH="${PECAN_ENV}/lib" \
OURS="${OURS}" \
  "${PECAN_ENV}/bin/Rscript" -e "
    options(renv.install.timeout = 21600, renv.config.install.jobs = ${INSTALL_JOBS}, repos = c(CRAN = 'https://cloud.r-project.org', pecan = 'https://pecanproject.r-universe.dev'), timeout = 600)
    lockfile <- renv:::renv_lockfile_read('${PECAN_ENV}/renv.lock')
    ours <- strsplit(Sys.getenv('OURS'), ',')[[1]]
    for (pkg in ours) {
      rec <- lockfile\$Packages[[pkg]]
      if (is.null(rec)) next
      spec <- if (identical(rec\$Source, 'GitHub')) {
        base <- paste0(rec\$RemoteUsername, '/', rec\$RemoteRepo)
        subdir <- rec\$RemoteSubdir
        if (!is.null(subdir) && nzchar(subdir)) base <- paste0(base, '/', subdir)
        paste0('github::', base, '@', rec\$RemoteSha)
      } else {
        pkg
      }
      renv::install(spec)
    }
  "
R_LIBS="${PECAN_ENV}/lib/R/library" \
R_LIBS_USER="" \
R_LIBS_SITE="" \
RENV_PATHS_CACHE="${PECAN_ENV}/renv-source-cache" \
RENV_PATHS_SOURCE="${PECAN_ENV}/renv-source-cache/sources" \
RENV_PATHS_LIBRARY="${PECAN_ENV}/lib/R/library" \
ARROW_HOME="${PECAN_ENV}" \
PKG_CONFIG_PATH="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
PKG_CONFIG_LIBDIR="${PECAN_ENV}/lib/pkgconfig:${PECAN_ENV}/share/pkgconfig" \
OPENBLAS_NUM_THREADS=1 \
OMP_NUM_THREADS=1 \
LIBRARY_PATH="${PECAN_ENV}/lib" \
LD_LIBRARY_PATH="${PECAN_ENV}/lib" \
  "${PECAN_ENV}/bin/Rscript" -e "
    options(renv.install.timeout = 21600, renv.config.install.jobs = ${INSTALL_JOBS})
    renv::restore(lockfile = '${PECAN_ENV}/renv.lock', prompt = FALSE)
  "

# 5. Verify
validate

log "Setup complete."
echo ""
echo "Activate the environment with:"
echo "  conda activate ${PECAN_ENV}"
