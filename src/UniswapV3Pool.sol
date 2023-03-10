// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3FlashCallback.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";

import "./lib/LiquidityMath.sol";
import "./lib/Math.sol";
import "./lib/Position.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";
import "prb-math/PRBMath.sol";
import "./lib/FixedPoint128.sol";
import "./lib/Oracle.sol";

contract UniswapV3Pool is IUniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    error InsufficientInputAmount();
    error InvalidPriceLimit();
    error InvalidTickRange();
    error NotEnoughLiquidity();
    error ZeroLiquidity();
    error AlreadyInitialized();
    error FlashLoanNotPaid();

    // 移除流动性事件
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    // 回收事件
    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    // 闪电贷事件
    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);
    // 添加激活观测点
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );
    // 添加流动性
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    // 交换token
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    // 工厂地址，token0，token1，tickSpacing初始化参数
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable tickSpacing;
    uint24 public immutable fee; // 费率
    // 跟踪token0的单位费用累计值 totalFee/totalLiquidity
    uint256 public feeGrowthGlobal0X128;
    // 跟踪token1的单位费用累计值 totalFee/totalLiquidity
    uint256 public feeGrowthGlobal1X128;

    struct Slot0 {
        // 当前价格
        uint160 sqrtPriceX96;
        // 当前价格对应的tick
        int24 tick;
        // 记录最新的观测的编号index
        uint16 observationIndex;
        // 记录活跃的观测数量，也就是length。初始化时,观测数量=可扩展数量，表示不能扩展
        // 保持数组中的活跃可观测点始终在[0,observationCardinality)范围中
        uint16 observationCardinality;
        // 记录观测数组能够扩展到的下一个基数大小，默认为1
        // 需要用户消耗gas来扩展
        uint16 observationCardinalityNext;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining; // 用户剩余的输入
        uint256 amountCalculated; // pool计算的输出
        uint160 sqrtPriceX96; // 当前价格
        int24 tick; // 当前tick
        uint256 feeGrowthGlobalX128; // 累计的单位交易费
        uint128 liquidity; // 当前liquidity
    }

    struct StepState {
        uint160 sqrtPriceStartX96; // 开始价格
        int24 nextTick; // 下一个价格
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    Slot0 public slot0;

    // 当前价格区间的总的liquidity
    uint128 public liquidity;

    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => Position.Info) public positions;
    Oracle.Observation[65535] public observations;

    constructor() {
        (factory, token0, token1, tickSpacing, fee) = IUniswapV3PoolDeployer(
            msg.sender
        ).parameters();
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
         (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(
            _blockTimestamp()
        );
         slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });
    }

    struct ModifyPositionParams {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPositionParams memory params)
        internal
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        Slot0 memory slot0_ = slot0;
        uint256 feeGrowthGlobal0X128_ = feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128_ = feeGrowthGlobal1X128;

        // 记录该用户的流动性
        position = positions.get(
            params.owner,
            params.lowerTick,
            params.upperTick
        );

        bool flippedLower = ticks.update(
            params.lowerTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            false
        );
        bool flippedUpper = ticks.update(
            params.upperTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            true
        );

        // 将lower和upper放入到bitMap中
        if (flippedLower) {
            tickBitmap.flipTick(params.lowerTick, int24(tickSpacing));
        }

        if (flippedUpper) {
            tickBitmap.flipTick(params.upperTick, int24(tickSpacing));
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks
            .getFeeGrowthInside(
                params.lowerTick,
                params.upperTick,
                slot0_.tick,
                feeGrowthGlobal0X128_,
                feeGrowthGlobal1X128_
            );

        position.update(
            params.liquidityDelta,
            feeGrowthInside0X128,
            feeGrowthInside1X128
        );
        // 只有价格区间包含当前价格的时候才把流动性添加到当前价格中
        if (slot0_.tick < params.lowerTick) {
            // 当价格区间高于当前价格时，只需要token0，x
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        } else if (slot0_.tick < params.upperTick) {
            // 这里根据用户投入到liquidity，重新计算一下用户需要投入多少token0和token1
            amount0 = Math.calcAmount0Delta(
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );

            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                slot0_.sqrtPriceX96,
                params.liquidityDelta
            );

            liquidity = LiquidityMath.addLiquidity(
                liquidity,
                params.liquidityDelta
            );
        } else {
            // 当价格区间低于当前价格时，只需要token1，y
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        }
    }

    function mint(
        address owner,
        // 价格区间
        int24 lowerTick,
        int24 upperTick,
        // 用户投入到liquidity
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < TickMath.MIN_TICK ||
            upperTick > TickMath.MAX_TICK
        ) revert InvalidTickRange();

        if (amount == 0) revert ZeroLiquidity();
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: int128(amount)
            })
        );
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        // 检查用户是否如期转账token0和token1
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();

        emit Mint(
            msg.sender,
            owner,
            lowerTick,
            upperTick,
            amount,
            amount0,
            amount1
        );
    }
    // 移除流动性
    function burn(
        int24 lowerTick,
        int24 upperTick,
        uint128 amount // 想要移除的流动性
    ) public returns (uint256 amount0, uint256 amount1) {
        (
            Position.Info storage position,
            int256 amount0Int,
            int256 amount1Int
        ) = _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    // 一个反向更新liquidity操作进行扣除，就是burn
                    liquidityDelta: -(int128(amount))
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);
        // 将用户应得的token和收费进行相加
        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, lowerTick, upperTick, amount, amount0, amount1);
    }
    // 提取用户的token
    function collect(
        address recipient,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(
            msg.sender,
            lowerTick,
            upperTick
        );

        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;
        // 从用户的position中提取两种token
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(token0).transfer(recipient, amount0);
        }

        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(token1).transfer(recipient, amount1);
        }

        emit Collect(
            msg.sender,
            recipient,
            lowerTick,
            upperTick,
            amount0,
            amount1
        );
    }

    function swap(
        address recipient,
        bool zeroForOne, // zero=false输出token0,输入token1。one=true输出token1,输入token0。根据公式 p = y/x: 当输出x的时候价格上涨，输出y的时候价格下降
        uint256 amountSpecified, // 与输出token对应的，用户需要投入的多少token
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;
        // 滑点保护
        if (
            zeroForOne // 当输出token1时，价格下降，但是不能小于limit
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 ||
                    sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO // 当输出token0时，价格上涨，但是不能超过limit
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 ||
                    sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
            liquidity: liquidity_
        });
        // 找到新的next price 对应的tick。
        while (
            state.amountSpecifiedRemaining > 0 &&
            // 当没有next tick的时候，这时不能超过最大，只有部分进行来交易。
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // 根据当前价格，以及换出的方向，在bitmap中寻找下一个tick。
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                int24(tickSpacing),
                zeroForOne
            );

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            // 根据找到的tick获取计算下一个真正的tick和两种token数量
            // 因为找的都是边界tick， next price可能还在边界中，所以需要重新计算一下。
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                // 滑点保护，防止价格下跌或上涨不超过limit
                (
                    zeroForOne
                        ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                )
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );
            // 减去用户可以输入到pool中的对应token数量和手续费用
            state.amountSpecifiedRemaining -= step.amountIn + step.feeAmount;
            // 加上pool给用户的输出token数量
            state.amountCalculated += step.amountOut;
            if (state.liquidity > 0) {
                // 增加全局单位费用 += deltaFee/L
                state.feeGrowthGlobalX128 += PRBMath.mulDiv(
                    step.feeAmount,
                    FixedPoint128.Q128,
                    state.liquidity
                );
            }
            // 检查是否跨price区间了
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                int128 liquidityDelta = ticks.cross(
                    step.nextTick,
                    (
                        zeroForOne
                            ? state.feeGrowthGlobalX128
                            : feeGrowthGlobal0X128
                    ),
                    (
                        zeroForOne
                            ? feeGrowthGlobal1X128
                            : state.feeGrowthGlobalX128
                    )
                );
                // 当价格按从lower => upper方向移动时，当价格从下面区间进入到上面区间的lower时:
                //     将下面区间的流动性扣除，并加上当前新区间的流动性,当穿过该区间的upper时减少对应的流动性
                // 当价格按从upper => lower方向移动时，当价格从上面区间进入到下面区间的upper时:
                //     将上面区间的流动性扣除，并加上当前新区间的流动性，当穿过该区间的lower时减少对应的流动性
                if (zeroForOne) liquidityDelta = -liquidityDelta;

                state.liquidity = LiquidityMath.addLiquidity(
                    state.liquidity,
                    liquidityDelta
                );
                // 当到达极限边界时，没有流动性了。此时交易只能部分成交
                if (state.liquidity == 0) revert NotEnoughLiquidity();
                // 开闭区间问题 左闭右开，如果穿过下界到下一个区间需要减一
                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
        // 更新当前tick到next tick
        if (state.tick != slot0_.tick) {
            (
                uint16 observationIndex,
                uint16 observationCardinality
                // 当现价改变时，一个观测会写入到数组中
            ) = observations.write(
                    slot0_.observationIndex,
                    _blockTimestamp(),
                    // 使用之前到tick，防止价格操控，用这个区块第一笔交易之前到价格
                    slot0_.tick,
                    slot0_.observationCardinality,
                    slot0_.observationCardinalityNext
                );

            (
                slot0.sqrtPriceX96,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            ) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }
        // 更新流动性
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;
        // 更新输入的token的单位费用累计值
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }
        (amount0, amount1) = zeroForOne // 转给用户token1，用户转给pool token0
            ? (
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            ) // 转给用户token0，用户转给pool token1
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );
        if (zeroForOne) {
            // 转给用户token1
            IERC20(token1).transfer(recipient, uint256(-amount1));
            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            // 用户转给pool token0
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            // 转给用户token0
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            // 用户转给pool token1
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            state.liquidity,
            slot0.tick
        );
    }

    // 闪电贷
    function flash(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        // 根据token请求的数量收取费用
        uint256 fee0 = Math.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = Math.mulDivRoundingUp(amount1, fee, 1e6);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(
            fee0,
            fee1,
            data
        );

        if (IERC20(token0).balanceOf(address(this)) < balance0Before + fee0)
            revert FlashLoanNotPaid();
        if (IERC20(token1).balanceOf(address(this)) < balance1Before + fee1)
            revert FlashLoanNotPaid();

        emit Flash(msg.sender, amount0, amount1);
    }
    // 给定一组时间点获取对应观测值
    function observe(uint32[] calldata secondsAgos)
        public
        view
        returns (int56[] memory tickCumulatives)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            );
    }
    // 扩展池子中可观测的基数
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) public {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );

        if (observationCardinalityNextNew != observationCardinalityNextOld) {
            slot0.observationCardinalityNext = observationCardinalityNextNew;
            emit IncreaseObservationCardinalityNext(
                observationCardinalityNextOld,
                observationCardinalityNextNew
            );
        }
    }
    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
    function _blockTimestamp() internal view returns (uint32 timestamp) {
        timestamp = uint32(block.timestamp);
    }
}
