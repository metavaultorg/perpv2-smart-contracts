// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import './utils/AddressStorage.sol';
import './utils/Governable.sol';
import './utils/interfaces/IStore.sol';

/**
 * @title  Store
 * @notice Users can deposit supported assets to back trader profits and receive
 *         a share of trader losses. Each asset pool is siloed, e.g. the ETH
 *         pool is independent from the USDC pool.
 *         Persistent storage of supported assets
 *         Persistent storage of supported markets
 *         Storage of protocol funds
 */
contract Store is Governable,ReentrancyGuard,IStore {
    // Libraries
    using SafeERC20 for IERC20;
    using Address for address payable;

    // Constants
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant MAX_FEE = 1000; // 10%
    uint256 public constant MAX_DEVIATION = 1000; // 10%
    uint256 public constant MAX_LIQTHRESHOLD = 10000; // 100%
    uint256 public constant MAX_MIN_ORDER_AGE = 30; //seconds
    uint256 public constant MIN_PYTH_MAX_AGE = 3; //seconds

    // State variables
    uint256 public feeShare = 500;
    uint256 public bufferPayoutPeriod = 7 days;
    bool public isPublicDeposit;

    // Asset list
    address[] public assetList;
    mapping(address => Asset) private assets;

    // Market list
    bytes10[] public marketList; 
    mapping(bytes10 => Market) private markets;

    mapping(address => uint256) private utilizationMultipliers; // asset => utilization multiplier , for maxOI control

    mapping(address => uint256) private lpSupply; // asset => lp supply
    mapping(address => uint256) private balances; // asset => balance
    mapping(address => mapping(address => uint256)) private userLpBalances; // asset => account => lp amount

    mapping(address => uint256) private bufferBalances; // asset => balance
    mapping(address => uint256) private lastPaid; // asset => timestamp

    mapping(address => bool) public whitelistedKeepers;
    mapping(address => bool) public whitelistedDepositer;
    mapping(address => bool) public whitelistedFundingAccount;
    mapping(address => int256) private globalUPLs; // asset => upl

    mapping(address => uint256) public feeReserves;  //treasury fees

    // Contracts
    AddressStorage public immutable addressStorage;
    address public positionManagerAddress;
    address public orderBookAddress;
    address public executorAddress;

        // Events
    event PoolDeposit(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 feeAmount,
        uint256 lpAmount,
        uint256 poolBalance,
        address indexed fundingAccount
    );

    event DirectPoolDeposit(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 bufferToPoolAmount,
        uint256 poolBalance,
        uint256 bufferBalance
    );

    event PoolWithdrawal(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 feeAmount,
        uint256 lpAmount,
        uint256 poolBalance
    );

    event PoolPayIn(
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint256 amount,
        uint256 bufferToPoolAmount,
        uint256 poolBalance,
        uint256 bufferBalance
    );

    event PoolPayOut(
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint256 amount,
        uint256 poolBalance,
        uint256 bufferBalance
    );
    event FeeShareUpdated(uint256 feeShare);
    event BufferPayoutPeriodUpdated(uint256 period);
    event UtilizationMultiplierUpdated(address indexed asset, uint256 utilizationMultiplier);
    event PublicDepositUpdated(bool isPublicDeposit);
    event WhitelistedKeeperUpdated(address indexed keeper, bool isActive);
    event WhitelistedFundingAccountUpdated(address indexed account, bool isActive);
    event WhitelistedDepositerUpdated(address indexed account, bool isActive);

    error Unauthorized(address account);

    /// @dev Only callable by PositionManager contract
    modifier onlyPositionManager() {
        if(msg.sender != positionManagerAddress)
            revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Only callable by PositionManager or Executor contracts
    modifier onlyPositionManagerAndExecutor() {
        if(msg.sender != positionManagerAddress && msg.sender != executorAddress)
            revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Only callable by PositionManager or OrderBook contracts
    modifier onlyPositionManagerAndOrderBook() {
        if(msg.sender != positionManagerAddress && msg.sender != orderBookAddress)
            revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage)  {
        addressStorage = _addressStorage;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        orderBookAddress = addressStorage.getAddress('OrderBook');
        positionManagerAddress = addressStorage.getAddress('PositionManager');
        executorAddress = addressStorage.getAddress('Executor');
    }

    /// @notice withdraw treasury fees
    /// @dev Only callable by governance
    /// @param _asset  address of asset
    function withdrawFees(address _asset) external override onlyGov {
        uint256 amount = feeReserves[_asset];
        if (amount == 0) {
            return;
        }
        feeReserves[_asset] = 0;
        _transferOut(_asset, addressStorage.getAddress('treasury'), amount);
    }

    /// @notice Set or update an asset
    /// @dev Only callable by governance
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _assetInfo Struct containing minSize and referencePriceFeed
    function setAsset(address _asset, Asset memory _assetInfo) external override onlyGov {
        assets[_asset] = _assetInfo;
        uint256 length = assetList.length;
        for (uint256 i; i < length; i++) {
            if (assetList[i] == _asset) return;
        }
        assetList.push(_asset);
    }

    /// @notice Set or update a market
    /// @dev Only callable by governance
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _marketInfo Market struct containing required market data
    function setMarket(bytes10 _market, Market memory _marketInfo) external override onlyGov {
        require(_marketInfo.fee <= MAX_FEE, '!max-fee');
        require(_marketInfo.maxLeverage >= 1, '!max-leverage');
        require(_marketInfo.maxDeviation <= MAX_DEVIATION, '!max-deviation');
        require(_marketInfo.liqThreshold <= MAX_LIQTHRESHOLD, '!max-liqthreshold');
        require(_marketInfo.minOrderAge <= MAX_MIN_ORDER_AGE, '!max-minorderage');
        require(_marketInfo.pythMaxAge >= MIN_PYTH_MAX_AGE, '!min-pythmaxage');

        markets[_market] = _marketInfo;
        uint256 length = marketList.length;
        for (uint256 i; i < length; i++) {
            // check if _market already exists, if yes return
            if (marketList[i] == _market) return;
        }
        marketList.push(_market);
    }

    /// @notice Set store fee
    /// @dev Only callable by governance
    /// @param _bps fee share in bps
    function setFeeShare(uint256 _bps) external override onlyGov {
        require(_bps < BPS_DIVIDER, '!bps');
        feeShare = _bps;
        emit FeeShareUpdated(_bps);
    }

    /// @notice Set buffer payout period
    /// @dev Only callable by governance
    /// @param _period Buffer payout period in seconds, default is 7 days (604800 seconds)
    function setBufferPayoutPeriod(uint256 _period) external override onlyGov {
        require(_period > 0, '!period');
        bufferPayoutPeriod = _period;
        emit BufferPayoutPeriodUpdated(_period);
    }

    /// @notice Set utilization multiplier
    /// @dev Only callable by governance
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _utilizationMultiplier utilization multiplier in bps ,e.g. if it is 5000 , maxOI available = asset balance x %50
    function setUtilizationMultiplier(address _asset, uint256 _utilizationMultiplier) external override onlyGov {
        utilizationMultipliers[_asset] = _utilizationMultiplier;
        emit UtilizationMultiplierUpdated(_asset,_utilizationMultiplier);
    }

    /// @notice Set depositing public or private
    /// @dev Only callable by governance
    /// @param _isPublicDeposit whether depositin is public
    function setIsPublicDeposit(bool _isPublicDeposit) external override onlyGov {
        isPublicDeposit = _isPublicDeposit;
        emit PublicDepositUpdated(_isPublicDeposit);
    }

    /// @notice Whitelisted keeper that can set global upl
    /// @dev Only callable by governance
    /// @param _keeper Keeper address
    /// @param _isActive whether keeper is active
    function setWhitelistedKeeper(address _keeper, bool _isActive) external  onlyGov {
        whitelistedKeepers[_keeper] = _isActive;
        emit WhitelistedKeeperUpdated(_keeper,_isActive); 
    }

    /// @notice Set whitelisted Funding Account
    /// @dev Only callable by governance
    /// @param _account  accounts authorized to deposit on behalf of another user
    /// @param _isActive whether account is active
    function setWhitelistedFundingAccount(address _account, bool _isActive) external  onlyGov {
        whitelistedFundingAccount[_account] = _isActive;
        emit WhitelistedFundingAccountUpdated(_account,_isActive);
    }

    /// @notice Set whitelisted depositer
    /// @dev Only callable by governance
    /// @param _account  accounts authorized to deposit
    /// @param _isActive whether account is active
    function setWhitelistedDepositer(address _account, bool _isActive) external override onlyGov {
        whitelistedDepositer[_account] = _isActive;
        emit WhitelistedDepositerUpdated(_account,_isActive);
    }

    /// @notice Increments pool balance
    /// @dev Only callable by PositionManager contract
    function incrementBalance(address _asset, uint256 _amount) external onlyPositionManager {
        balances[_asset] += _amount;
    }

    /// @notice Increments treasury fees
    /// @dev Only callable by PositionManager contract
    function addFees(address _asset, uint256 _amount) external onlyPositionManager {
        feeReserves[_asset] += _amount;
    }

    /// @notice Set global UPL, called by whitelisted keeper
    /// @param _assets Asset addresses
    /// @param _upls Corresponding total unrealized profit / loss
    function setGlobalUPLs(address[] calldata _assets, int256[] calldata _upls) external {
        if(!whitelistedKeepers[msg.sender])
            revert Unauthorized(msg.sender);
        for (uint256 i; i < _assets.length; i++) {
            globalUPLs[_assets[i]] = _upls[i];
        }
    }

    /// @notice Credit trader loss to buffer and pay pool from buffer amount based on time and payout rate
    /// @dev Only callable by PositionManager and Executor contracts
    /// @param _user User which incurred trading loss
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _amount Amount of trader loss
    function creditTraderLoss(address _user, address _asset, bytes10 _market, uint256 _amount) external onlyPositionManagerAndExecutor {

        // first the pending buffer will be transferred to the pool
        uint256 amountToSendPool = _sendBufferToPool(_asset);
        
        // credit trader loss to buffer
        _incrementBufferBalance(_asset, _amount);

        // emit event
        emit PoolPayIn(
            _user,
            _asset,
            _market,
            _amount,
            amountToSendPool,
            balances[_asset],
            bufferBalances[_asset]
        );
    }

    /// @notice Pay out trader profit, from buffer first then pool if buffer is depleted
    /// @dev Only callable by PositionManager contract
    /// @param _user Address to send funds to
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _amount Amount of trader profit
    function debitTraderProfit(
        address _user,
        address _asset,
        bytes10 _market,
        uint256 _amount
    ) external onlyPositionManager {
        // return if profit = 0
        if (_amount == 0) return;

        uint256 bufferBalance = bufferBalances[_asset];

        // decrement buffer balance first
        _decrementBufferBalance(_asset, _amount);

        // if _amount is greater than available in the buffer, pay remaining from the pool
        if (_amount > bufferBalance) {
            uint256 diffToPayFromPool = _amount - bufferBalance;
            uint256 poolBalance = balances[_asset];
            require(diffToPayFromPool < poolBalance, '!pool-balance');
            _decrementBalance(_asset, diffToPayFromPool);
        }

        // transfer profit out
        _transferOut(_asset, _user, _amount);

        // emit event
        emit PoolPayOut(_user, _asset, _market, _amount, balances[_asset], bufferBalances[_asset]);
    }

    /// @notice Withdraw 'amount' of 'asset'
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _amount Amount to be withdrawn
    function withdraw(address _asset, uint256 _amount) external {
        require(_amount > BPS_DIVIDER, '!amount');
        require(isSupported(_asset), '!asset');

        address user = msg.sender;

        // check pool balance and lp supply
        uint256 balance = balances[_asset];
        uint256 lpAssetSupply = lpSupply[_asset];
        require(balance > 0 && lpAssetSupply > 0, '!empty');

        // check user balance
        uint256 userBalance = getUserBalance(_asset, user);
        if (_amount > userBalance) _amount = userBalance;

        // withdrawal tax
        uint256 taxBps = getWithdrawalTaxBps(_asset, _amount);
        require(taxBps < BPS_DIVIDER, "!tax");
        uint256 tax = (_amount * taxBps) / BPS_DIVIDER;
        uint256 amountMinusTax = _amount - tax;

        // LP amount
        uint256 lpAmount = (_amount * lpAssetSupply) / balance;

        // decrement balances
        _decrementUserLpBalance(_asset, user, lpAmount);
        _decrementBalance(_asset, amountMinusTax);

        // transfer funds out
        _transferOut(_asset, user, amountMinusTax);

        // emit event
        emit PoolWithdrawal(user, _asset, _amount, tax, lpAmount, balances[_asset]);
    }

    /// @notice Transfers `_amount` of `_asset` in
    /// @dev Only callable by PositionManager or OrderBook contracts
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _from Address where asset is transferred from
    function transferIn(address _asset, address _from, uint256 _amount) external payable onlyPositionManagerAndOrderBook {
        _transferIn(_asset,_from,_amount);
    }

    /// @notice Transfers `_amount` of `_asset` out
    /// @dev Only callable by PositionManager or OrderBook contracts
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _to Address where asset is transferred to
    function transferOut(address _asset, address _to, uint256 _amount) external nonReentrant onlyPositionManagerAndOrderBook {
        _transferOut(_asset,_to,_amount);
    }

    /// @notice Returns asset struct of `_asset`
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getAsset(address _asset) external view returns (Asset memory) {
        return assets[_asset];
    }

    /// @notice Get a list of all supported assets
    function getAssetList() external view returns (address[] memory) {
        return assetList;
    }

    /// @notice Get number of supported assets
    function getAssetCount() external view returns (uint256) {
        return assetList.length;
    }

    /// @notice Returns asset address at `_index`
    /// @param _index index of asset
    function getAssetByIndex(uint256 _index) external view returns (address) {
        return assetList[_index];
    }

    /// @notice Returns market struct of `market`
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    function getMarket(bytes10 _market) external view override returns (Market memory) {
        return markets[_market];
    }

    /// @notice Returns market struct array of specified markets
    /// @param _markets Array of market bytes10, e.g. ["0x4554482D555344000000", "0x4254432D555344000000"] for ETH-USD and BTC-USD
    function getMarketMany(bytes10[] calldata _markets) external view returns (Market[] memory) {
        uint256 length = _markets.length;
        Market[] memory _marketInfos = new Market[](length);
        for (uint256 i; i < length; i++) {
            _marketInfos[i] = markets[_markets[i]];
        }
        return _marketInfos;
    }

    /// @notice Returns market identifier at `index`
    /// @param index index of marketList
    function getMarketByIndex(uint256 index) external view returns (bytes10) {
        return marketList[index];
    }

    /// @notice Get a list of all supported markets
    function getMarketList() external view returns (bytes10[] memory) {
        return marketList;
    }

    /// @notice Get number of supported markets
    function getMarketCount() external view returns (uint256) {
        return marketList.length;
    }

    /// @notice Returns the sum of buffer and pool balance of `_asset`
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getAvailable(address _asset) external view returns (uint256) {
        return balances[_asset] + bufferBalances[_asset];
    }

    /// @notice Returns the sum of buffer and pool balance of `_asset` multiplied by utilization multiplier
    /// @dev For available OI control for new position
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getAvailableForOI(address _asset) external view returns (uint256) {
        return ((balances[_asset] + bufferBalances[_asset]) * utilizationMultipliers[_asset]) / BPS_DIVIDER;
    }

    
    /// @notice Returns amount of `_asset` in pool
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getBalance(address _asset) external view returns (uint256) {
        return balances[_asset];
    }

    /// @notice Returns pool balances of `_assets`
    function getBalances(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i; i < length; i++) {
            _balances[i] = balances[_assets[i]];
        }

        return _balances;
    }

    /// @notice Returns buffer balances of `_assets`
    function getBufferBalances(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i; i < length; i++) {
            _balances[i] = bufferBalances[_assets[i]];
        }

        return _balances;
    }

    /// @notice Returns `_assets` balance of `account`
    function getUserBalances(address[] calldata _assets, address account) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i; i < length; i++) {
            _balances[i] = getUserBalance(_assets[i], account);
        }

        return _balances;
    }

    /// @notice Returns last time pool was paid
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getLastPaid(address _asset) external view returns (uint256) {
        return lastPaid[_asset];
    }

    /// @notice Returns total amount of LP for `_asset`
    function getLpSupply(address _asset) external view returns (uint256) {
        return lpSupply[_asset];
    }

    /// @notice Returns total unrealized p/l for `_asset`
    function getGlobalUPL(address _asset) external view returns (int256) {
        return globalUPLs[_asset];
    }

    /// @notice Deposit `_amount` of `_asset` into the pool
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _amount Amount to be deposited
    function deposit(address _asset, uint256 _amount) external payable {
        if(!isPublicDeposit){
            require(whitelistedDepositer[msg.sender], '!whitelisted');
        }            
        _deposit(msg.sender, _asset, _amount); 
    }

    /// @notice Deposit `_amount` of `_asset` into the pool by Funding account on behalf of `_user`
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _amount Amount to be deposited
    function depositForAccount(address _user, address _asset, uint256 _amount) external payable {
        require(whitelistedFundingAccount[msg.sender], '!whitelisted');
        require(_user != address(0), 'zero address');
        _deposit(_user, _asset, _amount); 
    }

    /// @notice Direct Pool Deposit `_amount` of `_asset` into the pool via buffer
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _amount Amount to be deposited
    function directPoolDeposit(address _asset, uint256 _amount) external payable {
        require(_amount > 0, '!_amount');
        require(isSupported(_asset), '!_asset');

        // if _asset is ETH (address(0)), set _amount to msg.value
        if (_asset == address(0)) {
            require(msg.value > 0, '!msg.value');
            _amount = msg.value;
        } else {
            _transferIn(_asset, msg.sender, _amount);
        }

        // first the pending buffer will be transferred to the pool
        uint256 amountToSendPool = _sendBufferToPool(_asset);

        // direct deposit to buffer
        _incrementBufferBalance(_asset, _amount);

        // emit event
        emit DirectPoolDeposit(
            msg.sender, 
            _asset, 
            _amount, 
            amountToSendPool,
            balances[_asset],
            bufferBalances[_asset]
        );
    }    

    /// @notice Returns pool deposit tax for `asset` and amount in bps
    function getDepositTaxBps(address _asset, uint256 _amount) public view returns (uint256) {
        uint256 taxBps;
        uint256 balance = balances[_asset];
        uint256 bufferBalance = bufferBalances[_asset];
        if (globalUPLs[_asset] - int256(bufferBalance) < 0) {
            taxBps = uint256(int256(BPS_DIVIDER) * (int256(bufferBalance) - globalUPLs[_asset]) / (int256(balance) + int256(_amount)));
        }
        return taxBps;
    }

    /// @notice Returns pool withdrawal tax for `asset` and amount in bps
    function getWithdrawalTaxBps(address _asset, uint256 _amount) public view returns (uint256) {
        uint256 taxBps;
        uint256 balance = balances[_asset];
        if (_amount >= balance) return BPS_DIVIDER;
        uint256 bufferBalance = bufferBalances[_asset];
        if (globalUPLs[_asset] - int256(bufferBalance) > 0) {
            taxBps = uint256(int256(BPS_DIVIDER) * (globalUPLs[_asset] - int256(bufferBalance)) / (int256(balance) - int256(_amount)));
        }
        return taxBps;
    }

    /// @notice Returns `_asset` balance of `_account`
    function getUserBalance(address _asset, address _account) public view returns (uint256) {
        if (lpSupply[_asset] == 0) return 0;
        return (userLpBalances[_asset][_account] * balances[_asset]) / lpSupply[_asset];
    }

    /// @notice Returns amount of LP of `_account` for `_asset`
    function getUserLpBalance(address _asset, address _account) external view returns (uint256) {
        return userLpBalances[_asset][_account];
    }

    /// @notice Returns true if `_asset` is supported
    /// @param _asset Asset address, e.g. address(0) for ETH
    function isSupported(address _asset) public view returns (bool) {
        return assets[_asset].minSize > 0;
    }

    /// @notice Returns amount of `_asset` in buffer
    function getBufferBalance(address _asset) external view returns (uint256) {
        return bufferBalances[_asset];
    }

    /// @notice Increments pool balance
    /// @dev Internal function
    function _incrementBalance(address _asset, uint256 _amount) internal {
        balances[_asset] += _amount;
    }

    /// @notice Decrements pool balance
    /// @dev Internal function
    function _decrementBalance(address _asset, uint256 _amount) internal {
        balances[_asset] = balances[_asset] <= _amount ? 0 : balances[_asset] - _amount;
    }

    /// @notice  Increments buffer balance
    /// @dev Internal function
    function _incrementBufferBalance(address _asset, uint256 _amount) internal {
        bufferBalances[_asset] += _amount;
    }

    /// @notice  Decrements buffer balance
    /// @dev Internal function
    function _decrementBufferBalance(address _asset, uint256 _amount) internal {
        bufferBalances[_asset] = bufferBalances[_asset] <= _amount ? 0 : bufferBalances[_asset] - _amount;
    }

    /// @notice  Updates `lastPaid`
    /// @dev Internal function
    function _setLastPaid(address _asset, uint256 _timestamp) internal {
        lastPaid[_asset] = _timestamp;
    }

    /// @notice Increments `lpSupply` and `userLpBalances`
    /// @dev Internal function
    function _incrementUserLpBalance(address _asset, address _user, uint256 _amount) internal {
        lpSupply[_asset] += _amount;

        unchecked {
            // Overflow not possible: balance + _amount is at most lpSupply + _amount, which is checked above.
            userLpBalances[_asset][_user] += _amount;
        }
    }

    /// @notice Decrements `lpSupply` and `userLpBalances`
    /// @dev Internal function
    function _decrementUserLpBalance(address asset, address _user, uint256 amount) internal {
        lpSupply[asset] = lpSupply[asset] <= amount ? 0 : lpSupply[asset] - amount;

        userLpBalances[asset][_user] = userLpBalances[asset][_user] <= amount
            ? 0
            : userLpBalances[asset][_user] - amount;
    }

    /// @notice Stream buffer balance progressively into the pool
    /// @dev Internal function
    function _sendBufferToPool(address _asset) internal returns (uint256) {
        // local variables
        uint256 lpAsset = lastPaid[_asset];
        uint256 currentTimestamp = block.timestamp;
        uint256 amountToSendPool;

        if (lpAsset == 0) {
            // during the very first execution, set lastPaid and return
            _setLastPaid(_asset, currentTimestamp);
        } else {
            // get buffer balance and buffer payout period to calculate amountToSendPool
            uint256 bufferBalance = bufferBalances[_asset];

            // Stream buffer balance progressively into the pool
            amountToSendPool = (bufferBalance * (block.timestamp - lpAsset)) / bufferPayoutPeriod;
            if (amountToSendPool > bufferBalance) amountToSendPool = bufferBalance;

            // update storage
            if(amountToSendPool > 0){
                _incrementBalance(_asset, amountToSendPool);
                _decrementBufferBalance(_asset, amountToSendPool);
            }
            _setLastPaid(_asset, currentTimestamp);
        }
        return amountToSendPool;
    }


    /// @notice Deposit `_amount` of `_asset` into the pool
    /// @dev Internal function
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _amount Amount to be deposited
    function _deposit(address _user,address _asset, uint256 _amount) internal {
        require(_amount > 0, '!_amount');
        require(isSupported(_asset), '!_asset');

        uint256 balance = balances[_asset];

        // if _asset is ETH (address(0)), set _amount to msg.value
        if (_asset == address(0)) {
            require(msg.value > 0, '!msg.value');
            _amount = msg.value;
        } else {
            _transferIn(_asset, msg.sender, _amount);
        }

        // deposit tax
        uint256 taxBps = getDepositTaxBps(_asset, _amount);
        require(taxBps < BPS_DIVIDER, "!tax");
        uint256 tax = (_amount * taxBps) / BPS_DIVIDER;
        uint256 amountMinusTax = _amount - tax;

        // pool share is equal to pool balance of _user divided by the total balance
        uint256 lpAssetSupply = lpSupply[_asset];
        uint256 lpAmount = balance == 0 || lpAssetSupply == 0 ? amountMinusTax : (amountMinusTax * lpAssetSupply) / balance;

        // increment balances
        _incrementUserLpBalance(_asset, _user, lpAmount);
        _incrementBalance(_asset, _amount);

        // emit event
        emit PoolDeposit(_user, _asset, _amount, tax, lpAmount, balances[_asset],msg.sender);
    }

    /// @notice Transfers `_amount` of `_asset` in
    /// @dev Internal function
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _from Address where asset is transferred from
    function _transferIn(address _asset, address _from, uint256 _amount) internal {
        if (_amount == 0 || _asset == address(0)) return;
        IERC20(_asset).safeTransferFrom(_from, address(this), _amount);
    }

    /// @notice Transfers `_amount` of `_asset` out
    /// @dev Internal function
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param to Address where asset is transferred to
    function _transferOut(address _asset, address to, uint256 _amount) internal{
        if (_amount == 0 || to == address(0)) return;
        if (_asset == address(0)) {
            payable(to).sendValue(_amount);
        } else {
            IERC20(_asset).safeTransfer(to, _amount);
        }
    }

}

