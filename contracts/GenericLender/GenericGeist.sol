// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../Interfaces/UniswapInterfaces/IUniswapV2Router02.sol";

import "./GenericLenderBase.sol";
import "../Interfaces/Aave/IAToken.sol";
import "../Interfaces/Aave/IStakedAave.sol";
import "../Interfaces/Aave/ILendingPool.sol";
import "../Interfaces/Aave/IProtocolDataProvider.sol";
import "../Interfaces/Aave/IAaveIncentivesController.sol";
import "../Interfaces/Aave/IReserveInterestRateStrategy.sol";
import "../Libraries/Aave/DataTypes.sol";

import "../interfaces/geist/IGeistIncentivesController.sol";
import "../interfaces/geist/IMultiFeeDistribution.sol";

contract GenericGeist is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IProtocolDataProvider public constant protocolDataProvider =
        IProtocolDataProvider(0xf3B0611e2E4D2cd6aB4bb3e01aDe211c3f42A8C3);
    IGeistIncentivesController private constant incentivesController =
        IGeistIncentivesController(0x297FddC5c33Ef988dd03bd13e162aE084ea1fE57);
    ILendingPool private constant lendingPool =
        ILendingPool(0x9FAD24f572045c7869117160A571B2e50b10d068);

    IAToken public aToken;

    address public keeper;

    uint16 internal constant DEFAULT_REFERRAL = 0; 
    uint16 internal customReferral;

    address public constant WETH =
        address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    address public constant GEIST =
        address(0xd8321AA83Fb0a4ECd6348D4577431310A6E0814d);

    IUniswapV2Router02 public constant router =
        IUniswapV2Router02(address(0xF491e7B69E4244ad4002BC14e878a34207E38c29));

    uint256 constant internal SECONDS_IN_YEAR = 365 days;
    uint256 constant MAX_BPS = 10_000;
    uint256 public minRewardToSell;

    constructor(
        address _strategy,
        string memory name,
        IAToken _aToken,
        bool _isIncentivised
    ) public GenericLenderBase(_strategy, name) {
        _initialize(_aToken);
    }

    function initialize(IAToken _aToken) external {
        _initialize(_aToken);
    }

    function cloneGeistLender(
        address _strategy,
        string memory _name,
        IAToken _aToken
    ) external returns (address newLender) {
        newLender = _clone(_strategy, _name);
        GenericGeist(newLender).initialize(_aToken);
    }

    function setReferralCode(uint16 _customReferral) external management {
        customReferral = _customReferral;
    }

    function setKeeper(address _keeper) external management {
        keeper = _keeper;
    }

    function withdraw(uint256 amount) external override management returns (uint256) {
        return _withdraw(amount);
    }

    //emergency withdraw. sends balance plus amount to governance
    function emergencyWithdraw(uint256 amount) external override onlyGovernance {
        lendingPool.withdraw(address(want), amount, address(this));

        want.safeTransfer(vault.governance(), want.balanceOf(address(this)));
    }

    function deposit() external override management {
        uint256 balance = want.balanceOf(address(this));
        _deposit(balance);
    }

    function withdrawAll() external override management returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function nav() external view override returns (uint256) {
        return _nav();
    }

    function underlyingBalanceStored() public view returns (uint256 balance) {
        balance = aToken.balanceOf(address(this));
    }

    function apr() external view override returns (uint256) {
        return _apr();
    }

    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a.mul(_nav());
    }


    // TODO : calculate this and uncomment in estimations
    // calculates APR from Liquidity Mining Program
//    function _incentivesRate(uint256 totalLiquidity) public view returns (uint256) {
//        // only returns != 0 if the incentives are in place at the moment.
//        // it will fail if the isIncentivised is set to true but there is no incentives
//        if(isIncentivised && block.timestamp < _incentivesController().getDistributionEnd()) {
//            uint256 _emissionsPerSecond;
//            (, _emissionsPerSecond, ) = _incentivesController().getAssetData(address(aToken));
//            if(_emissionsPerSecond > 0) {
//                uint256 emissionsInWant = _AAVEtoWant(_emissionsPerSecond); // amount of emissions in want
//
//                uint256 incentivesRate = emissionsInWant.mul(SECONDS_IN_YEAR).mul(1e18).div(totalLiquidity); // APRs are in 1e18
//
//                return incentivesRate.mul(9_500).div(10_000); // 95% of estimated APR to avoid overestimations
//            }
//        }
//        return 0;
//    }
//
    function aprAfterDeposit(uint256 extraAmount) external view override returns (uint256) {
        // i need to calculate new supplyRate after Deposit (when deposit has not been done yet)
        DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(address(want));

        (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, , , , uint256 averageStableBorrowRate, , , ) =
            protocolDataProvider.getReserveData(address(want));

        uint256 newLiquidity = availableLiquidity.add(extraAmount);

        (, , , , uint256 reserveFactor, , , , , ) = protocolDataProvider.getReserveConfigurationData(address(want));

        (uint256 newLiquidityRate, , ) =
            IReserveInterestRateStrategy(reserveData.interestRateStrategyAddress).calculateInterestRates(
                address(want),
                newLiquidity,
                totalStableDebt,
                totalVariableDebt,
                averageStableBorrowRate,
                reserveFactor
            );

        return newLiquidityRate.div(1e9);

//
//        uint256 incentivesRate = _incentivesRate(newLiquidity.add(totalStableDebt).add(totalVariableDebt)); // total supplied liquidity in Aave v2
//        return newLiquidityRate.div(1e9).add(incentivesRate); // divided by 1e9 to go from Ray to Wad
    }

    function hasAssets() external view override returns (bool) {
        return aToken.balanceOf(address(this)) > 0;
    }

    // Only for incentivised aTokens
    // this is a manual trigger to claim rewards once each 10 days
    // only callable if the token is incentivised by Aave Governance (_checkCooldown returns true)
    function harvest() external keepers{
        _claimAndSellRewards();

        // deposit want in lending protocol
        uint256 balance = want.balanceOf(address(this));
        if(balance > 0) {
            _deposit(balance);
        }
    }

    function _claimAndSellRewards() internal returns (uint256) {
        IGeistIncentivesController _incentivesController = incentivesController;

        _incentivesController.claim(address(this), getAssets());

        // Exit with 50% penalty
        IMultiFeeDistribution(_incentivesController.rewardMinter()).exit();

        // sell reward for want
        uint256 rewardBalance = balanceOfReward();
        if (rewardBalance >= minRewardToSell) {
            _sellRewardForWant(rewardBalance);
        }
    }

    function balanceOfReward() internal view returns (uint256) {
        return IERC20(GEIST).balanceOf(address(this));
    }

    function estimatedRewardsInWant() public view returns (uint256) {
        uint256 rewardBalance = 0;

        uint256[] memory rewards = incentivesController.claimableReward(
            address(this),
            getAssets()
        );
        for (uint8 i = 0; i < rewards.length; i++) {
            rewardBalance += rewards[i];
        }

        rewardBalance = rewardBalance.mul(5000).div(MAX_BPS);
        rewardBalance += balanceOfReward();

        return rewardToWant(rewardBalance);
    }

    function getAssets() internal view returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = address(aToken);
    }

    function harvestTrigger(uint256 callcost) external view returns (bool) {
        // TODO: replace with amount to sell
        // return _checkCooldown();
    }

    function _initialize(IAToken _aToken) internal {
        require(address(aToken) == address(0), "GenericAave already initialized");

        aToken = _aToken;
        require(lendingPool.getReserveData(address(want)).aTokenAddress == address(_aToken), "WRONG ATOKEN");
        IERC20(address(want)).safeApprove(address(lendingPool), type(uint256).max);
    }

    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)).add(underlyingBalanceStored());
    }

    function _apr() internal view returns (uint256) {
        uint256 liquidityRate = uint256(lendingPool.getReserveData(address(want)).currentLiquidityRate).div(1e9);// dividing by 1e9 to pass from ray to wad
        (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, , , , , , , ) =
                    protocolDataProvider.getReserveData(address(want));
        return liquidityRate;
        // uint256 incentivesRate = _incentivesRate(availableLiquidity.add(totalStableDebt).add(totalVariableDebt)); // total supplied liquidity in Aave v2
        // return liquidityRate.add(incentivesRate);
    }

    //withdraw an amount including any want balance
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = aToken.balanceOf(address(this));
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying.add(looseBalance);

        if (amount > total) {
            //cant withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        //not state changing but OK because of previous call
        uint256 liquidity = want.balanceOf(address(aToken));

        if (liquidity > 1) {
            uint256 toWithdraw = amount.sub(looseBalance);

            if (toWithdraw <= liquidity) {
                //we can take all
                lendingPool.withdraw(address(want), toWithdraw, address(this));
            } else {
                //take all we can
                lendingPool.withdraw(address(want), liquidity, address(this));
            }
        }
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    function _deposit(uint256 amount) internal {
        ILendingPool lp = lendingPool;
        // NOTE: check if allowance is enough and acts accordingly
        // allowance might not be enough if
        //     i) initial allowance has been used (should take years)
        //     ii) lendingPool contract address has changed (Aave updated the contract address)
        if(want.allowance(address(this), address(lp)) < amount){
            IERC20(address(want)).safeApprove(address(lp), 0);
            IERC20(address(want)).safeApprove(address(lp), type(uint256).max);
        }

        uint16 referral;
        uint16 _customReferral = customReferral;
        if(_customReferral != 0) {
            referral = _customReferral;
        } else {
            referral = DEFAULT_REFERRAL;
        }

        lp.deposit(address(want), amount, address(this), referral);
    }

    function rewardToWant(uint256 _amount) internal view returns (uint256) {
        if(_amount == 0) {
            return 0;
        }

        address[] memory path;

        if(address(want) == address(WETH)) {
            path = new address[](2);
            path[0] = address(GEIST);
            path[1] = address(want);
        } else {
            path = new address[](3);
            path[0] = address(GEIST);
            path[1] = address(WETH);
            path[2] = address(want);
        }

        uint256[] memory amounts = router.getAmountsOut(_amount, path);
        return amounts[amounts.length - 1];
    }

    function _sellRewardForWant(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        address[] memory path;

        if(address(want) == address(WETH)) {
            path = new address[](2);
            path[0] = address(GEIST);
            path[1] = address(want);
        } else {
            path = new address[](3);
            path[0] = address(GEIST);
            path[1] = address(WETH);
            path[2] = address(want);
        }

        if(IERC20(GEIST).allowance(address(this), address(router)) < _amount) {
            IERC20(GEIST).safeApprove(address(router), 0);
            IERC20(GEIST).safeApprove(address(router), type(uint256).max);
        }

        router.swapExactTokensForTokens(
            _amount,
            0,
            path,
            address(this),
            now
        );
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = address(aToken);
        return protected;
    }

    modifier keepers() {
        require(
            msg.sender == address(keeper) || msg.sender == address(strategy) || msg.sender == vault.governance() || msg.sender == IBaseStrategy(strategy).management(),
            "!keepers"
        );
        _;
    }
}
