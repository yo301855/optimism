// SPDX-License-Identifier: MIT
// @unsupported: ovm
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import "./interfaces/iL2LiquidityPool.sol";
import "../libraries/OVM_CrossDomainEnabledFast.sol";

/* External Imports */
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @dev An L1 LiquidityPool implementation
 */
contract L1LiquidityPool is OVM_CrossDomainEnabledFast, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /**************
     *   Struct   *
     **************/
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 pendingReward; // Pending reward
        //
        // We do some fancy math here. Basically, any point in time, the amount of rewards
        // entitled to a user but is pending to be distributed is:
        //
        //   Update Reward Per Share:
        //   accUserRewardPerShare = accUserRewardPerShare + (accUserReward - lastAccUserReward) / userDepositAmount
        //
        //  LP Provider:
        //      Deposit:
        //          Case 1 (new user):
        //              Update Reward Per Share();
        //              Calculate user.rewardDebt = amount * accUserRewardPerShare;
        //          Case 2 (user who has already deposited add more funds):
        //              Update Reward Per Share();
        //              Calculate user.pendingReward = amount * accUserRewardPerShare - user.rewardDebt;
        //              Calculate user.rewardDebt = (amount + new_amount) * accUserRewardPerShare;
        //
        //      Withdraw
        //          Update Reward Per Share();
        //          Calculate user.pendingReward = amount * accUserRewardPerShare - user.rewardDebt;
        //          Calculate user.rewardDebt = (amount - withdraw_amount) * accUserRewardPerShare;
    }
    // Info of each pool.
    struct PoolInfo {
        address l1TokenAddress; // Address of token contract.
        address l2TokenAddress; // Address of toekn contract.

        // balance
        uint256 userDepositAmount; // user deposit amount;

        // user rewards
        uint256 lastAccUserReward; // Last accumulated user reward
        uint256 accUserReward; // Accumulated user reward.
        uint256 accUserRewardPerShare; // Accumulated user rewards per share, times 1e12. See below.

        // owner rewards
        uint256 accOwnerReward; // Accumulated owner reward.

        // start time -- used to calculate APR
        uint256 startTime;
    }

    /*************
     * Variables *
     *************/

    // mapping L1 and L2 token address to poolInfo
    mapping(address => PoolInfo) public poolInfo;
    // Info of each user that stakes tokens.
    mapping(address => mapping(address => UserInfo)) public userInfo;

    address public owner;
    address public L2LiquidityPoolAddress;
    uint256 public userRewardFeeRate;
    uint256 public ownerRewardFeeRate;
    // Default gas value which can be overridden if more complex logic runs on L2.
    uint32 public SETTLEMENT_L2_GAS;
    uint256 public SAFE_GAS_STIPEND;
    // cdm address
    address public l1CrossDomainMessenger;

    /********************
     *       Events     *
     ********************/

    event AddLiquidity(
        address sender,
        uint256 amount,
        address tokenAddress
    );

    event OwnerRecoverFee(
        address sender,
        address receiver,
        uint256 amount,
        address tokenAddress
    );

    event ClientDepositL1(
        address sender,
        uint256 receivedAmount,
        address tokenAddress
    );

    event ClientPayL1(
        address sender,
        uint256 amount,
        uint256 userRewardFee,
        uint256 ownerRewardFee,
        uint256 totalFee,
        address tokenAddress
    );

    event ClientPayL1Settlement(
        address sender,
        uint256 amount,
        uint256 userRewardFee,
        uint256 ownerRewardFee,
        uint256 totalFee,
        address tokenAddress
    );

    event WithdrawLiquidity(
        address sender,
        address receiver,
        uint256 amount,
        address tokenAddress
    );

    event WithdrawReward(
        address sender,
        address receiver,
        uint256 amount,
        address tokenAddress
    );

    /********************
     *    Constructor   *
     ********************/

    constructor()
        OVM_CrossDomainEnabledFast(address(0), address(0))
    {}

    /**********************
     * Function Modifiers *
     **********************/

    modifier onlyOwner() {
        require(msg.sender == owner || owner == address(0), 'caller is not the owner');
        _;
    }

    modifier onlyNotInitialized() {
        require(address(L2LiquidityPoolAddress) == address(0), "Contract has been initialized");
        _;
    }

    modifier onlyInitialized() {
        require(address(L2LiquidityPoolAddress) != address(0), "Contract has not yet been initialized");
        _;
    }


    /********************
     * Public Functions *
     ********************/

    /**
     * @dev transfer ownership
     *
     * @param _newOwner new owner of this contract
     */
    function transferOwnership(
        address _newOwner
    )
        public
        onlyOwner()
    {
        owner = _newOwner;
    }

    /**
     * @dev Initialize this contract.
     *
     * @param _l1CrossDomainMessenger L1 Messenger address being used for sending the cross-chain message.
     * @param _l1CrossDomainMessengerFast L1 Messenger address being used for relaying cross-chain messages quickly.
     * @param _L2LiquidityPoolAddress Address of the corresponding L2 LP deployed to the L2 chain
     */
    function initialize(
        address _l1CrossDomainMessenger,
        address _l1CrossDomainMessengerFast,
        address _L2LiquidityPoolAddress
    )
        public
        onlyOwner()
        onlyNotInitialized()
        initializer()
    {
        require(_l1CrossDomainMessenger != address(0) && _l1CrossDomainMessengerFast != address(0) && _L2LiquidityPoolAddress != address(0), "zero address not allowed");
        senderMessenger = _l1CrossDomainMessenger;
        relayerMessenger = _l1CrossDomainMessengerFast;
        L2LiquidityPoolAddress = _L2LiquidityPoolAddress;
        owner = msg.sender;
        configureFee(35, 15);
        configureGas(1400000, 2300);

        __Context_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();

    }

    /**
     * @dev Configure fee of this contract.
     *
     * @param _userRewardFeeRate fee rate that users get
     * @param _ownerRewardFeeRate fee rate that contract owner gets
     */
    function configureFee(
        uint256 _userRewardFeeRate,
        uint256 _ownerRewardFeeRate
    )
        public
        onlyOwner()
        onlyInitialized()
    {
        userRewardFeeRate = _userRewardFeeRate;
        ownerRewardFeeRate = _ownerRewardFeeRate;
    }

    /**
     * @dev Configure gas.
     *
     * @param _l2GasFee default finalized deposit L2 Gas
     * @param _safeGas safe gas stipened
     */
    function configureGas(
        uint32 _l2GasFee,
        uint256 _safeGas
    )
        public
        onlyOwner()
        onlyInitialized()
    {
        SETTLEMENT_L2_GAS = _l2GasFee;
        SAFE_GAS_STIPEND = _safeGas;
    }

    /***
     * @dev Add the new token pair to the pool
     * DO NOT add the same LP token more than once. Rewards will be messed up if you do.
     *
     * @param _l1TokenAddress
     * @param _l2TokenAddress
     *
     */
    function registerPool(
        address _l1TokenAddress,
        address _l2TokenAddress
    )
        public
        onlyOwner()
    {
        require(_l1TokenAddress != _l2TokenAddress, "l1 and l2 token addresses cannot be same");
        // use with caution, can register only once
        PoolInfo storage pool = poolInfo[_l1TokenAddress];
        // l2 token address equal to zero, then pair is not registered.
        require(pool.l2TokenAddress == address(0), "Token Address Already Registered");
        poolInfo[_l1TokenAddress] =
            PoolInfo({
                l1TokenAddress: _l1TokenAddress,
                l2TokenAddress: _l2TokenAddress,
                userDepositAmount: 0,
                lastAccUserReward: 0,
                accUserReward: 0,
                accUserRewardPerShare: 0,
                accOwnerReward: 0,
                startTime: block.timestamp
            });
    }

    /**
     * Update the user reward per share
     * @param _tokenAddress Address of the target token.
     */
    function updateUserRewardPerShare(
        address _tokenAddress
    )
        public
    {
        PoolInfo storage pool = poolInfo[_tokenAddress];
        if (pool.lastAccUserReward < pool.accUserReward) {
            uint256 accUserRewardDiff = (pool.accUserReward.sub(pool.lastAccUserReward));
            if (pool.userDepositAmount != 0) {
                pool.accUserRewardPerShare = pool.accUserRewardPerShare.add(
                    accUserRewardDiff.mul(1e12).div(pool.userDepositAmount)
                );
            }
            pool.lastAccUserReward = pool.accUserReward;
        }
    }

    /**
     * Liquididity providers add liquidity
     * @param _amount liquidity amount that users want to deposit.
     * @param _tokenAddress address of the liquidity token.
     */
     function addLiquidity(
        uint256 _amount,
        address _tokenAddress
    )
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(msg.value != 0 || _tokenAddress != address(0), "Amount Incorrect");
        // check whether user sends ETH or ERC20
        if (msg.value != 0) {
            // override the _amount and token address
            _amount = msg.value;
            _tokenAddress = address(0);
        }

        PoolInfo storage pool = poolInfo[_tokenAddress];
        UserInfo storage user = userInfo[_tokenAddress][msg.sender];

        require(pool.l2TokenAddress != address(0), "Token Address Not Register");

        // Update accUserRewardPerShare
        updateUserRewardPerShare(_tokenAddress);

        // if the user has already deposited token, we move the rewards to
        // pendingReward and update the reward debet.
        if (user.amount > 0) {
            user.pendingReward = user.pendingReward.add(
                user.amount.mul(pool.accUserRewardPerShare).div(1e12).sub(user.rewardDebt)
            );
            user.rewardDebt = (user.amount.add(_amount)).mul(pool.accUserRewardPerShare).div(1e12);
        } else {
            user.rewardDebt = _amount.mul(pool.accUserRewardPerShare).div(1e12);
        }

        // transfer funds if users deposit ERC20
        if (_tokenAddress != address(0)) {
            IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }

        // update amounts
        user.amount = user.amount.add(_amount);
        pool.userDepositAmount = pool.userDepositAmount.add(_amount);

        emit AddLiquidity(
            msg.sender,
            _amount,
            _tokenAddress
        );
    }

    /**
     * Client deposit ERC20 from their account to this contract, which then releases funds on the L2 side
     * @param _amount amount that client wants to transfer.
     * @param _tokenAddress L2 token address
     */
    function clientDepositL1(
        uint256 _amount,
        address _tokenAddress
    )
        external
        payable
        whenNotPaused
    {
        require(msg.value != 0 || _tokenAddress != address(0), "Amount Incorrect");
        // check whether user sends ETH or ERC20
        if (msg.value != 0) {
            // override the _amount and token address
            _amount = msg.value;
            _tokenAddress = address(0);
        }

        PoolInfo storage pool = poolInfo[_tokenAddress];

        require(pool.l2TokenAddress != address(0), "Token Address Not Register");

        // transfer funds if users deposit ERC20
        if (_tokenAddress != address(0)) {
            IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }

        // Construct calldata for L1LiquidityPool.depositToFinalize(_to, receivedAmount)
        bytes memory data = abi.encodeWithSelector(
            iL2LiquidityPool.clientPayL2.selector,
            msg.sender,
            _amount,
            pool.l2TokenAddress
        );

        // Send calldata into L1
        sendCrossDomainMessage(
            address(L2LiquidityPoolAddress),
            // extra gas for complex l2 logic
            SETTLEMENT_L2_GAS,
            data
        );

        emit ClientDepositL1(
            msg.sender,
            _amount,
            _tokenAddress
        );
    }

    /**
     * Users withdraw token from LP
     * @param _amount amount to withdraw
     * @param _tokenAddress L1 token address
     * @param _to receiver to get the funds
     */
    function withdrawLiquidity(
        uint256 _amount,
        address _tokenAddress,
        address payable _to
    )
        external
        whenNotPaused
    {
        PoolInfo storage pool = poolInfo[_tokenAddress];
        UserInfo storage user = userInfo[_tokenAddress][msg.sender];

        require(pool.l2TokenAddress != address(0), "Token Address Not Register");
        require(user.amount >= _amount, "Withdraw Error");

        // Update accUserRewardPerShare
        updateUserRewardPerShare(_tokenAddress);

        // calculate all the rewards and set it as pending rewards
        user.pendingReward = user.pendingReward.add(
            user.amount.mul(pool.accUserRewardPerShare).div(1e12).sub(user.rewardDebt)
        );
        // Update the user data
        user.amount = user.amount.sub(_amount);
        // update reward debt
        user.rewardDebt = user.amount.mul(pool.accUserRewardPerShare).div(1e12);
        // update total user deposit amount
        pool.userDepositAmount = pool.userDepositAmount.sub(_amount);

        if (_tokenAddress != address(0)) {
            IERC20(_tokenAddress).safeTransfer(_to, _amount);
        } else {
            (bool sent,) = _to.call{gas: SAFE_GAS_STIPEND, value: _amount}("");
            require(sent, "Failed to send Ether");
        }

        emit WithdrawLiquidity(
            msg.sender,
            _to,
            _amount,
            _tokenAddress
        );
    }

    /**
     * owner recovers fee from ERC20
     * @param _amount amount that owner wants to recover.
     * @param _tokenAddress L1 token address
     * @param _to receiver to get the fee.
     */
    function ownerRecoverFee(
        uint256 _amount,
        address _tokenAddress,
        address _to
    )
        external
        onlyOwner()
    {
        PoolInfo storage pool = poolInfo[_tokenAddress];

        require(pool.l2TokenAddress != address(0), "Token Address Not Register");
        require(pool.accOwnerReward >= _amount, "Owner Reward Withdraw Error");

        pool.accOwnerReward = pool.accOwnerReward.sub(_amount);

        if (_tokenAddress != address(0)) {
            IERC20(_tokenAddress).safeTransfer(_to, _amount);
        } else {
            (bool sent,) = _to.call{gas: SAFE_GAS_STIPEND, value: _amount}("");
            require(sent, "Failed to send Ether");
        }

        emit OwnerRecoverFee(
            msg.sender,
            _to,
            _amount,
            _tokenAddress
        );
    }

    /**
     * withdraw reward from ERC20
     * @param _amount reward amount that liquidity providers want to withdraw
     * @param _tokenAddress L1 token address
     * @param _to receiver to get the reward
     */
    function withdrawReward(
        uint256 _amount,
        address _tokenAddress,
        address _to
    )
        external
        whenNotPaused
    {
        PoolInfo storage pool = poolInfo[_tokenAddress];
        UserInfo storage user = userInfo[_tokenAddress][msg.sender];

        require(pool.l2TokenAddress != address(0), "Token Address Not Register");

        uint256 pendingReward = user.pendingReward.add(
            user.amount.mul(pool.accUserRewardPerShare).div(1e12).sub(user.rewardDebt)
        );

        require(pendingReward >= _amount, "Withdraw Reward Error");

        user.pendingReward = pendingReward.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accUserRewardPerShare).div(1e12);

        if (_tokenAddress != address(0)) {
            IERC20(_tokenAddress).safeTransfer(_to, _amount);
        } else {
            (bool sent,) = _to.call{gas: SAFE_GAS_STIPEND, value: _amount}("");
            require(sent, "Failed to send Ether");
        }

        emit WithdrawReward(
            msg.sender,
            _to,
            _amount,
            _tokenAddress
        );
    }

    /**
     * Pause contract
     */
    function pause() external onlyOwner() {
        _pause();
    }

    /**
     * UnPause contract
     */
    function unpause() external onlyOwner() {
        _unpause();
    }

    /*************************
     * Cross-chain Functions *
     *************************/

    /**
     * Move funds from L2 to L1, and pay out from the right liquidity pool
     * part of the contract pause, if only this method needs pausing use pause on CDM_Fast
     * @param _to receiver to get the funds
     * @param _amount amount to to be transferred.
     * @param _tokenAddress L1 token address
     */
    function clientPayL1(
        address payable _to,
        uint256 _amount,
        address _tokenAddress
    )
        external
        onlyFromCrossDomainAccount(address(L2LiquidityPoolAddress))
        whenNotPaused
    {
        bool replyNeeded = false;

        PoolInfo storage pool = poolInfo[_tokenAddress];
        uint256 userRewardFee = (_amount.mul(userRewardFeeRate)).div(1000);
        uint256 ownerRewardFee = (_amount.mul(ownerRewardFeeRate)).div(1000);
        uint256 totalFee = userRewardFee.add(ownerRewardFee);
        uint256 receivedAmount = _amount.sub(totalFee);

        if (_tokenAddress != address(0)) {
            //IERC20(_tokenAddress).safeTransfer(_to, _amount);
            if (receivedAmount > IERC20(_tokenAddress).balanceOf(address(this))) {
                replyNeeded = true;
            } else {
                pool.accUserReward = pool.accUserReward.add(userRewardFee);
                pool.accOwnerReward = pool.accOwnerReward.add(ownerRewardFee);
                IERC20(_tokenAddress).safeTransfer(_to, receivedAmount);
            }
        } else {
            // //this is ETH
            // // balances[address(0)] = balances[address(0)].sub(_amount);
            // //_to.transfer(_amount); UNSAFE
            // (bool sent,) = _to.call{gas: SAFE_GAS_STIPEND, value: _amount}("");
            // require(sent, "Failed to send Ether");
            if (receivedAmount > address(this).balance) {
                 replyNeeded = true;
             } else {
                pool.accUserReward = pool.accUserReward.add(userRewardFee);
                pool.accOwnerReward = pool.accOwnerReward.add(ownerRewardFee);
                 //this is ETH
                 // balances[address(0)] = balances[address(0)].sub(_amount);
                 //_to.transfer(_amount); UNSAFE
                 (bool sent,) = _to.call{gas: SAFE_GAS_STIPEND, value: receivedAmount}("");
                 require(sent, "Failed to send Ether");
             }
         }

         if (replyNeeded) {
             // send cross domain message
             bytes memory data = abi.encodeWithSelector(
             iL2LiquidityPool.clientPayL2Settlement.selector,
             _to,
             _amount,
             pool.l2TokenAddress
             );

             sendCrossDomainMessage(
                 address(L2LiquidityPoolAddress),
                 SETTLEMENT_L2_GAS,
                 data
             );
         } else {
             emit ClientPayL1(
             _to,
             receivedAmount,
             userRewardFee,
             ownerRewardFee,
             totalFee,
             _tokenAddress
             );
         }
    }

    /**
     * Settlement pay when there's not enough funds on the other side
     * part of the contract pause, if only this method needs pausing use pause on CDM_Fast
     * @param _to receiver to get the funds
     * @param _amount amount to to be transferred.
     * @param _tokenAddress L1 token address
     */
    function clientPayL1Settlement(
        address payable _to,
        uint256 _amount,
        address _tokenAddress
    )
        external
        onlyFromCrossDomainAccount(address(L2LiquidityPoolAddress))
        whenNotPaused
    {
        PoolInfo storage pool = poolInfo[_tokenAddress];
        uint256 userRewardFee = (_amount.mul(userRewardFeeRate)).div(1000);
        uint256 ownerRewardFee = (_amount.mul(ownerRewardFeeRate)).div(1000);
        uint256 totalFee = userRewardFee.add(ownerRewardFee);
        uint256 receivedAmount = _amount.sub(totalFee);

        pool.accUserReward = pool.accUserReward.add(userRewardFee);
        pool.accOwnerReward = pool.accOwnerReward.add(ownerRewardFee);

        if (_tokenAddress != address(0)) {
            IERC20(_tokenAddress).safeTransfer(_to, receivedAmount);
        } else {
            //this is ETH
            // balances[address(0)] = balances[address(0)].sub(_amount);
            //_to.transfer(_amount); UNSAFE
            (bool sent,) = _to.call{gas: SAFE_GAS_STIPEND, value: receivedAmount}("");
            require(sent, "Failed to send Ether");
        }

        emit ClientPayL1Settlement(
        _to,
        receivedAmount,
        userRewardFee,
        ownerRewardFee,
        totalFee,
        _tokenAddress
        );
    }
}
