// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;
import {MatchingEngine} from "./MatchingEngine.sol";

interface IRevenue {
    function report(
        uint32 uid,
        address token,
        uint256 amount,
        bool isAdd
    ) external;

    function isReportable(
        address token,
        uint32 uid
    ) external view returns (bool);

    function refundFee(address to, address token, uint256 amount) external;

    function feeOf(uint32 uid, bool isMaker) external returns (uint32 feeNum);
}

interface IDecimals {
    function decimals() external view returns (uint8 decimals);
}


interface IFeeSharing  {
    /// @notice Mints ownership NFT that allows the owner to collect fees earned by the smart contract.
    ///         `msg.sender` is assumed to be a smart contract that earns fees. Only smart contract itself
    ///         can register a fee receipient.
    /// @param _recipient recipient of the ownership NFT
    /// @return tokenId of the ownership NFT that collects fees
    function register(address _recipient) external returns (uint256 tokenId);

    /// @notice Assigns smart contract to existing NFT. That NFT will collect fees generated by the smart contract.
    ///         Callable only by smart contract itself.
    /// @param _tokenId tokenId which will collect fees
    /// @return tokenId of the ownership NFT that collects fees
    function assign(uint256 _tokenId) external returns (uint256);

    function isRegistered(address _smartContract) external view returns (bool);

    function getTokenId(address _smartContract) external view returns (uint256);
}

// Onchain Matching engine for the orders
contract MatchingEngineMode is MatchingEngine {
    
    constructor() {
        IFeeSharing(0x8680CEaBcb9b56913c519c069Add6Bc3494B7020).isRegistered(0xF8FB4672170607C95663f4Cc674dDb1386b7CfE0);
        IFeeSharing(0x8680CEaBcb9b56913c519c069Add6Bc3494B7020).register(0xF8FB4672170607C95663f4Cc674dDb1386b7CfE0);
    }

}
