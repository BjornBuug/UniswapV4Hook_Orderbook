// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IEngine} from "@standardweb3/exchange/interfaces/IEngine.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin/contracts/token/erc20/IERC20.sol";

// TODO:
// [] MAke the hook ERC1155 to mint for the user a receipt when they placed order
// {] burn it when they redemmed or canceled it.
// [] Create redeem function, cancel function.

contract OrderBookHookV4 is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using CurrencyLibrary for Currency;

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

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // true
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

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

    // function getHookData(
    //     uint256 limitPrice,
    //     uint256 amount,
    //     address recipient,
    //     bool isMaker,
    //     uint32 n
    // ) public pure returns (bytes memory) {
    //     return abi.encode(limitPrice, amount, recipient, isMaker, n);
    // }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata orderHookData
    ) external override returns (bytes4, int128) {
        // Check if the orderOrderHookData is not empty [x]
        if (orderHookData.length == 0) return (BaseHook.afterSwap.selector, 0);

        // Decode the the orderHook data to retrive te order details
        (
            uint256 limitPrice,
            uint256 amount,
            address recipient,
            bool isMaker,
            uint32 n
        ) = abi.decode(
                orderHookData,
                (uint256, uint256, address, bool, uint32)
            );

        // Create a function to to match the order

        // Calculate the delta for the unspecified currency

        return (BaseHook.afterSwap.selector, 0);
    }

    /**
        struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    } */

    // Returns the matched Amount, and output
    function _matchOrder(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        uint256 limitPrice,
        uint256 amount,
        address recipient,
        bool isMaker,
        uint32 n
    ) private returns (uint256 matchedAmount, uint256 outputAmount) {
        // Determine which tokens is being traded [x]
        address tokenIn = swapParams.zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        address tokenOut = swapParams.zeroForOne
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
    }

    // TODO Modifier where only poolManager can call this beforeSwap.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata orderHookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (orderHookData.length == 0)
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        uint128 amount = _limitOrder(key, swapParams, orderHookData);
        // TODO: Add mint for the user to mintERC1155 as receipt

        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(int128(amount), 0), // ?? check this back if it reverts
            0
        );
    }

    // function that allow the limit trade to be executed using orderHookData
    function _limitOrder(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata orderHookData
    ) internal returns (uint128 amountDelta) {
        // =>if the orderHookData is empy
        // return 0
        if (orderHookData.length == 0) return 0;

        (
            uint256 limitPrice,
            uint256 amount,
            address recipient,
            bool isMaker,
            uint32 n
        ) = abi.decode(
                orderHookData,
                (uint256, uint256, address, bool, uint32)
            );

        // Tranfer 0.001 ETH deposited by user from the poolManager to HookContract
        _take(
            swapParams.zeroForOne ? key.currency0 : key.currency1,
            uint128(amount)
        );

        // TODO: Change the bellow Currency to be dynamic
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

    // Transfer the user's deposited tokens from the PoolManager to be sold
    // as part of a limit order
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
            // Selling token0 for token1
            if (token0 == address(0)) {
                // If token0 is ETH (address 0), use limitSellETH
                IEngine(payable(matchingEngine)).limitSellETH{value: amount}(
                    token1, // Token to buy
                    limitPrice,
                    isMaker, // at limit price
                    n, // The maximum number of orders to match in the orderbook
                    recipient
                );
                return amount;
            }

            // If token0 is not ETH, approve and use limitSell
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
            // Buying token0 with token1
            if (token1 == address(0)) {
                // If token1 is ETH (address 0), use limitBuyETH
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

    receive() external payable {}
}
