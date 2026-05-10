// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BridgeToken
contract BridgeToken is ERC20 {
    address public bridge;
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyBridge() {
        require(msg.sender == bridge, "Not bridge");
        _;
    }

    constructor() ERC20("Bridged USDC", "bUSDC") {
        owner = msg.sender;
    }

    /// @notice Configure a contract parameter
    function setBridge(address _bridge) external onlyOwner {
        require(_bridge != address(0), "Zero address");
        bridge = _bridge;
    }

    /// @notice Bridge tokens to another chain
    /// @param to Recipient address
    /// @param amount Token amount
    function bridgeMint(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
    }

    /// @notice Bridge tokens to another chain
    /// @param from Source address
    /// @param amount Token amount
    function bridgeBurn(address from, uint256 amount) external onlyBridge {
        _burn(from, amount);
    }
}

struct BridgeRequest {
    address recipient;
    uint256 amount;
    uint16 srcChain;
    bytes32 txHash;
}

contract TokenBridge {
    BridgeToken public token;
    address public relayer;
    address public admin;

    mapping(bytes32 => bool) public processedTxs;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }
    modifier onlyRelayer() {
        require(msg.sender == relayer, "Not relayer");
        _;
    }

    constructor(address _token, address _relayer) {
        token = BridgeToken(_token);
        admin = msg.sender;
        relayer = _relayer;
    }

    /// @notice Process pending operations
    function processBridgeRequest(BridgeRequest calldata req) external onlyRelayer {
        require(!processedTxs[req.txHash], "Already processed");

        processedTxs[req.txHash] = true;
        token.bridgeMint(req.recipient, req.amount);
    }

    /// @notice Submit a request or transaction
    function submitUserBridgeRequest(BridgeRequest calldata req) external {
        require(req.amount > 0, "Zero amount");
        require(req.srcChain > 0, "Invalid chain");

        token.bridgeBurn(msg.sender, req.amount);
        emit BridgeInitiated(msg.sender, req.recipient, req.amount, req.srcChain);
    }

    /// @notice Configure a contract parameter
    function setRelayer(address _relayer) external onlyAdmin {
        require(_relayer != address(0), "Zero address");
        relayer = _relayer;
    }

    event BridgeInitiated(address indexed sender, address recipient, uint256 amount, uint16 dstChain);
}

// IMPACT
// An attacker sets req.recipient to any address they control on the destination chain. They burn their own tokens but the
// bridge event instructs the relayer to mint tokens to the attacker-controlled recipient, enabling cross-chain fund
// redirection from legitimate users who expect to receive tokens.

// BUG
// submitUserBridgeRequest burns tokens from msg.sender using req.amount (correct) but emits the event with req.recipient which
// is user-controlled and not validated to equal msg.sender. The destination chain relayer will mint to req.recipient.

// INVARIANT
// The recipient on the destination chain must always be the sender (msg.sender) or an explicitly authorized delegate, not a
// user-controlled parameter.

// WHAT BREAKS
// submitUserBridgeRequest passes the user-supplied req.recipient directly into the bridge event without overriding it with
// msg.sender. While this looks like flexibility, a social engineering attack can exploit it: an attacker creates a phishing
// interface that constructs a BridgeRequest with the victim's amount but the attacker's recipient address on the destination
// chain.

// EXPLOIT PATH
// 1. Attacker deploys a phishing frontend that calls submitUserBridgeRequest
// 2. Victim approves and calls the function thinking they bridge 50,000 bUSDC to themselves on chain B
// 3. The phishing frontend sets req.recipient = attackerAddressOnChainB
// 4. bridgeBurn burns 50,000 bUSDC from victim (correct). Event emits recipient = attacker
// 5. Relayer on chain B processes the event, calls processBridgeRequest with req.recipient = attacker
// 6. 50,000 bUSDC minted to attacker on chain B. Victim loses funds.

// WHY MISSED
// The burn uses msg.sender (correct), and the function has non-zero checks. The vulnerability is in the trust boundary:
// req.recipient is user-supplied calldata that flows directly into the privileged bridge event without being overridden
// with msg.sender. Auditors checking the burn logic see it is correct and move on without tracing how recipient propagates
// to the destination chain.
