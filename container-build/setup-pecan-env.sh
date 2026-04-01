#!/usr/bin/env bash
set -euo pipefail

# ---- CONFIG ----
S3_ENDPOINT="https://s3.garage.ccmmf.ncsa.cloud"
S3_BUCKET="s3://carb/environments"
DEFAULT_ENV="${HOME}/.conda/envs/pecan-all"

# ---- HELPERS ----
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---- ARGS ----
usage() {
  echo "Usage: $0 <VERSION> [ENV_PATH]"
  echo ""
  echo "  VERSION   Required. PEcAn environment version to install (e.g. 1.10)."
  echo "            Resolves to: ${S3_BUCKET}/pecan-all-<VERSION>.tar.gz"
  echo "  ENV_PATH  Optional. Directory to install the environment."
  echo "            Default: ~/.conda/envs/pecan-all"
  echo ""
  echo "Requirements: aws CLI configured with appropriate credentials, conda on PATH."
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
command -v aws >/dev/null 2>&1 || die "aws CLI not found. Install or load it before running this script."
if ! command -v conda >/dev/null 2>&1; then
    log "conda not found. Attempting to load the conda module..."
    module load conda 2>/dev/null || true
    command -v conda >/dev/null 2>&1 || die "conda not found. Install Miniconda or load the conda module before running this script."
fi

if [[ -e "${PECAN_ENV}" ]]; then
  die "Target path already exists: ${PECAN_ENV}. Remove it or choose a different path."
fi

# ---- MAIN ----
log "PEcAn version: ${PECAN_VERSION}"
log "Target environment path: ${PECAN_ENV}"
log "S3 tarball: ${S3_TARBALL}"

# 1. Download
log "Downloading PEcAn environment tarball from S3..."
aws s3 cp --endpoint-url "${S3_ENDPOINT}" "${S3_TARBALL}" "${TARBALL}"

# 2. Unpack
log "Decompressing tarball..."
mkdir -p "${PECAN_ENV}"
tar -xzf "${TARBALL}" -C "${PECAN_ENV}"

# 3. Fix embedded paths
log "Fixing embedded paths (conda-unpack)..."
eval "$(conda shell.bash hook)"
set +u
conda activate "${PECAN_ENV}"
set -u
conda-unpack

# 4. Restore R packages
log "Restoring R packages — this takes 20-40 minutes..."
R_LIBS="${PECAN_ENV}/lib/R/library" \
R_LIBS_USER="" \
R_LIBS_SITE="" \
RENV_PATHS_CACHE="${PECAN_ENV}/renv-source-cache" \
RENV_PATHS_SOURCE="${PECAN_ENV}/renv-source-cache/sources" \
RENV_PATHS_LIBRARY="${PECAN_ENV}/lib/R/library" \
  "${PECAN_ENV}/bin/Rscript" -e "
    renv::restore(lockfile = '${PECAN_ENV}/renv.lock', prompt = FALSE)
  "

# 5. Verify
log "Verifying..."
R_LIBS="${PECAN_ENV}/lib/R/library" \
R_LIBS_USER="" \
R_LIBS_SITE="" \
  "${PECAN_ENV}/bin/Rscript" -e "
    library('PEcAn.all')
    library('PEcAn.RothC')
    library('PEcAn.SIPNET')
    library('tidyverse')
    library('here')
    library('arrow')
    library('duckdb')
  " || die "Verification failed. Check the renv::restore() output above for errors."

log "Setup complete."
echo ""
echo "Activate the environment with:"
echo "  conda activate ${PECAN_ENV}"
