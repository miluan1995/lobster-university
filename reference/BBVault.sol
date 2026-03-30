// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// lib/forge-std/src/interfaces/IERC20.sol

/// @dev Interface of the ERC20 standard as defined in the EIP.
/// @dev This includes the optional name, symbol, and decimals metadata.
interface IERC20 {
    /// @dev Emitted when `value` tokens are moved from one account (`from`) to another (`to`).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @dev Emitted when the allowance of a `spender` for an `owner` is set, where `value`
    /// is the new allowance.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Returns the amount of tokens in existence.
    function totalSupply() external view returns (uint256);

    /// @notice Returns the amount of tokens owned by `account`.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Moves `amount` tokens from the caller's account to `to`.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Returns the remaining number of tokens that `spender` is allowed
    /// to spend on behalf of `owner`
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
    /// @dev Be aware of front-running risks: https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Moves `amount` tokens from `from` to `to` using the allowance mechanism.
    /// `amount` is then deducted from the caller's allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Returns the name of the token.
    function name() external view returns (string memory);

    /// @notice Returns the symbol of the token.
    function symbol() external view returns (string memory);

    /// @notice Returns the decimals places of the token.
    function decimals() external view returns (uint8);
}

// src/interfaces/IFlapAIProvider.sol

interface IFlapAIProvider {
    struct Model { string name; uint256 price; bool enabled; }
    enum RequestStatus { NONE, PENDING, FULFILLED, UNDELIVERED, REFUNDED }
    struct Request {
        address consumer; uint16 modelId; uint8 numOfChoices; uint64 timestamp;
        uint128 feePaid; RequestStatus status; uint8 choice; bytes14 reserved;
    }
    function reason(uint256 modelId, string calldata prompt, uint8 numOfChoices) external payable returns (uint256 requestId);
    function getModel(uint256 modelId) external view returns (Model memory);
    function getReasoningCid(uint256 requestId) external view returns (string memory);
    function getRequest(uint256 requestId) external view returns (Request memory);
}

abstract contract FlapAIConsumerBase {
    error FlapAIConsumerOnlyProvider();
    error FlapAIConsumerUnsupportedChain(uint256 chainId);

    function lastRequestId() public view virtual returns (uint256);
    function _fulfillReasoning(uint256 requestId, uint8 choice) internal virtual;
    function _onFlapAIRequestRefunded(uint256 requestId) internal virtual;

    function _getFlapAIProvider() internal view virtual returns (address) {
        uint256 id = block.chainid;
        if (id == 56) return 0xaEe3a7Ca6fe6b53f6c32a3e8407eC5A9dF8B7E39;
        if (id == 97) return 0xFBeE0a1C921f6f4DadfAdd102b8276175D1b518D;
        revert FlapAIConsumerUnsupportedChain(id);
    }

    function fulfillReasoning(uint256 requestId, uint8 choice) external {
        if (msg.sender != _getFlapAIProvider()) revert FlapAIConsumerOnlyProvider();
        _fulfillReasoning(requestId, choice);
    }

    function onFlapAIRequestRefunded(uint256 requestId) external payable {
        if (msg.sender != _getFlapAIProvider()) revert FlapAIConsumerOnlyProvider();
        _onFlapAIRequestRefunded(requestId);
    }
}

// src/interfaces/IPancakeRouter.sol

interface IPancakeRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable;
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

// src/interfaces/VaultBase.sol

/// @title VaultBase — Flap Vault Specification V1
abstract contract VaultBase {
    error UnsupportedChain(uint256 chainId);

    function _getPortal() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56) return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        if (id == 97) return 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        revert UnsupportedChain(id);
    }

    function _getGuardian() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (id == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        revert UnsupportedChain(id);
    }

    function description() public view virtual returns (string memory);
}

// src/BlackBearAIVault.sol

/// @title BlackBearAIVault
/// @notice AI Oracle-driven Buyback & Burn vault — Flap Vault Spec V1 compliant
contract BlackBearAIVault is VaultBase, FlapAIConsumerBase {
    uint256 public constant MODEL_ID = 0; // google/gemini-3-flash
    uint8   public constant NUM_CHOICES = 3;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    address public immutable token;
    address public owner;

    uint256 public minBal;       // min BNB to trigger AI
    uint256 public cooldown;     // seconds between AI calls
    uint256 public bbBps;        // aggressive buyback bps
    uint256 public smBps;        // conservative buyback bps
    uint256 public slipBps;      // slippage tolerance bps

    uint256 private _lastReqId;
    uint8   public lastChoice;
    uint8   public pendingAct;   // 0=none, 1=aggressive, 2=conservative
    bool    public hasPending;
    uint256 public lastReasonTs;

    uint256 public totalBB;      // total BNB spent on buyback
    uint256 public totalBurned;  // total tokens burned
    uint256 public totalReqs;

    event Requested(uint256 id, uint256 bal);
    event Fulfilled(uint256 id, uint8 choice);
    event Refunded(uint256 id);
    event Queued(uint8 act);
    event BuybackBurn(uint256 bnb, uint256 tokens, uint8 act);

    modifier auth() {
        require(msg.sender == owner || msg.sender == _getGuardian(), "!auth");
        _;
    }

    constructor(address _token, uint256 _minBal, uint256 _cooldown) {
        require(_token != address(0));
        token = _token;
        owner = msg.sender;
        minBal = _minBal;
        cooldown = _cooldown;
        bbBps = 8000;
        smBps = 2000;
        slipBps = 500;
    }

    // ── Flap Vault Spec ──
    function description() public view override(VaultBase) returns (string memory) {
        return string(abi.encodePacked(
            "Black Bear AI Vault | Burned: ", _u2s(totalBurned),
            " | Reqs: ", _u2s(totalReqs), " | Last: ", _u2s(lastChoice)
        ));
    }

    // ── FlapAIConsumer ──
    function lastRequestId() public view override returns (uint256) { return _lastReqId; }

    function _fulfillReasoning(uint256 id, uint8 choice) internal override {
        require(id == _lastReqId);
        _lastReqId = 0;
        lastChoice = choice;
        emit Fulfilled(id, choice);
        if (choice == 0) { hasPending = true; pendingAct = 1; emit Queued(1); }
        else if (choice == 2) { hasPending = true; pendingAct = 2; emit Queued(2); }
    }

    function _onFlapAIRequestRefunded(uint256 id) internal override {
        require(id == _lastReqId);
        _lastReqId = 0;
        emit Refunded(id);
    }

    // ── Core Logic ──
    receive() external payable {
        if (hasPending) { _exec(); return; }
        if (_lastReqId != 0) return;
        if (address(this).balance < minBal) return;
        if (lastReasonTs != 0 && block.timestamp < lastReasonTs + cooldown) return;
        _requestAI();
    }

    function manualReason() external auth {
        require(_lastReqId == 0 && !hasPending);
        _requestAI();
    }

    function executePending() external auth {
        require(hasPending);
        _exec();
    }

    function _requestAI() internal {
        IFlapAIProvider p = IFlapAIProvider(_getFlapAIProvider());
        uint256 fee = p.getModel(MODEL_ID).price;
        require(address(this).balance >= fee);
        _lastReqId = p.reason{value: fee}(MODEL_ID, _prompt(), NUM_CHOICES);
        lastReasonTs = block.timestamp;
        totalReqs++;
        emit Requested(_lastReqId, address(this).balance);
    }

    function _exec() internal {
        hasPending = false;
        uint8 a = pendingAct;
        if (a == 1) _buyback(bbBps);
        else if (a == 2) _buyback(smBps);
    }

    function _buyback(uint256 bps) internal {
        uint256 amt = (address(this).balance * bps) / 10000;
        if (amt == 0) return;
        IPancakeRouter r = IPancakeRouter(ROUTER);
        address[] memory path = new address[](2);
        path[0] = r.WETH(); path[1] = token;
        uint256[] memory out = r.getAmountsOut(amt, path);
        uint256 minOut = (out[1] * (10000 - slipBps)) / 10000;
        uint256 pre = IERC20(token).balanceOf(address(this));
        r.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amt}(minOut, path, address(this), block.timestamp);
        uint256 got = IERC20(token).balanceOf(address(this)) - pre;
        if (got > 0) IERC20(token).transfer(DEAD, got);
        totalBB += amt; totalBurned += got;
        emit BuybackBurn(amt, got, pendingAct);
    }

    function _prompt() internal view returns (string memory) {
        return string(abi.encodePacked(
            "You are an AI strategist for a Buyback & Burn vault on BNB Chain. ",
            "Token: ", _hex(token), ". Balance: ", _u2s(address(this).balance / 1e15), " finney. ",
            "Use ave_token_tool to check market data. Decide: ",
            "(0) Aggressive buyback 80% - favorable conditions. ",
            "(1) Hold - unfavorable/uncertain. ",
            "(2) Conservative buyback 20% - neutral. ",
            "Reply with only the number."
        ));
    }

    // ── Admin ──
    function setParams(uint256 _min, uint256 _cd, uint256 _bb, uint256 _sm, uint256 _sl) external auth {
        require(_bb <= 10000 && _sm <= 10000 && _sl <= 5000);
        minBal = _min; cooldown = _cd; bbBps = _bb; smBps = _sm; slipBps = _sl;
    }
    function transferOwnership(address o) external auth { require(o != address(0)); owner = o; }
    function emergencyWithdraw(address payable to) external auth {
        (bool ok,) = to.call{value: address(this).balance}(""); require(ok);
    }
    function rescueToken(address t, address to) external auth {
        IERC20(t).transfer(to, IERC20(t).balanceOf(address(this)));
    }

    // ── Helpers ──
    function _u2s(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v; uint256 d;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { b[--d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
    function _hex(address a) internal pure returns (string memory) {
        bytes16 h = "0123456789abcdef";
        bytes memory s = new bytes(42); s[0] = "0"; s[1] = "x";
        bytes20 ad = bytes20(a);
        for (uint256 i; i < 20; i++) { s[2+i*2] = h[uint8(ad[i])>>4]; s[3+i*2] = h[uint8(ad[i])&0xf]; }
        return string(s);
    }
}

