// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Parent contract to create a hook contract
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

// This library allows for transferring and holding native tokens and ERC20 tokens
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

// Contains a struct to create Pool and their generating a poolId using PoolIdLibrary
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

// Contains hooks
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

// BalanceDelta Library for getting the amount0 and amount1 deltas from the BalanceDelta type
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// Library for getting the specified and unspecified deltas from the BeforeSwapDelta type()
// Uesed to handle information about token amount changes before a swap happens
import {BeforeSwapDeltaLibrary, BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

// Interface to interact with a pool manager
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

// engine that match orders using the order book contract
import {IEngine} from "@standardweb3/exchange/interfaces/IEngine.sol";

import {IERC20} from "openzeppelin/contracts/token/erc20/IERC20.sol";

// Declare the hook contracts
contract OrderBookHookV4 is BaseHook {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    address matchingEngine;
    address weth;

    // Pseudo code
    // include a constructor as well as basehook contract
    // utilize the PoolManager contract, weth, matchingengine
    constructor(
        IPoolManager _poolmanager,
        address _matchingengine,
        address _weth
    ) BaseHook(_poolmanager) {
        matchingEngine = _matchingengine;
        weth = _weth;
    }

    /* beforeSwapReturnDelta VS beforeSwap : Could be written as as post or tweet
    @note The "beforeSwapReturnDelta" functionality is used in the "Committing Capital" phase.
    It allows the system to dynamically adjust the amount being swapped in the AMM part of the transaction  
    For example, if a user wants to swap 100 USDC for ETH, the hook might use beforeSwapReturnDelta to:
    Reduce the swap amount to 80 USDC
    Reserve the remaining 20 USDC for the orderbook part of the system */

    // Override this function from based hook to specified which hooks will be used in this contract hooks.
    // NOTE: we are going to use the FLAG associted with every permissions to deploy a hook contract
    // These hooks Hooks lives in Hooks.sol
    // NOTE: in my usecase I need to enable BeforeSwap and BeforeSwapReturnData
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // It can perform checks or modifications but doesn't directly alter the swap amounts
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // It allows the hook to actually modify the amounts being swapped.
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Creates a BeforeSwapDelta from specified and unspecified
    function toBeforeSwapDelta(
        int128 deltaSpecified,
        int128 deltaUnspecified
    ) internal pure returns (BeforeSwapDelta beforeSwapDelta) {
        /// @solidity memory-safe-assembly
        assembly {
            // Combine deltaSpecified and deltaUnspecified into a single 256-bit value
            beforeSwapDelta := or(
                // Shift deltaSpecified left by 128 bits
                shl(128, deltaSpecified),
                // Mask deltaUnspecified to ensure it fits in 128 bits
                and(sub(shl(128, 1), 1), deltaUnspecified)
            )
        }
    }

    // Before swap hook we can add any logic
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    )
        external
        override
        returns (
            // poolManagerOnly, // NOTE:add this later
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        // Get original deltas from the swap parameters
        BeforeSwapDelta before = BeforeSwapDelta.wrap(
            swapParams.amountSpecified
        );

        // Calculate how much should be used for the limit order.
        uint128 amount = _limitOrder(key, swapParams, hookData);

        // TODO: setup delta after taking input fund from pool manager and settle
        // int128 afterOrder = before.getSpecifiedDelta() - int128(amount); // audit-issue uncomment this

        // does the retur
        // Return the function selector, new BeforeSwapDelta, and zero fees
        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(int128(amount), 0),
            0
        );
    }

    // The swapParams to conduct a swap
    /**
     struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
    */

    function _limitOrder(
        PoolKey calldata key, // The pool key
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData // The hook data
    ) internal returns (uint128 amountDelta) {
        if (hookData.length == 0) return 0;

        // @audit-info "The user specifiy the amount of tokens to swapped
        // using limit order?

        (
            uint256 limitPrice,
            uint256 amount,
            address recipient,
            bool isMaker,
            uint32 n
        ) = abi.decode(hookData, (uint256, uint256, address, bool, uint32));

        // TODO: check if amount is bigger than delta, if it is, return delta
        // Take tokens out of PM to our hook contract

        _take(
            swapParams.zeroForOne ? key.currency0 : key.currency1,
            uint128(amount)
        );

        _trade(
            Currency.unwrap(key.currency0), // ETH
            Currency.unwrap(key.currency1), // Tokens
            swapParams.zeroForOne,
            limitPrice,
            amount,
            isMaker,
            n,
            recipient
        );
        return uint128(amount);
    }

    function getHookData(
        uint256 limitPrice,
        uint256 amount,
        address recipient,
        bool isMaker,
        uint32 n
    ) public pure returns (bytes memory) {
        return abi.encode(limitPrice, amount, recipient, isMaker, n);
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        currency.transfer(address(poolManager), amount);
        poolManager.settle(); // Check this out
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        // What is the "take function"
        poolManager.take(currency, address(this), amount);
    }

    function _trade(
        address token0,
        address token1,
        bool zeroForOne,
        uint256 limitPrice,
        uint256 amount,
        bool isMaker,
        uint32 n,
        address recipient
    ) internal returns (uint256 total) {
        if (zeroForOne) {
            if (token0 == address(0)) {
                IEngine(payable(matchingEngine)).limitSellETH{value: amount}(
                    token1,
                    limitPrice,
                    isMaker,
                    n,
                    recipient
                );
                return amount;
            }
            // else
            IERC20(token0).approve(matchingEngine, amount);

            (uint makePrice, uint placed, uint id) = IEngine(matchingEngine)
                .limitSell(
                    token0 == address(0) ? weth : token0,
                    token1 == address(0) ? weth : token1,
                    limitPrice,
                    amount,
                    isMaker,
                    n,
                    recipient
                );
            return amount;
        } else {
            if (token1 == address(0)) {
                IEngine(payable(matchingEngine)).limitBuyETH{value: amount}(
                    token0,
                    limitPrice,
                    isMaker,
                    n,
                    recipient
                );
                return amount;
            }
            IERC20(token1).approve(matchingEngine, amount);
            IEngine(matchingEngine).limitBuy(
                token0 == address(0) ? weth : token0,
                token1 == address(0) ? weth : token1,
                limitPrice,
                amount,
                isMaker,
                n,
                recipient
            );
            return amount;
        }
    }

    receive() external payable {
        // You can add any custom logic here if needed
    }

    // Before Swap Hooks
    /// hookData Any data to pass to the callback, via `IUnlockCallback(msg.sender).unlockCallback(data)`
}
