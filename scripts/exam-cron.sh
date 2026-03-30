#!/bin/bash
# Lobster University 考试自动化 — 每30分钟由 cron 调用
set -euo pipefail
source /Users/mac/.openclaw/workspace/.env

VAULT="0x8A9624fd8a55a4881c26B80801eDCE41C85DE79B"
RPC="https://bsc-dataseed.binance.org"
CAST="ALL_PROXY= cast"

call() { eval "$CAST call $VAULT \"$1\" --rpc-url $RPC ${2:-}"; }
send() { eval "$CAST send $VAULT \"$1\" --rpc-url $RPC --private-key $PRIVATE_KEY --legacy ${2:-}"; }

# Decode getRound: returns raw hex then abi-decode to handle fixed arrays
decode_round() {
  local raw
  raw=$(call "getRound(uint256)" "$1")
  eval "$CAST abi-decode 'f()(uint256,uint256,uint256,uint256,uint8,bool,address[3],uint256[3])' $raw"
}

ROUND=$(call "currentRound()(uint256)")
echo "Current round: $ROUND"

if [ "$ROUND" = "0" ]; then
  echo "No rounds yet, starting first exam..."
  send "startExam()"
  echo "Exam started! Round 1"
  exit 0
fi

ROUND_DATA=$(decode_round "$ROUND")
PHASE=$(echo "$ROUND_DATA" | sed -n '5p' | tr -d ' ')
echo "Round $ROUND phase: $PHASE"

case "$PHASE" in
  4) # DONE — 上一轮结束，开新一轮
    echo "Previous round done, starting new exam..."
    send "startExam()"
    echo "New exam started! Round $((ROUND + 1))"
    ;;
  2) # ANSWERING — 答题中，检查是否超时需要关闭
    START_TIME=$(echo "$ROUND_DATA" | sed -n '3p' | awk '{print $1}')
    WINDOW=$(call "answerWindow()(uint256)")
    NOW=$(date +%s)
    DEADLINE=$((START_TIME + WINDOW))
    if [ "$NOW" -ge "$DEADLINE" ]; then
      echo "Answer window expired, closing exam..."
      send "closeExam(uint256)" "$ROUND"
      echo "Exam closed, waiting for Oracle scoring"
    else
      REMAINING=$(( DEADLINE - NOW ))
      echo "Answer window still open, ${REMAINING}s remaining"
    fi
    ;;
  1) # QUESTION — 等待 Oracle 回调生成题目
    echo "Waiting for Oracle to generate question..."
    ;;
  3) # SCORING — 等待 Oracle 评分回调
    echo "Waiting for Oracle scoring callback..."
    ;;
  *) echo "Unknown phase: $PHASE" ;;
esac
