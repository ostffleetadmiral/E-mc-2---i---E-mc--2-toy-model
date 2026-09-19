#!/usr/bin/env bash
# Qstar 24-hour dual-Ollama training driver.
#
# Runs two workers in parallel:
#   A -> local Ollama  (127.0.0.1:11434,      $LOCAL_MODEL)
#   B -> remote Ollama (192.168.12.211:11434, $REMOTE_MODEL)
#
# Each worker loops over its shard of the 100-topic lists:
#   1. qstar train-internet --articles <shard>   (Wikipedia fetch + Ollama augment)
#   2. qstar train --prompts <pshard>            (pure Ollama teacher expansion)
#
# Each invocation persists its corpus delta on exit (and every 5 articles
# inside train-internet), so the run checkpoints continuously. Workers use
# separate corpus files (qstar_corpus_{a,b}.txt) to avoid write contention;
# merge them afterwards if desired.
#
# Stop early:  touch datasets/train24h.stop   or   kill the PID in logs/train24h.pid
# Duration:    TRAIN24H_HOURS env (default 24)

set -u
cd "$(dirname "$0")/.."

QSTAR=./zig-out/bin/qstar
HOURS=${TRAIN24H_HOURS:-24}
DEADLINE=$((HOURS * 3600))
LOCAL_MODEL=${LOCAL_MODEL:-qwen2.5:3b}
REMOTE_MODEL=${REMOTE_MODEL:-qwen2.5:3b}
LOCAL_HOST=127.0.0.1
REMOTE_HOST=192.168.12.211
PORT=11434
STOPFILE=datasets/train24h.stop

mkdir -p logs datasets
rm -f "$STOPFILE"

# --- Interleave-shard the topic lists (even -> A, odd -> B) ---
shard() { # $1=infile $2=parity(0|1) $3=outfile
    awk 'NF && $1 !~ /^#/ { n++; if (n % 2 == '"$2"') print }' "$1" > "$3"
}
shard datasets/train24h_articles.txt 0 datasets/train24h_articles_A.txt
shard datasets/train24h_articles.txt 1 datasets/train24h_articles_B.txt
shard datasets/train24h_prompts.txt  0 datasets/train24h_prompts_A.txt
shard datasets/train24h_prompts.txt  1 datasets/train24h_prompts_B.txt

echo "[train24h] shards: A=$(wc -l < datasets/train24h_articles_A.txt) articles / $(wc -l < datasets/train24h_prompts_A.txt) prompts"
echo "[train24h] shards: B=$(wc -l < datasets/train24h_articles_B.txt) articles / $(wc -l < datasets/train24h_prompts_B.txt) prompts"
echo "[train24h] deadline: ${HOURS}h from $(date)"

worker() { # $1=tag $2=host $3=model
    local tag=$1 host=$2 model=$3
    local corpus="qstar_corpus_${tag,,}.txt"
    local log="logs/train24h_${tag}.log"
    local cycle=0
    echo "[worker-$tag] start $(date -Is) host=$host model=$model corpus=$corpus" >> "$log"
    while (( SECONDS < DEADLINE )) && [[ ! -f $STOPFILE ]]; do
        cycle=$((cycle + 1))
        local cycle_start=$SECONDS
        echo "[worker-$tag] === cycle $cycle (elapsed ${SECONDS}s) $(date -Is) ===" >> "$log"

        "$QSTAR" train-internet \
            --articles "datasets/train24h_articles_${tag}.txt" \
            --corpus "$corpus" \
            --ollama-host "$host" --ollama-port $PORT --model "$model" \
            >> "$log" 2>&1
        echo "[worker-$tag] internet pass exit=$? elapsed=${SECONDS}s" >> "$log"

        (( SECONDS >= DEADLINE )) && break
        [[ -f $STOPFILE ]] && break

        "$QSTAR" train \
            --prompts "datasets/train24h_prompts_${tag}.txt" \
            --corpus "$corpus" --teacher ollama \
            --ollama-host "$host" --ollama-port $PORT --model "$model" \
            >> "$log" 2>&1
        echo "[worker-$tag] teacher pass exit=$? elapsed=${SECONDS}s" >> "$log"

        # Backoff guard: a sub-minute cycle means the Ollama endpoint is
        # failing fast — don't hot-spin the log for 24h.
        if (( cycle_start + 60 > SECONDS )); then
            echo "[worker-$tag] cycle under 60s — backing off 120s" >> "$log"
            sleep 120
        fi
    done
    echo "[worker-$tag] finished after $cycle cycles, ${SECONDS}s $(date -Is)" >> "$log"
}

worker A "$LOCAL_HOST"  "$LOCAL_MODEL"  & A_PID=$!
worker B "$REMOTE_HOST" "$REMOTE_MODEL" & B_PID=$!
echo "$A_PID $B_PID" > logs/train24h.pid
echo "[train24h] workers: A pid=$A_PID (local $LOCAL_MODEL)  B pid=$B_PID (remote $REMOTE_MODEL)"
echo "[train24h] logs: logs/train24h_A.log logs/train24h_B.log"

wait $A_PID $B_PID
echo "[train24h] all workers done $(date -Is)"
echo "[train24h] corpus sizes:"
wc -l qstar_corpus_a.txt qstar_corpus_b.txt 2>/dev/null || true
