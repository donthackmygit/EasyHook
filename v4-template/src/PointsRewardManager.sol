// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PointsToken} from "./PointsToken.sol";

contract PointsRewardManager is Owned {
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address user,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 public immutable DOMAIN_SEPARATOR;

    PointsToken public immutable pointsToken;
    address public rewardSigner;

    mapping(address user => mapping(uint256 nonce => bool used)) public usedNonces;

    event PointsClaimed(address indexed user, uint256 amount, uint256 indexed nonce);
    event RewardSignerUpdated(address indexed oldSigner, address indexed newSigner);

    error InvalidRewardSigner();
    error InvalidClaimUser();
    error InvalidClaimAmount();
    error ClaimExpired();
    error NonceAlreadyUsed();
    error InvalidSignature();

    constructor(address _rewardSigner) Owned(msg.sender) {
        if (_rewardSigner == address(0)) revert InvalidRewardSigner();

        rewardSigner = _rewardSigner;
        pointsToken = new PointsToken();
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PointsRewardManager")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function setRewardSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidRewardSigner();

        address oldSigner = rewardSigner;
        rewardSigner = newSigner;

        emit RewardSignerUpdated(oldSigner, newSigner);
    }

    function claimPoints(address user, uint256 amount, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        if (user == address(0)) revert InvalidClaimUser();
        if (amount == 0) revert InvalidClaimAmount();
        if (block.timestamp > deadline) revert ClaimExpired();
        if (usedNonces[user][nonce]) revert NonceAlreadyUsed();

        bytes32 digest = claimDigest(user, amount, nonce, deadline);
        address signer = ECDSA.recover(digest, signature);
        if (signer != rewardSigner) revert InvalidSignature();

        usedNonces[user][nonce] = true;
        pointsToken.mint(user, amount);

        emit PointsClaimed(user, amount, nonce);
    }

    function claimDigest(address user, uint256 amount, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, user, amount, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }
}
