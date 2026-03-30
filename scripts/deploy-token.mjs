#!/usr/bin/env node
/**
 * 龙虾大学 $LOBUNI 发币脚本
 * 使用 FlapSkill 合约 createToken
 */
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { bsc } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const FLAPSKILL = "0x482970490d06fc3a480bfd0e9e58141667cffedc";
const abi = parseAbi([
  "function createToken(string _name, string _symbol, string _meta, address _feeTo, bytes32 _salt, uint16 _taxRate, uint16 _mktBps, uint16 _dividendBps, uint16 _deflationBps, uint16 _lpBps, uint256 _minimumShareBalance) external returns (address token)"
]);

const pk = process.env.PRIVATE_KEY;
if (!pk) { console.error("请设置 PRIVATE_KEY 环境变量"); process.exit(1); }

const account = privateKeyToAccount(pk.startsWith("0x") ? pk : `0x${pk}`);
const client = createWalletClient({ account, chain: bsc, transport: http() });
const pub = createPublicClient({ chain: bsc, transport: http() });

console.log("发币钱包:", account.address);
console.log("代币: Lobster University ($LOBUNI)");
console.log("税率: 1%, 全部归 feeTo");
console.log("feeTo:", "0xD82913909e136779E854302E783ecdb06bfc7Ee2");
console.log("预测地址: 0x95E91880968Dec20b3288Be92862B2b961d47777");
console.log("---");

const hash = await client.writeContract({
  address: FLAPSKILL,
  abi,
  functionName: "createToken",
  args: [
    "Lobster University",
    "LOBUNI",
    "bafkreicx5yhogdpeopezb64ww7gywco3id7kxhf5in42gji5gbid6mw6fi",
    "0xD82913909e136779E854302E783ecdb06bfc7Ee2",
    "0x84e5486315a3d31cdebc8a60d242cdf9d96a4684f42929d016d56ff450db26ad",
    100,    // 1% tax
    10000,  // 100% to marketing (feeTo)
    0, 0, 0, 0n
  ],
});

console.log("TX Hash:", hash);
const receipt = await pub.waitForTransactionReceipt({ hash });
console.log("Status:", receipt.status);
console.log("Block:", receipt.blockNumber);

// 从 logs 中找代币地址
for (const log of receipt.logs) {
  if (log.topics[0] === "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef") {
    // Transfer event — 第一个通常是代币创建
    console.log("Token Address:", log.address);
  }
}
