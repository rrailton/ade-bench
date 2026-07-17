#!/usr/bin/env bash
# Repeatable benchmark matrix runner for Claude Code model/effort comparisons.
#
# Usage:
#   ./run-matrix.sh <arm-name> <model> <effort> [extra ade args...]
#   e.g. ./run-matrix.sh fable5-low claude-fable-5 low
#        ./run-matrix.sh opus48-xhigh claude-opus-4-8 xhigh
#
# Auth: export CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) before
# running for subscription-billed runs, or ANTHROPIC_API_KEY for API runs.
#
# Spend guard: tasks run in batches; between batches the cumulative output
# tokens in the results TSV are checked against MAX_OUTPUT_TOKENS. When the
# ceiling is exceeded, no further batches launch (in-flight trials finish).
set -euo pipefail
cd "$(dirname "$0")"

ARM="${1:?arm name required (e.g. fable5-low)}"
MODEL="${2:?model required (e.g. claude-fable-5)}"
EFFORT="${3:?effort required (low|medium|high|xhigh|max)}"
shift 3

# ---- knobs -----------------------------------------------------------------
N_ATTEMPTS="${N_ATTEMPTS:-1}"
N_CONCURRENT="${N_CONCURRENT:-2}"
BATCH_SIZE="${BATCH_SIZE:-10}"                    # tasks per batch
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-2000000}" # cumulative ceiling across the arm
TASK_FILE="${TASK_FILE:-matrix-tasks.txt}"        # one task id per line
NO_DIFFS="${NO_DIFFS:-1}"                         # 1 = skip file-diff snapshots (faster); agent transcripts unaffected
# ---------------------------------------------------------------------------

# Harness settings via env (no .env file; see Config.get_setting).
export DEFAULT_AGENT_TIMEOUT_SEC="${DEFAULT_AGENT_TIMEOUT_SEC:-1800}"
export SETUP_TIMEOUT_SEC="${SETUP_TIMEOUT_SEC:-600}"
export DEFAULT_TEST_TIMEOUT_SEC="${DEFAULT_TEST_TIMEOUT_SEC:-300}"
export CLEANUP_TIMEOUT_SEC="${CLEANUP_TIMEOUT_SEC:-180}"
export DOCKER_DEFAULT_PLATFORM=linux/amd64
export CLAUDE_CODE_EFFORT="$EFFORT"

if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: export CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY first." >&2
  exit 1
fi
# The agent requires the ANTHROPIC_API_KEY env var to exist even when unused.
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

[[ -r "$TASK_FILE" ]] || { echo "ERROR: $TASK_FILE not found." >&2; exit 1; }
TASKS=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] || TASKS+=("$line")
done < "$TASK_FILE"

RUN_ID="${ARM}__$(date +%Y-%m-%d__%H-%M-%S)"
RESULTS_DIR="experiments"
LOG="matrix-runs.log"
echo "$(date -Iseconds) START arm=$ARM model=$MODEL effort=$EFFORT run_id=$RUN_ID tasks=${#TASKS[@]} attempts=$N_ATTEMPTS ceiling=$MAX_OUTPUT_TOKENS" | tee -a "$LOG"

spent_tokens() {
  # Sum output_tokens (col 13) across all TSVs for this run id.
  find "$RESULTS_DIR" -name "results.tsv" -path "*${RUN_ID}*" 2>/dev/null \
    | xargs -r awk -F'\t' 'NR>1 {s+=$13} END {print s+0}'
}

batch_no=0
for ((i=0; i<${#TASKS[@]}; i+=BATCH_SIZE)); do
  batch_no=$((batch_no+1))
  batch=("${TASKS[@]:i:BATCH_SIZE}")

  spent="$(spent_tokens)"
  if (( spent > MAX_OUTPUT_TOKENS )); then
    echo "$(date -Iseconds) HALT ceiling exceeded: ${spent} > ${MAX_OUTPUT_TOKENS} output tokens; ${#TASKS[@]} tasks total, stopped before batch $batch_no" | tee -a "$LOG"
    exit 2
  fi
  echo "$(date -Iseconds) BATCH $batch_no (${batch[*]}) spent=${spent}" | tee -a "$LOG"

  # Each batch gets its own run dir (the harness assumes one run per run-id);
  # the shared RUN_ID prefix is what groups an arm for aggregation.
  .venv/bin/ade run "${batch[@]}" \
    --db duckdb --project-type dbt --agent claude \
    --model "$MODEL" \
    --n-attempts "$N_ATTEMPTS" \
    --n-concurrent-trials "$N_CONCURRENT" \
    --run-id "${RUN_ID}-b${batch_no}" \
    --no-rebuild \
    $( [[ "$NO_DIFFS" == "1" ]] && echo --no-diffs ) \
    "$@" || echo "$(date -Iseconds) WARN batch $batch_no exited nonzero (individual failures are normal)" | tee -a "$LOG"
done

echo "$(date -Iseconds) DONE arm=$ARM spent=$(spent_tokens) output tokens. Results: $RESULTS_DIR/$RUN_ID" | tee -a "$LOG"
