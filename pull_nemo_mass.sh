#!/bin/bash
# =============================================================================
# Pull UKESM1.1 NEMO monthly output from MASS — ONE suite, ONE stream.
#
# Driven by pull_nemo.sbatch (one array task per line of tasks.txt), but also
# runs standalone on a node with MASS (moo) access.
#
#   bash pull_nemo_mass.sh --suite u-dp583 --stream grid-T --dry-run
#   bash pull_nemo_mass.sh --suite u-dp583 --stream grid-T --year-start 2034 --year-end 2084
#
# Each monthly file is fetched from moose:/crum/<suite>/onm.nc.file, cut down
# to the variables below with ncks, and written to
#   ${DATA_ROOT}/UKESM1.1/<suite>/nemo_<id>o_1m_<YYYYMMDD-YYYYMMDD>_<suffix>.nc
# The raw file is deleted straight away, so peak disk stays at a few GB.
#
# Retrieval is batched one `moo get` per year (MASS prefers fewer, larger
# requests). Resumable: months already on disk are skipped. Months never
# archived on MASS are reported and skipped rather than failing the batch.
#
# Per-month sizes on MASS: grid-T 277 MB, grid-V 116 MB, diaptr 12 MB.
# MASS cannot subset whole-file gets, so grid-T moves ~14 GB/year/suite even
# though ~0.3 GB is kept. Filtered streams (mld, tau-U, tau-V) are stripped
# server-side with `moo filter` and move ~1-2 MB per month.
#
# ALWAYS --dry-run first. `moo get` can hang silently when Fetch-on-Demand is
# disabled, so every get is wrapped in `timeout`.
# =============================================================================

set -uo pipefail

DATA_ROOT="${DATA_ROOT:-/data/users/${USER}/SPG_SAI}"
LOCAL_BASE="${DATA_ROOT}/UKESM1.1"
TMP_BASE="${DATA_ROOT}/tmp_nemo_mass"
LOG_BASE="${DATA_ROOT}/logs/pull_nemo"

SUITE=""
STREAM=""
DRY_RUN=0
START_YR=2034
END_YR=2084
GET_TIMEOUT=7200          # seconds per batch

usage() {
    cat <<EOF
usage: $0 --suite <u-XXXXX> --stream <grid-T|diaptr|vo|mld|tau-U|tau-V> [options]

options:
  --dry-run          check MASS holdings and report what would be pulled; retrieve nothing
  --year-start YYYY  default ${START_YR}
  --year-end   YYYY  default ${END_YR}
  --timeout    SECS  per-batch moo timeout, default ${GET_TIMEOUT}
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite)      SUITE="$2"; shift 2 ;;
        --stream)     STREAM="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --year-start) START_YR="$2"; shift 2 ;;
        --year-end)   END_YR="$2"; shift 2 ;;
        --timeout)    GET_TIMEOUT="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done

[[ -n "$SUITE"  ]] || usage
[[ -n "$STREAM" ]] || usage

# ---------------------------------------------------------------------------
# Streams: which NEMO file on MASS, which variables to keep, output suffix.
# To keep extra variables, add them to WANT_VARS. To add a stream, add a line.
# ---------------------------------------------------------------------------
USE_FILTER=0
MASS_STREAM="$STREAM"
case "$STREAM" in
    grid-T)  WANT_VARS="thetao,so,somxl010,mlotst,zos,sos" ; SUFFIX="grid-T_ext" ;;  # 3D T/S, MLD, SSH, SSS
    diaptr)  WANT_VARS="zomsfatl,sophtadv_atlantic"        ; SUFFIX="diaptr_ext" ;;  # native AMOC streamfunction + heat transport
    vo)      WANT_VARS="vo"       ; SUFFIX="grid-V_ext" ; MASS_STREAM="grid-V" ;;    # meridional velocity -> BSF
    mld)     WANT_VARS="somxl010" ; SUFFIX="mld_ext"    ; MASS_STREAM="grid-T" ; USE_FILTER=1 ;;  # MLD only
    tau-U)   WANT_VARS="tauuo"    ; SUFFIX="tauuo_ext"  ; MASS_STREAM="grid-U" ; USE_FILTER=1 ;;  # zonal wind stress
    tau-V)   WANT_VARS="tauvo"    ; SUFFIX="tauvo_ext"  ; MASS_STREAM="grid-V" ; USE_FILTER=1 ;;  # meridional wind stress
    *) echo "unknown stream: $STREAM"; usage ;;
esac

ABBREV="${SUITE#u-}"
LOCAL_DIR="${LOCAL_BASE}/${SUITE}"
TMP_DIR="${TMP_BASE}/${SUITE}_${STREAM}"
MASS_BASE="moose:/crum/${SUITE}/onm.nc.file"
LOG="${LOG_BASE}_${ABBREV}_${STREAM}.log"

mkdir -p "$LOCAL_DIR" "$TMP_DIR" "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "  suite   : ${SUITE} (${ABBREV})"
echo "  stream  : ${STREAM}  ->  *_${SUFFIX}.nc"
echo "  vars    : ${WANT_VARS}"
echo "  years   : ${START_YR}-${END_YR}"
echo "  dry-run : ${DRY_RUN}"
echo "  started : $(date)"
echo "============================================================"

# NEMO names a month by its start and the next start:
#   nemo_dp583o_1m_20340101-20340201_grid-T.nc
month_stamp() {   # $1=YYYY $2=MM  ->  "YYYYMMDD-YYYYMMDD"
    local start next
    start=$(printf "%04d%02d01" "$1" "$2")
    next=$(date -d "${1}-${2}-01 +1 month" +%Y%m%d)
    echo "${start}-${next}"
}

# ---------------------------------------------------------------------------
# Dry run: confirm MASS holds a full set, and report what is already local.
# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
    echo "querying MASS ..."
    listing=$(timeout 900 moo ls -l "${MASS_BASE}/" 2>&1 | grep -E "_${MASS_STREAM}\.nc *$")
    n_mass=$(echo "$listing" | grep -c . )
    # moo ls -l columns: F <owner> <bytes> <date> <time> <tz> <uri>
    bytes=$(echo "$listing" | awk '{s+=$3} END {print s+0}')
    n_local=$(find "$LOCAL_DIR" -name "*_${SUFFIX}.nc" -size +0 2>/dev/null | wc -l)
    expected=$(( (END_YR - START_YR + 1) * 12 ))

    echo "  on MASS      : ${n_mass} files  ($(numfmt --to=iec "${bytes:-0}")B, whole run)"
    echo "  expected     : ${expected} months"
    echo "  already local: ${n_local}  ->  ${SUFFIX}"
    echo "  to retrieve  : $(( expected - n_local )) months"
    if (( n_mass < expected )); then
        echo "  WARNING: MASS has fewer files than expected — check before running for real"
    fi
    echo "dry run complete: $(date)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Real retrieval. The collection is listed once up front so never-archived
# months are skipped instead of poisoning a whole batch.
# ---------------------------------------------------------------------------
echo "listing MASS holdings for _${MASS_STREAM}.nc ..."
MASS_LIST=$(timeout 900 moo ls "${MASS_BASE}/" 2>/dev/null | grep -E "_${MASS_STREAM}\.nc *$")
if [[ -z "$MASS_LIST" ]]; then
    echo "  WARNING: MASS listing empty/failed — proceeding without existence filter"
fi

retrieved=0; skipped=0; errors=0; not_archived=0

# Whole-file gets go one year at a time; filtered (2D) streams move so little
# that they ask for every year at once to avoid paying the tape wait per year.
BATCH_YEARS=1
(( USE_FILTER )) && BATCH_YEARS=$(( END_YR - START_YR + 1 ))

for (( yr = START_YR; yr <= END_YR; yr += BATCH_YEARS )); do
    yr_last=$(( yr + BATCH_YEARS - 1 )); (( yr_last > END_YR )) && yr_last=$END_YR
    declare -a need_stamps=() need_urls=()
    for (( by = yr; by <= yr_last; by++ )); do
    for mo in {1..12}; do
        stamp=$(month_stamp "$by" "$mo")
        ext="${LOCAL_DIR}/nemo_${ABBREV}o_1m_${stamp}_${SUFFIX}.nc"
        if [[ -s "$ext" ]]; then
            (( skipped++ )) || true
            continue
        fi
        fname="nemo_${ABBREV}o_1m_${stamp}_${MASS_STREAM}.nc"
        if [[ -n "$MASS_LIST" ]] && ! grep -qF "$fname" <<< "$MASS_LIST"; then
            echo "  not archived on MASS (skipping): ${fname}"
            (( not_archived++ )) || true
            continue
        fi
        need_stamps+=("$stamp")
        need_urls+=("${MASS_BASE}/${fname}")
    done
    done

    if (( ${#need_stamps[@]} == 0 )); then
        continue
    fi

    echo "[$(date +%H:%M:%S)] ${yr}-${yr_last}: retrieving ${#need_stamps[@]} month(s)"

    rm -f "${TMP_DIR}"/*.nc
    if (( USE_FILTER )); then
        ncksf="${TMP_DIR}/keep.ncks"
        printf -- "-v %s\n" "$WANT_VARS" > "$ncksf"
        if ! timeout "$GET_TIMEOUT" moo filter -z -i "$ncksf" "${need_urls[@]}" "${TMP_DIR}/" 2>&1; then
            echo "  WARNING: moo filter failed or timed out for ${yr} (keeping what arrived)"
        fi
    elif ! timeout "$GET_TIMEOUT" moo get "${need_urls[@]}" "${TMP_DIR}/" 2>&1; then
        echo "  WARNING: moo get failed or timed out for ${yr}"
    fi

    for stamp in "${need_stamps[@]}"; do
        raw="${TMP_DIR}/nemo_${ABBREV}o_1m_${stamp}_${MASS_STREAM}.nc"
        ext="${LOCAL_DIR}/nemo_${ABBREV}o_1m_${stamp}_${SUFFIX}.nc"

        if [[ ! -s "$raw" ]]; then
            echo "  MISSING after get: ${stamp}"
            (( errors++ )) || true
            continue
        fi

        # Filtered files arrive already reduced: check the variable and keep.
        # Not `grep -q`: under pipefail it SIGPIPEs ncdump and reads as failure.
        # A file that fails the check is quarantined, never deleted.
        if (( USE_FILTER )); then
            if ncdump -h "$raw" 2>/dev/null | grep -E "\b${WANT_VARS}\(" >/dev/null; then
                mv -f "$raw" "$ext"; (( retrieved++ )) || true
            else
                echo "  ERROR: ${WANT_VARS} absent from filtered ${stamp} (quarantined)"
                mkdir -p "${TMP_DIR}/quarantine"
                mv -f "$raw" "${TMP_DIR}/quarantine/"; (( errors++ )) || true
            fi
            continue
        fi

        # Only ask ncks for variables this file actually has, so one absent
        # diagnostic does not fail the whole extraction.
        have=$(ncdump -h "$raw" 2>/dev/null | awk '/^variables:/,/^data:/' \
               | grep -oE '\b[a-zA-Z_][a-zA-Z0-9_]*\(' | tr -d '(' | sort -u)
        keep=""
        IFS=',' read -ra wanted <<< "$WANT_VARS"
        for v in "${wanted[@]}"; do
            if grep -qx "$v" <<< "$have"; then
                keep="${keep:+${keep},}${v}"
            fi
        done

        if [[ -z "$keep" ]]; then
            echo "  ERROR: none of [${WANT_VARS}] present in ${stamp}"
            rm -f "$raw"
            (( errors++ )) || true
            continue
        fi

        if ncks -v "$keep" -O "$raw" "$ext" 2>/dev/null; then
            (( retrieved++ )) || true
        else
            echo "  ERROR: ncks failed for ${stamp}"
            rm -f "$ext"
            (( errors++ )) || true
        fi
        rm -f "$raw"
    done
done

rm -f "${TMP_DIR}"/*.nc "${TMP_DIR}/keep.ncks"
rmdir "$TMP_DIR" 2>/dev/null || true

echo "------------------------------------------------------------"
echo "  ${SUITE} / ${STREAM} finished: $(date)"
echo "  retrieved=${retrieved}  skipped=${skipped}  errors=${errors}  not_archived=${not_archived}"
echo "  local: $(find "$LOCAL_DIR" -name "*_${SUFFIX}.nc" -size +0 | wc -l) ${SUFFIX} files"
echo "------------------------------------------------------------"

(( errors == 0 )) || exit 1
exit 0
