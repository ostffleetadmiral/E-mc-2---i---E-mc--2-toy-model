#!/usr/bin/env bash
# Qstar verified full-dataset training driver (replaces train24h.sh).
#
# Two workers in parallel, fact-checking ON for all generated text:
#   A -> local Ollama  (127.0.0.1:11434,      $LOCAL_MODEL)
#   B -> remote Ollama (192.168.12.211:11434, $REMOTE_MODEL)
#
# Phase 0 (once): stop any running train24h session, merge its worker
#                 corpora (qstar_corpus_{a,b}.txt) + qstar_corpus.txt into a
#                 deduplicated seed, copy to qstar_corpus_v{a,b}.txt.
# Phase 1 (once per worker): datasets/ split — each worker runs
#                 `train-corpus --ingest-dir <dir> --enrich-dir <dir>
#                 --fact-check` over its half of the top-level dataset dirs.
#                 Enrichment extractions are verified against the source
#                 document itself (extraction fidelity).
# Phase 2 (loop): train-internet over half the built-in WIKIPEDIA_ARTICLES
#                 sweep (--offset/--limit) + the worker's 110-topic article
#                 shard, then train --prompts on its prompt shard — all
#                 --fact-check (reference cache -> Wikipedia -> Playwright).
#
# Resume: per-directory .done markers in datasets/verified_done/ make Phase 1
# resumable; corpora checkpoint every 5 articles / 10 files / per pass.
#
# Stop early:  touch datasets/train_verified.stop  or  kill PIDs in logs/train_verified.pid
# Duration:    TRAIN_VERIFIED_HOURS env (default 48)

set -u
cd "$(dirname "$0")/.."

QSTAR=./zig-out/bin/qstar
HOURS=${TRAIN_VERIFIED_HOURS:-48}
DEADLINE=$((HOURS * 3600))
LOCAL_MODEL=${LOCAL_MODEL:-qwen2.5:3b}
REMOTE_MODEL=${REMOTE_MODEL:-qwen2.5:3b}
LOCAL_HOST=127.0.0.1
REMOTE_HOST=192.168.12.211
PORT=11434
STOPFILE=datasets/train_verified.stop
DONE_DIR=datasets/verified_done
FC_FLAGS="--fact-check --fc-judge-rate ${FC_JUDGE_RATE:-10} --fc-threshold ${FC_THRESHOLD:-550}"
WIKI_TOTAL=1345
WIKI_HALF=$(( (WIKI_TOTAL + 1) / 2 ))

mkdir -p logs datasets "$DONE_DIR"
rm -f "$STOPFILE"

# --- Phase 0: retire the unverified 24h run, seed verified corpora ---
if [[ -f logs/train24h.pid ]]; then
    echo "[verified] stopping train24h run..."
    touch datasets/train24h.stop
    sleep 3
    # shellcheck disable=SC2046
    kill $(cat logs/train24h.pid) 2>/dev/null || true
    pkill -f "qstar.*corpus qstar_corpus_[ab]\.txt" 2>/dev/null || true
    sleep 2
    rm -f datasets/train24h.stop logs/train24h.pid
    echo "[verified] train24h stopped; corpora preserved"
fi

if [[ ! -f qstar_corpus_va.txt || ! -f qstar_corpus_vb.txt ]]; then
    echo "[verified] merging existing corpora into verified seed..."
    cat qstar_corpus_a.txt qstar_corpus_b.txt qstar_corpus.txt 2>/dev/null \
        | awk 'NF' | sort -u > datasets/verified_seed.txt
    wc -l datasets/verified_seed.txt
    [[ -f qstar_corpus_va.txt ]] || cp datasets/verified_seed.txt qstar_corpus_va.txt
    [[ -f qstar_corpus_vb.txt ]] || cp datasets/verified_seed.txt qstar_corpus_vb.txt
fi

# --- Shard the 110-topic lists (even -> A, odd -> B) ---
shard() { # $1=infile $2=parity(0|1) $3=outfile
    awk 'NF && $1 !~ /^#/ { n++; if (n % 2 == '"$2"') print }' "$1" > "$3"
}
shard datasets/train24h_articles.txt 0 datasets/train24h_articles_A.txt
shard datasets/train24h_articles.txt 1 datasets/train24h_articles_B.txt
shard datasets/train24h_prompts.txt  0 datasets/train24h_prompts_A.txt
shard datasets/train24h_prompts.txt  1 datasets/train24h_prompts_B.txt

# --- Split top-level dataset dirs deterministically by sorted-order parity ---
mapfile -t DS_DIRS < <(find datasets -mindepth 1 -maxdepth 1 -type d \
    ! -name verified_done ! -name factcheck_refs | sort)
DIRS_A=(); DIRS_B=()
for idx in "${!DS_DIRS[@]}"; do
    if (( idx % 2 == 0 )); then DIRS_A+=("${DS_DIRS[$idx]}"); else DIRS_B+=("${DS_DIRS[$idx]}"); fi
done

echo "[verified] dataset dirs: A=${#DIRS_A[@]} B=${#DIRS_B[@]} of ${#DS_DIRS[@]}"
echo "[verified] shards: A=$(wc -l < datasets/train24h_articles_A.txt) articles / $(wc -l < datasets/train24h_prompts_A.txt) prompts"
echo "[verified] deadline: ${HOURS}h from $(date)"

worker() { # $1=tag $2=host $3=model ; dirs come from DIRS_A/DIRS_B
    local tag=$1 host=$2 model=$3
    local corpus="qstar_corpus_v${tag,,}.txt"
    local log="logs/train_verified_${tag}.log"
    local -n dirs_ref="DIRS_${tag}"
    local wiki_offset=0
    [[ $tag == B ]] && wiki_offset=$WIKI_HALF
    local cycle=0

    echo "[worker-$tag] start $(date -Is) host=$host model=$model corpus=$corpus" >> "$log"

    # ---- Phase 1: full-dataset ingest + verified enrich (resumable) ----
    for d in "${dirs_ref[@]}"; do
        [[ -f $STOPFILE ]] && break
        (( SECONDS >= DEADLINE )) && break
        local marker="$DONE_DIR/${tag}_$(basename "$d").done"
        if [[ -f $marker ]]; then
            echo "[worker-$tag] skip $d (done marker)" >> "$log"
            continue
        fi
        echo "[worker-$tag] phase1 $d $(date -Is)" >> "$log"
        "$QSTAR" train-corpus \
            --ingest-dir "$d" --enrich-dir "$d" \
            --corpus-file "$corpus" \
            --ollama-host "$host" --ollama-port $PORT --model "$model" \
            $FC_FLAGS \
            >> "$log" 2>&1
        local rc=$?
        echo "[worker-$tag] phase1 $d exit=$rc elapsed=${SECONDS}s" >> "$log"
        (( rc == 0 )) && touch "$marker"
    done

    # ---- Phase 2: verified Wikipedia sweep + topic shards + teacher loop ----
    while (( SECONDS < DEADLINE )) && [[ ! -f $STOPFILE ]]; do
        cycle=$((cycle + 1))
        local cycle_start=$SECONDS
        echo "[worker-$tag] === cycle $cycle (elapsed ${SECONDS}s) $(date -Is) ===" >> "$log"

        # Built-in 1,345-article sweep, half per worker
        "$QSTAR" train-internet \
            --corpus "$corpus" \
            --offset $wiki_offset --limit $WIKI_HALF \
            --ollama-host "$host" --ollama-port $PORT --model "$model" \
            $FC_FLAGS \
            >> "$log" 2>&1
        echo "[worker-$tag] wiki sweep pass exit=$? elapsed=${SECONDS}s" >> "$log"

        (( SECONDS >= DEADLINE )) && break
        [[ -f $STOPFILE ]] && break

        # 110-topic article shard
        "$QSTAR" train-internet \
            --articles "datasets/train24h_articles_${tag}.txt" \
            --corpus "$corpus" \
            --ollama-host "$host" --ollama-port $PORT --model "$model" \
            $FC_FLAGS \
            >> "$log" 2>&1
        echo "[worker-$tag] topics pass exit=$? elapsed=${SECONDS}s" >> "$log"

        (( SECONDS >= DEADLINE )) && break
        [[ -f $STOPFILE ]] && break

        # Teacher-prompt shard (verified against web references)
        "$QSTAR" train \
            --prompts "datasets/train24h_prompts_${tag}.txt" \
            --corpus "$corpus" --teacher ollama \
            --ollama-host "$host" --ollama-port $PORT --model "$model" \
            $FC_FLAGS \
            >> "$log" 2>&1
        echo "[worker-$tag] teacher pass exit=$? elapsed=${SECONDS}s" >> "$log"

        # Backoff guard: sub-minute cycle means the endpoint is failing fast
        if (( cycle_start + 60 > SECONDS )); then
            echo "[worker-$tag] cycle under 60s — backing off 120s" >> "$log"
            sleep 120
        fi
    done
    echo "[worker-$tag] finished after $cycle cycles, ${SECONDS}s $(date -Is)" >> "$log"
}

worker A "$LOCAL_HOST"  "$LOCAL_MODEL"  & A_PID=$!
worker B "$REMOTE_HOST" "$REMOTE_MODEL" & B_PID=$!
echo "$A_PID $B_PID" > logs/train_verified.pid
echo "[verified] workers: A pid=$A_PID (local $LOCAL_MODEL)  B pid=$B_PID (remote $REMOTE_MODEL)"
echo "[verified] logs: logs/train_verified_A.log logs/train_verified_B.log"
echo "[verified] corpora: qstar_corpus_va.txt qstar_corpus_vb.txt"

wait $A_PID $B_PID
echo "[verified] all workers done $(date -Is)"
echo "[verified] corpus sizes:"
wc -l qstar_corpus_va.txt qstar_corpus_vb.txt 2>/dev/null || true
