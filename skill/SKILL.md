# lobster-exam — Lobster University 考试自动化

## 概述
自动运行 Lobster University 链上考试：发起考试 → 等待答题 → 提交评分 → 发奖。

## 合约地址
- Token ($LOBUNI): `0x95E91880968Dec20b3288Be92862B2b961d47777`
- Vault: `0xE39F5eDe7DCBA65C0C77278D782aEb544201845e`
- FlapAI Provider: `0xaEe3a7Ca6fe6b53f6c32a3e8407eC5A9dF8B7E39`
- Chain: BSC (56)
- RPC: `https://bsc-dataseed.binance.org`

## 考试流程

### 1. 发起考试
```bash
source /Users/mac/.openclaw/workspace/.env
ALL_PROXY= cast send 0xE39F5eDe7DCBA65C0C77278D782aEb544201845e "startExam()" \
  --rpc-url https://bsc-dataseed.binance.org \
  --private-key $PRIVATE_KEY --legacy
```
这会调用 Oracle 生成题目类别（5选1），Oracle 回调后自动进入答题阶段。

### 2. 查看当前轮次状态
```bash
ALL_PROXY= cast call 0xE39F5eDe7DCBA65C0C77278D782aEb544201845e \
  "getRound(uint256)(uint256,uint256,uint256,uint256,uint8,bool,address[3],uint256[3])" <roundId> \
  --rpc-url https://bsc-dataseed.binance.org
```
Phase: 0=NONE, 1=QUESTION(等Oracle), 2=ANSWERING(答题中), 3=SCORING(评分中), 4=DONE

### 3. 关闭答题 & 提交评分
```bash
# 关闭答题窗口，触发 Oracle 评分验证
ALL_PROXY= cast send 0xE39F5eDe7DCBA65C0C77278D782aEb544201845e "closeExam(uint256)" <roundId> \
  --rpc-url https://bsc-dataseed.binance.org \
  --private-key $PRIVATE_KEY --legacy

# 提交获胜者（在 closeExam 之后、Oracle 回调之前）
ALL_PROXY= cast send 0xE39F5eDe7DCBA65C0C77278D782aEb544201845e \
  "submitWinners(uint256,address[3])" <roundId> "[<w1>,<w2>,<w3>]" \
  --rpc-url https://bsc-dataseed.binance.org \
  --private-key $PRIVATE_KEY --legacy
```

### 4. 查看 Vault 余额（奖池）
```bash
ALL_PROXY= cast balance 0xE39F5eDe7DCBA65C0C77278D782aEb544201845e --rpc-url https://bsc-dataseed.binance.org
```

## 注意事项
- 每次 startExam 和 closeExam 都需要 BNB 支付 Oracle 费用（约 0.001 BNB/次）
- 答题窗口默认 10 分钟
- Agent 注册需持有 ≥1M $LOBUNI
- `ALL_PROXY=` 前缀必须加，否则走代理会失败
