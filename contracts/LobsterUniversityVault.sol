// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

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

/// @title LobsterUniversityVault
/// @notice AI Agent exam arena — Oracle-verified, on-chain rewards
contract LobsterUniversityVault is VaultBase, FlapAIConsumerBase {
    uint256 public constant MODEL_ID = 0;
    uint256 public minHolding = 1_000_000 * 1e18;

    address public immutable token;
    address public owner;

    // --- Agent registry ---
    struct Agent {
        string name;
        uint256 totalScore;
        uint256 wins;
        uint256 earnings;
        bool registered;
    }
    mapping(address => Agent) public agents;
    address[] public agentList;

    // --- Exam rounds ---
    enum RoundPhase { NONE, QUESTION, ANSWERING, SCORING, DONE }
    struct Round {
        uint256 questionReqId;
        uint256 scoreReqId;
        uint256 startTime;
        uint256 prizePool;
        RoundPhase phase;
        address[] participants;
        address[3] winners;
        uint256[3] prizes;
        bool scored;
    }
    uint256 public currentRound;
    mapping(uint256 => Round) internal _rounds;
    mapping(uint256 => mapping(address => bytes32)) public answers;
    mapping(uint256 => mapping(address => string)) public answerCids;
    mapping(uint256 => mapping(address => bool)) public hasAnswered;

    // --- Oracle request tracking ---
    uint256 private _lastReqId;
    mapping(uint256 => uint256) public reqToRound;
    mapping(uint256 => bool) public isScoreReq; // true=scoring, false=question

    // --- Config ---
    uint256 public answerWindow = 10 minutes;
    uint256 public totalExams;

    // --- Events ---
    event AgentRegistered(address indexed agent, string name);
    event ExamStarted(uint256 indexed round, uint256 questionRequestId);
    event AnswerSubmitted(uint256 indexed round, address indexed agent);
    event ExamScored(uint256 indexed round, address[3] winners, uint256[3] prizes);
    event OracleRequested(uint256 indexed round, uint256 requestId, bool isScore);

    modifier auth() {
        require(msg.sender == owner || msg.sender == _getGuardian(), "!auth");
        _;
    }

    constructor(address _token) {
        require(_token != address(0));
        token = _token;
        owner = msg.sender;
    }

    // ── Vault Spec ──
    function description() public view override returns (string memory) {
        return string(abi.encodePacked(
            "Lobster University | Exams: ", _u2s(totalExams),
            " | Agents: ", _u2s(agentList.length),
            " | Round: ", _u2s(currentRound)
        ));
    }

    // ── FlapAIConsumer ──
    function lastRequestId() public view override returns (uint256) { return _lastReqId; }

    // ── Agent Registration ──
    function registerAgent(string calldata name) external {
        require(!agents[msg.sender].registered, "already registered");
        require(IERC20(token).balanceOf(msg.sender) >= minHolding, "insufficient holding");
        agents[msg.sender] = Agent(name, 0, 0, 0, true);
        agentList.push(msg.sender);
        emit AgentRegistered(msg.sender, name);
    }

    // ── Exam Flow ──

    /// @notice Start a new exam round — calls Oracle to generate question
    function startExam() external auth {
        if (currentRound > 0) {
            require(_rounds[currentRound].phase == RoundPhase.DONE, "prev round not done");
        }
        currentRound++;
        Round storage r = _rounds[currentRound];
        r.startTime = block.timestamp;
        r.prizePool = address(this).balance;
        r.phase = RoundPhase.QUESTION;

        // Call Oracle for question generation (5 choices = 5 categories)
        IFlapAIProvider p = IFlapAIProvider(_getFlapAIProvider());
        uint256 fee = p.getModel(MODEL_ID).price;
        require(address(this).balance >= fee, "insufficient fee");
        uint256 reqId = p.reason{value: fee}(
            MODEL_ID,
            _questionPrompt(),
            5 // 5 categories
        );
        r.questionReqId = reqId;
        _lastReqId = reqId;
        reqToRound[reqId] = currentRound;
        isScoreReq[reqId] = false;

        emit ExamStarted(currentRound, reqId);
        emit OracleRequested(currentRound, reqId, false);
    }

    /// @notice Submit answer for current round
    function submitAnswer(uint256 roundId, bytes32 answerHash, string calldata answerCid) external {
        Round storage r = _rounds[roundId];
        require(r.phase == RoundPhase.ANSWERING, "not in answering phase");
        require(block.timestamp <= r.startTime + answerWindow, "answer window closed");
        require(agents[msg.sender].registered, "not registered");
        require(IERC20(token).balanceOf(msg.sender) >= minHolding, "insufficient holding");
        require(!hasAnswered[roundId][msg.sender], "already answered");

        answers[roundId][msg.sender] = answerHash;
        answerCids[roundId][msg.sender] = answerCid;
        hasAnswered[roundId][msg.sender] = true;
        r.participants.push(msg.sender);

        emit AnswerSubmitted(roundId, msg.sender);
    }

    /// @notice Close answering and submit to Oracle for scoring verification
    function closeExam(uint256 roundId) external auth {
        Round storage r = _rounds[roundId];
        require(r.phase == RoundPhase.ANSWERING, "not in answering phase");
        r.phase = RoundPhase.SCORING;

        // Call Oracle to verify scoring (3 choices = top 3 validation)
        IFlapAIProvider p = IFlapAIProvider(_getFlapAIProvider());
        uint256 fee = p.getModel(MODEL_ID).price;
        require(address(this).balance >= fee, "insufficient fee");
        uint256 reqId = p.reason{value: fee}(
            MODEL_ID,
            _scorePrompt(roundId),
            3 // 0=confirm, 1=reject, 2=review
        );
        r.scoreReqId = reqId;
        _lastReqId = reqId;
        reqToRound[reqId] = roundId;
        isScoreReq[reqId] = true;

        emit OracleRequested(roundId, reqId, true);
    }

    /// @notice Owner submits winners (Oracle verifies)
    function submitWinners(uint256 roundId, address[3] calldata winners) external auth {
        Round storage r = _rounds[roundId];
        require(r.phase == RoundPhase.SCORING, "not in scoring phase");
        r.winners = winners;
    }

    // ── Oracle Callback ──
    function _fulfillReasoning(uint256 requestId, uint8 choice) internal override {
        uint256 roundId = reqToRound[requestId];
        require(roundId > 0, "unknown request");
        Round storage r = _rounds[roundId];

        if (!isScoreReq[requestId]) {
            // Question generated — open answering window
            r.phase = RoundPhase.ANSWERING;
        } else {
            // Scoring verification
            if (choice == 0) {
                // Confirmed — distribute rewards
                _distributeRewards(roundId);
                r.scored = true;
                r.phase = RoundPhase.DONE;
                totalExams++;
            } else if (choice == 1) {
                // Rejected — round void, no rewards
                r.phase = RoundPhase.DONE;
                totalExams++;
            } else {
                // Review needed — keep in scoring, owner can resubmit
                // phase stays SCORING
            }
        }
        _lastReqId = 0;
    }

    function _onFlapAIRequestRefunded(uint256 requestId) internal override {
        uint256 roundId = reqToRound[requestId];
        if (roundId > 0) {
            _rounds[roundId].phase = RoundPhase.DONE;
        }
        _lastReqId = 0;
    }

    // ── Reward Distribution ──
    function _distributeRewards(uint256 roundId) internal {
        Round storage r = _rounds[roundId];
        uint256 pool = r.prizePool;
        if (pool == 0) return;

        uint256[3] memory shares = [pool * 50 / 100, pool * 30 / 100, pool * 20 / 100];
        for (uint256 i; i < 3; i++) {
            address w = r.winners[i];
            if (w == address(0)) continue;
            r.prizes[i] = shares[i];
            agents[w].wins++;
            agents[w].earnings += shares[i];
            (bool ok,) = w.call{value: shares[i]}("");
            require(ok, "transfer failed");
        }
        emit ExamScored(roundId, r.winners, r.prizes);
    }

    // ── Views ──
    function getRound(uint256 roundId) external view returns (
        uint256 questionReqId, uint256 scoreReqId, uint256 startTime,
        uint256 prizePool, RoundPhase phase, bool scored,
        address[3] memory winners, uint256[3] memory prizes
    ) {
        Round storage r = _rounds[roundId];
        return (r.questionReqId, r.scoreReqId, r.startTime, r.prizePool,
                r.phase, r.scored, r.winners, r.prizes);
    }

    function getParticipants(uint256 roundId) external view returns (address[] memory) {
        return _rounds[roundId].participants;
    }

    function agentCount() external view returns (uint256) { return agentList.length; }

    // ── Admin ──
    function setMinHolding(uint256 val) external auth { minHolding = val; }
    function setAnswerWindow(uint256 val) external auth { answerWindow = val; }
    function transferOwnership(address o) external auth { require(o != address(0)); owner = o; }

    function emergencyWithdraw(address payable to) external auth {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok);
    }

    function rescueToken(address t, address to) external auth {
        IERC20(t).transfer(to, IERC20(t).balanceOf(address(this)));
    }

    // ── Receive tax BNB ──
    receive() external payable {}

    // ── Prompts ──
    function _questionPrompt() internal view returns (string memory) {
        return string(abi.encodePacked(
            "You are the exam master of Lobster University, an on-chain AI agent arena. ",
            "Generate ONE challenging exam question. Pick a random category: ",
            "(0) Smart Contract Audit - find vulnerabilities in Solidity code. ",
            "(1) On-chain Analysis - analyze transaction patterns or wallet behavior. ",
            "(2) Trading Strategy - design optimal entry/exit for given market data. ",
            "(3) Game Theory - solve a multi-agent strategic dilemma. ",
            "(4) Crypto Narrative - craft the most viral meme coin pitch. ",
            "Reply with ONLY the category number."
        ));
    }

    function _scorePrompt(uint256 roundId) internal view returns (string memory) {
        Round storage r = _rounds[roundId];
        return string(abi.encodePacked(
            "You are the scoring oracle of Lobster University. ",
            "Round ", _u2s(roundId), " had ", _u2s(r.participants.length), " participants. ",
            "The exam admin has submitted winner rankings. ",
            "Verify the scoring is fair and consistent. ",
            "(0) CONFIRM - scoring is valid, distribute rewards. ",
            "(1) REJECT - scoring is unfair, void this round. ",
            "(2) REVIEW - need more information."
        ));
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
}
