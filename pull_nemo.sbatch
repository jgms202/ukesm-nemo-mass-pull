#!/bin/bash
# ============================================================================
# pull_nemo.sbatch -- one Slurm array task per (non-comment) line of tasks.txt.
# Submit through submit.sh, which sizes the array and throttles it so MASS
# never sees more than 3 concurrent streams from one user.
#
# Tape bound, not CPU bound. cpu-long because one grid-T stream can exceed 6 h.
# ============================================================================

#SBATCH --job-name=nemo_mass
#SBATCH --partition=cpu-long
#SBATCH --time=48:00:00
#SBATCH --mem=8000
#SBATCH --cpus-per-task=2

set -o pipefail
module load scitools/default-current     # provides ncks / ncdump

REPO="${REPO:?submit via submit.sh}"
IDX=${SLURM_ARRAY_TASK_ID:-0}

mapfile -t TASKS < <(grep -vE '^\s*(#|$)' "${REPO}/tasks.txt")
if (( IDX >= ${#TASKS[@]} )); then
    echo "array index ${IDX} beyond task list (${#TASKS[@]} tasks)"; exit 1
fi

read -r SUITE STREAM Y0 Y1 <<< "${TASKS[$IDX]}"
echo "task ${IDX}: ${SUITE} ${STREAM} ${Y0}-${Y1}  on $(hostname)  $(date)"

bash "${REPO}/pull_nemo_mass.sh" \
     --suite "$SUITE" --stream "$STREAM" \
     --year-start "$Y0" --year-end "$Y1" \
     ${EXTRA_ARGS:-}
