#!/usr/bin/env node
// Four.meme token launch script for $LOBUNI
import { createWalletClient, http, createPublicClient, encodeFunctionData } from 'viem';
import { bsc } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BASE = 'https://four.meme/meme-api';
const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) { console.error('PRIVATE_KEY not set'); process.exit(1); }

const account = privateKeyToAccount(PRIVATE_KEY);
const ADDRESS = account.address;
const TM2 = '0x5c952063c7fc8610FFDB798152D69F0B9550762b';

const publicClient = createPublicClient({ chain: bsc, transport: http('https://bsc-dataseed.binance.org') });
const walletClient = createWalletClient({ account, chain: bsc, transport: http('https://bsc-dataseed.binance.org') });

async function api(path, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['meme-web-access'] = token;
  const r = await fetch(`${BASE}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  const d = await r.json();
  if (d.code !== '0' && d.code !== 0) throw new Error(`API ${path}: ${JSON.stringify(d)}`);
  return d.data;
}

async function uploadImage(token, filePath) {
  const form = new FormData();
  const blob = new Blob([readFileSync(filePath)], { type: 'image/jpeg' });
  form.append('file', blob, 'logo.jpg');
  const r = await fetch(`${BASE}/v1/private/token/upload`, {
    method: 'POST',
    headers: { 'meme-web-access': token },
    body: form
  });
  const d = await r.json();
  if (d.code !== '0' && d.code !== 0) throw new Error(`Upload: ${JSON.stringify(d)}`);
  return d.data;
}

async function main() {
  console.log('Wallet:', ADDRESS);

  // 1. Get nonce
  console.log('1. Getting nonce...');
  const nonce = await api('/v1/private/user/nonce/generate', {
    accountAddress: ADDRESS, verifyType: 'LOGIN', networkCode: 'BSC'
  });
  console.log('Nonce:', nonce);

  // 2. Sign & login
  console.log('2. Signing & logging in...');
  const message = `You are sign in Meme ${nonce}`;
  const signature = await account.signMessage({ message });
  const accessToken = await api('/v1/private/user/login/dex', {
    region: 'WEB', langType: 'EN', loginIp: '', inviteCode: '',
    verifyInfo: { address: ADDRESS, networkCode: 'BSC', signature, verifyType: 'LOGIN' },
    walletName: 'MetaMask'
  });
  console.log('Access token:', accessToken.slice(0, 20) + '...');

  // 3. Upload logo
  console.log('3. Uploading logo...');
  const logoPath = resolve(__dirname, '../assets/logo.jpg');
  const imgUrl = await uploadImage(accessToken, logoPath);
  console.log('Image URL:', imgUrl);

  // 4. Create token
  console.log('4. Creating token...');
  const createData = await api('/v1/private/token/create', {
    name: 'Lobster University',
    shortName: 'LOBUNI',
    desc: 'AI Agent Exam Arena on BNB Chain. Oracle-verified exams, on-chain rewards. Where AI Agents Earn Their Degree 🎓🦞',
    imgUrl,
    launchTime: Date.now(),
    label: 'AI',
    lpTradingFee: 0.0025,
    webUrl: 'https://miluan1995.github.io/lobster-university/',
    twitterUrl: '',
    telegramUrl: '',
    preSale: '0',
    onlyMPC: false,
    feePlan: false,
    tokenTaxInfo: {
      feeRate: 1,
      recipientRate: 100,
      recipientAddress: ADDRESS, // dev wallet, will forward 70% to Vault
      burnRate: 0,
      divideRate: 0,
      liquidityRate: 0,
      minSharing: 100000
    },
    raisedToken: {
      symbol: 'BNB', nativeSymbol: 'BNB',
      symbolAddress: '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c',
      deployCost: '0', buyFee: '0.01', sellFee: '0.01', minTradeFee: '0',
      b0Amount: '8', totalBAmount: '18', totalAmount: '1000000000',
      logoUrl: 'https://static.four.meme/market/fc6c4c92-63a3-4034-bc27-355ea380a6795959172881106751506.png',
      tradeLevel: ['0.1', '0.5', '1'], status: 'PUBLISH',
      buyTokenLink: 'https://pancakeswap.finance/swap',
      reservedNumber: 10, saleRate: '0.8', networkCode: 'BSC', platform: 'MEME'
    }
  }, accessToken);

  console.log('Create response:', JSON.stringify(createData));
  const { createArg, signature: txSig } = createData;

  // 5. Call TokenManager2.createToken on-chain
  console.log('5. Calling createToken on-chain...');
  const hash = await walletClient.sendTransaction({
    to: TM2,
    data: encodeFunctionData({
      abi: [{
        name: 'createToken',
        type: 'function',
        inputs: [{ name: 'createArg', type: 'bytes' }, { name: 'sign', type: 'bytes' }],
        outputs: [],
        stateMutability: 'payable'
      }],
      args: [createArg, txSig]
    }),
    value: 5000000000000000n // 0.005 BNB launch fee
  });
  console.log('TX hash:', hash);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log('Status:', receipt.status);
  console.log('Block:', receipt.blockNumber);

  // Parse TokenCreate event to get token address
  const tokenCreateTopic = '0x'; // will parse from logs
  for (const log of receipt.logs) {
    // TokenCreate event from TM2
    if (log.address.toLowerCase() === TM2.toLowerCase() && log.topics.length > 0) {
      console.log('Log:', log.address, log.topics[0]);
    }
    // New token address is usually in the logs
    for (const topic of log.topics) {
      if (topic.length === 66) {
        const addr = '0x' + topic.slice(26);
        if (addr.toLowerCase().endsWith('4444')) {
          console.log('🦞 TOKEN ADDRESS:', addr);
        }
      }
    }
  }
  // Also check all unique addresses in logs
  const addrs = new Set();
  for (const log of receipt.logs) {
    addrs.add(log.address);
  }
  console.log('All log addresses:', [...addrs]);
}

main().catch(e => { console.error(e); process.exit(1); });
