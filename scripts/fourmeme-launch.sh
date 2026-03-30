#!/bin/bash
set -euo pipefail
# Four.meme $LOBUNI token launch script
# Uses curl + cast (Foundry) — no npm deps needed

source /Users/mac/.openclaw/workspace/.env
RPC="https://bsc-dataseed.binance.org"
BASE="https://four.meme/meme-api"
WALLET=$(ALL_PROXY= cast wallet address --private-key "$PRIVATE_KEY")
TM2="0x5c952063c7fc8610FFDB798152D69F0B9550762b"

echo "Wallet: $WALLET"

# 1. Get nonce
echo "1. Getting nonce..."
NONCE=$(ALL_PROXY= curl -s "$BASE/v1/private/user/nonce/generate" \
  -H "Content-Type: application/json" \
  -d "{\"accountAddress\":\"$WALLET\",\"verifyType\":\"LOGIN\",\"networkCode\":\"BSC\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data'])")
echo "Nonce: $NONCE"

# 2. Sign message & login
echo "2. Signing & logging in..."
MESSAGE="You are sign in Meme $NONCE"
SIGNATURE=$(ALL_PROXY= cast wallet sign --private-key "$PRIVATE_KEY" "$MESSAGE")
echo "Signature: ${SIGNATURE:0:20}..."

ACCESS_TOKEN=$(ALL_PROXY= curl -s "$BASE/v1/private/user/login/dex" \
  -H "Content-Type: application/json" \
  -d "{
    \"region\":\"WEB\",\"langType\":\"EN\",\"loginIp\":\"\",\"inviteCode\":\"\",
    \"verifyInfo\":{\"address\":\"$WALLET\",\"networkCode\":\"BSC\",\"signature\":\"$SIGNATURE\",\"verifyType\":\"LOGIN\"},
    \"walletName\":\"MetaMask\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'])")
echo "Access token: ${ACCESS_TOKEN:0:20}..."

# 3. Upload logo
echo "3. Uploading logo..."
IMG_URL=$(ALL_PROXY= curl -s "$BASE/v1/private/token/upload" \
  -H "meme-web-access: $ACCESS_TOKEN" \
  -F "file=@/Users/mac/.openclaw/workspace/lobster-university/assets/logo.jpg" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data'])")
echo "Image URL: $IMG_URL"

# 4. Create token via API
echo "4. Creating token..."
LAUNCH_TIME=$(python3 -c "import time; print(int(time.time()*1000))")
CREATE_RESP=$(ALL_PROXY= curl -s "$BASE/v1/private/token/create" \
  -H "Content-Type: application/json" \
  -H "meme-web-access: $ACCESS_TOKEN" \
  -d "{
    \"name\":\"Lobster University\",
    \"shortName\":\"LOBUNI\",
    \"symbol\":\"BNB\",
    \"desc\":\"AI Agent Exam Arena on BNB Chain. Oracle-verified exams, on-chain rewards. Where AI Agents Earn Their Degree\",
    \"imgUrl\":\"$IMG_URL\",
    \"launchTime\":$LAUNCH_TIME,
    \"label\":\"AI\",
    \"lpTradingFee\":0.0025,
    \"webUrl\":\"https://miluan1995.github.io/lobster-university/\",
    \"twitterUrl\":\"\",
    \"telegramUrl\":\"\",
    \"preSale\":\"0\",
    \"raisedAmount\":\"18\",
    \"onlyMPC\":false,
    \"feePlan\":false,
    \"tokenTaxInfo\":{
      \"feeRate\":1,
      \"recipientRate\":100,
      \"recipientAddress\":\"$WALLET\",
      \"burnRate\":0,
      \"divideRate\":0,
      \"liquidityRate\":0,
      \"minSharing\":100000
    },
    \"raisedToken\":{
      \"symbol\":\"BNB\",\"nativeSymbol\":\"BNB\",
      \"symbolAddress\":\"0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c\",
      \"deployCost\":\"0\",\"buyFee\":\"0.01\",\"sellFee\":\"0.01\",\"minTradeFee\":\"0\",
      \"b0Amount\":\"8\",\"totalBAmount\":\"18\",\"totalAmount\":\"1000000000\",
      \"logoUrl\":\"https://static.four.meme/market/fc6c4c92-63a3-4034-bc27-355ea380a6795959172881106751506.png\",
      \"tradeLevel\":[\"0.1\",\"0.5\",\"1\"],\"status\":\"PUBLISH\",
      \"buyTokenLink\":\"https://pancakeswap.finance/swap\",
      \"reservedNumber\":10,\"saleRate\":\"0.8\",\"networkCode\":\"BSC\",\"platform\":\"MEME\"
    }
  }")
echo "Create response: $CREATE_RESP"

CREATE_ARG=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['createArg'])")
TX_SIG=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['signature'])")
echo "createArg: ${CREATE_ARG:0:40}..."
echo "signature: ${TX_SIG:0:40}..."

# 5. Call TokenManager2.createToken on-chain
echo "5. Calling createToken on-chain..."
TX_HASH=$(ALL_PROXY= HTTPS_PROXY= HTTP_PROXY= cast send \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC" \
  --value 0.005ether \
  "$TM2" \
  "createToken(bytes,bytes)" \
  "$CREATE_ARG" "$TX_SIG" \
  2>&1)
echo "Result: $TX_HASH"
