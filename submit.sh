#!/bin/bash
# ============================================================================
# submit.sh -- submit every line of tasks.txt as a throttled Slurm array.
#
#   ./submit.sh --dry-run          # ALWAYS FIRST: checks MASS, retrieves nothing
#   ./submit.sh                    # real pull
#   MAXPAR=2 ./submit.sh           # change concurrency (default 3; keep <= 3-4)
#   ARRAY=0-5 ./submit.sh          # run only some task lines (0-based)
#
# Extra args are passed straight to pull_nemo_mass.sh.
# ============================================================================

set -o nounset -o pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${REPO}/logs"
mkdir -p "$LOG_DIR"

N=$(grep -cvE '^\s*(#|$)' "${REPO}/tasks.txt")
(( N > 0 )) || { echo "no tasks in tasks.txt"; exit 1; }

ARRAY_SPEC="${ARRAY:-0-$(( N - 1 ))}%${MAXPAR:-3}"

echo "submitting ${N} task(s): array ${ARRAY_SPEC}  args: ${*:-none}"
JOBID=$(sbatch --parsable \
               --array="${ARRAY_SPEC}" \
               --output="${LOG_DIR}/nemo_mass_%A_%a.out" \
               --error="${LOG_DIR}/nemo_mass_%A_%a.err" \
               --export=ALL,REPO="${REPO}",EXTRA_ARGS="$*" \
               "${REPO}/pull_nemo.sbatch") || { echo "sbatch failed"; exit 1; }

echo "job id : ${JOBID}"
echo "watch  : squeue -u \$USER -j ${JOBID}"
echo "logs   : tail -f ${LOG_DIR}/nemo_mass_${JOBID}_*.out"
echo "cancel : scancel ${JOBID}"
