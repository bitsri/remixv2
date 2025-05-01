// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

interface IBitsriBTC {
    struct RequestData {
        uint256 serialNumber;
        string dbKey;
        string btcAddress;
        uint256 balance;
        uint256 transactions;
        bool fulfilled;
    }

    struct DBEntry {
        string btcAddress;
        uint256 balance;
        uint256 transactions;
        uint256 lastUpdated;
        bool fulfilled;
    }

    function getChainlinkDataFeedLatestAnswer() external view returns (int);
    function sendRequest(string calldata dbKey) external returns (bytes32);
    function getRequestData(bytes32 requestId) external view returns (RequestData memory);
    function getRequestDataBySerial(uint256 serialNumber) external view returns (RequestData memory);
    function getDBEntry(string memory dbKey) external view returns (DBEntry memory);
}

abstract contract BitsriCoreBase is ConfirmedOwner {
    IBitsriBTC public immutable bitsriBTC = IBitsriBTC(0x2e90De2298F79a72d8F0d45c722193625958Bb0D);
    IERC20 public immutable usdcToken = IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359);

    uint256 internal constant INTEREST_RATE = 10;
    uint256 internal constant EARN_RATE = 10;
    uint256 internal constant MAX_LTV = 70;
    uint256 internal constant SECONDS_PER_YEAR = 31536000;
    uint256 internal constant SATOSHI_TO_BTC = 100000000;
    uint256 internal constant MIN_UPDATE_INTERVAL = 10 minutes;

    struct MainVault {
        uint256 balance;
        uint256 lastUpdated;
    }

    struct LendVault {
        uint256 balance;
        uint256 borrowedAmount;
        uint256 borrowTimestamp;
    }

    struct EarnVault {
        uint256 balance;
        uint256 stakeTimestamp;
    }

    struct UserProfile {
        address ethAddress;
        string bsuId;
        string dbKey;
        bool exists;
        string btcWithdrawAddress;
    }

    mapping(address => string) public ethToBsuId;
    mapping(string => string) public bsuIdToDbKey;
    mapping(string => UserProfile) public userProfiles;
    mapping(string => MainVault) public mainVaults;
    mapping(string => LendVault) public lendVaults;
    mapping(string => EarnVault) public earnVaults;
    mapping(string => bytes32) public lastRequestIds;
    mapping(string => uint256) public lastRequestTimestamps;
    mapping(string => uint256) public movedBalances;
    mapping(string => uint256) public withdrawnBalances;
    uint256 public bsuCounter;

    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientCollateral(uint256 requested, uint256 available);
    error InvalidBSUID(string bsuId);
    error Unauthorized();
    error InvalidAmount();
    error DataNotUpToDate();
    error UpdateInProgress();
    error ActiveLoan();

    event BSUIDAssigned(address indexed ethAddress, string bsuId, string dbKey);
    event Borrowed(string indexed bsuId, uint256 borrowedAmount);
    event Repaid(string indexed bsuId, uint256 repaidAmount, uint256 interestPaid);
    event EarningsClaimed(string indexed bsuId, uint256 earningsAmount);
    event UpdateRequested(string indexed bsuId, string dbKey, bytes32 requestId);
    event MainVaultUpdated(string indexed bsuId, uint256 newBalance, uint256 timestamp);
    event FundsTransferred(string indexed bsuId, string fromVault, string toVault, uint256 amount);
    event MovedBalanceUpdated(string indexed bsuId, uint256 newMovedBalance);
    event WithdrawnBalanceUpdated(string indexed bsuId, uint256 newWithdrawnBalance);

    constructor() ConfirmedOwner(msg.sender) {}

    // --- Core Logic Functions ---

    function assignBSUIDInternal(address sender) internal {
        require(bytes(ethToBsuId[sender]).length == 0, "ETH address already has BSUID");

        bsuCounter++;
        string memory bsuId = string(abi.encodePacked("BSU", uintToStr(bsuCounter)));
        string memory dbKey = string(abi.encodePacked("DB", uintToStr(bsuCounter)));

        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);
        require(bytes(entry.btcAddress).length > 0, "Invalid DB key or DB key limit reached");

        ethToBsuId[sender] = bsuId;
        bsuIdToDbKey[bsuId] = dbKey;
        userProfiles[bsuId] = UserProfile(sender, bsuId, dbKey, true, "");

        mainVaults[bsuId] = MainVault(entry.balance, block.timestamp);
        lendVaults[bsuId] = LendVault(0, 0, 0);
        earnVaults[bsuId] = EarnVault(0, 0);

        emit BSUIDAssigned(sender, bsuId, dbKey);
    }

    function requestUpdateInternal(string calldata _bsuId, address sender) internal returns (bytes32) {
        validateBSUID(_bsuId);

        if (block.timestamp - lastRequestTimestamps[_bsuId] < MIN_UPDATE_INTERVAL) {
            if (sender != userProfiles[_bsuId].ethAddress && sender != owner()) {
                revert("Update requested too recently");
            }
        }

        string memory dbKey = bsuIdToDbKey[_bsuId];
        bytes32 requestId = bitsriBTC.sendRequest(dbKey);

        lastRequestIds[_bsuId] = requestId;
        lastRequestTimestamps[_bsuId] = block.timestamp;

        emit UpdateRequested(_bsuId, dbKey, requestId);

        return requestId;
    }

    function updateMainVaultInternal(string calldata _bsuId) internal returns (bool updated) {
        validateBSUID(_bsuId);

        string memory dbKey = bsuIdToDbKey[_bsuId];
        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);

        if (entry.lastUpdated > mainVaults[_bsuId].lastUpdated) {
            uint256 lendVaultBalance = lendVaults[_bsuId].balance;
            uint256 earnVaultBalance = earnVaults[_bsuId].balance;
            uint256 movedBalance = movedBalances[_bsuId];
            uint256 withdrawnBalance = withdrawnBalances[_bsuId];

            mainVaults[_bsuId].balance = entry.balance + movedBalance - lendVaultBalance - earnVaultBalance - withdrawnBalance;
            mainVaults[_bsuId].lastUpdated = entry.lastUpdated;

            emit MainVaultUpdated(_bsuId, mainVaults[_bsuId].balance, entry.lastUpdated);
            return true;
        }
        return false;
    }

    function checkAndRequestUpdateInternal(string memory _bsuId) internal returns (bool) {
        string memory dbKey = bsuIdToDbKey[_bsuId];
        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);

        if (block.timestamp - entry.lastUpdated > 24 hours) {
            bytes32 requestId = bitsriBTC.sendRequest(dbKey);
            lastRequestIds[_bsuId] = requestId;
            lastRequestTimestamps[_bsuId] = block.timestamp;

            emit UpdateRequested(_bsuId, dbKey, requestId);
            return false;
        }

        return true;
    }

    function moveToLendVaultInternal(string calldata _bsuId, uint256 _amount, address sender) internal {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, sender);

        MainVault storage mainVault = mainVaults[_bsuId];
        LendVault storage lendVault = lendVaults[_bsuId];

        if (mainVault.balance < _amount) {
            revert InsufficientBalance(_amount, mainVault.balance);
        }

        mainVault.balance -= _amount;
        lendVault.balance += _amount;

        emit FundsTransferred(_bsuId, "MainVault", "LendVault", _amount);
    }

    function moveFromLendVaultInternal(string calldata _bsuId, uint256 _amount, address sender) internal {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, sender);

        LendVault storage lendVault = lendVaults[_bsuId];
        MainVault storage mainVault = mainVaults[_bsuId];

        if (lendVault.borrowedAmount > 0) {
            uint256 collateralRequired = calculateRequiredCollateral(_bsuId, lendVault.borrowedAmount);

            if (lendVault.balance - _amount < collateralRequired) {
                revert InsufficientCollateral(_amount, lendVault.balance - collateralRequired);
            }
        }

        if (lendVault.balance < _amount) {
            revert InsufficientBalance(_amount, lendVault.balance);
        }

        lendVault.balance -= _amount;
        mainVault.balance += _amount;

        emit FundsTransferred(_bsuId, "LendVault", "MainVault", _amount);
    }

    function moveToEarnVaultInternal(string calldata _bsuId, uint256 _amount, address sender) internal {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, sender);

        MainVault storage mainVault = mainVaults[_bsuId];
        EarnVault storage earnVault = earnVaults[_bsuId];

        if (mainVault.balance < _amount) {
            revert InsufficientBalance(_amount, mainVault.balance);
        }

        if (earnVault.balance > 0) {
            uint256 earnings = calculateEarnings(_bsuId);
            earnVault.balance += earnings;
        }

        mainVault.balance -= _amount;
        earnVault.balance += _amount;
        earnVault.stakeTimestamp = block.timestamp;

        emit FundsTransferred(_bsuId, "MainVault", "EarnVault", _amount);
    }

    function moveFromEarnVaultInternal(string calldata _bsuId, uint256 _amount, address sender) internal {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, sender);

        EarnVault storage earnVault = earnVaults[_bsuId];
        MainVault storage mainVault = mainVaults[_bsuId];

        uint256 earnings = calculateEarnings(_bsuId);
        uint256 totalBalance = earnVault.balance + earnings;

        if (totalBalance < _amount) {
            revert InsufficientBalance(_amount, totalBalance);
        }

        earnVault.balance = totalBalance - _amount;
        earnVault.stakeTimestamp = block.timestamp;

        mainVault.balance += _amount;

        emit FundsTransferred(_bsuId, "EarnVault", "MainVault", _amount);
    }

    function borrowInternal(string calldata _bsuId, uint256 _borrowAmount, address sender) internal {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, sender);

        bool isUpToDate = checkAndRequestUpdateInternal(_bsuId);

        LendVault storage lendVault = lendVaults[_bsuId];

        uint256 requiredCollateral = calculateRequiredCollateral(_bsuId, _borrowAmount);

        if (lendVault.balance < requiredCollateral) {
            revert InsufficientCollateral(requiredCollateral, lendVault.balance);
        }

        lendVault.borrowedAmount += _borrowAmount;
        lendVault.borrowTimestamp = block.timestamp;

        require(usdcToken.transfer(userProfiles[_bsuId].ethAddress, _borrowAmount), "USDC transfer failed");

        emit Borrowed(_bsuId, _borrowAmount);

        if (!isUpToDate) {
            requestUpdateInternal(_bsuId, sender);
        }
    }

    function repayInternal(string calldata _bsuId, uint256 _repayAmount, address sender, uint256 interestRate, uint256 secondsPerYear) internal returns (uint256 interestPayment, uint256 amountToRepay) {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, sender);

        checkAndRequestUpdateInternal(_bsuId);

        LendVault storage lendVault = lendVaults[_bsuId];

        require(lendVault.borrowedAmount > 0, "No active loan");

        uint256 timeElapsed = block.timestamp - lendVault.borrowTimestamp;
        uint256 interestAmount = (lendVault.borrowedAmount * interestRate * timeElapsed) / (100 * secondsPerYear);

        uint256 totalDue = lendVault.borrowedAmount + interestAmount;
        amountToRepay = _repayAmount > totalDue ? totalDue : _repayAmount;

        require(usdcToken.transferFrom(sender, address(this), amountToRepay), "USDC transfer failed");

        interestPayment = amountToRepay > interestAmount ? interestAmount : amountToRepay;
        uint256 principalPayment = amountToRepay - interestPayment;

        if (amountToRepay >= totalDue) {
            lendVault.borrowedAmount = 0;
            lendVault.borrowTimestamp = 0;
        } else {
            lendVault.borrowedAmount -= principalPayment;
            lendVault.borrowTimestamp = block.timestamp;
        }

        emit Repaid(_bsuId, amountToRepay, interestPayment);

        requestUpdateInternal(_bsuId, sender);
    }

    function claimEarningsInternal(string calldata _bsuId, address sender) internal returns (uint256 earnings) {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, sender);

        checkAndRequestUpdateInternal(_bsuId);

        EarnVault storage earnVault = earnVaults[_bsuId];

        require(earnVault.balance > 0, "No funds in earn vault");

        earnings = calculateEarnings(_bsuId);
        require(earnings > 0, "No earnings to claim");

        earnVault.balance += earnings;
        earnVault.stakeTimestamp = block.timestamp;

        emit EarningsClaimed(_bsuId, earnings);

        requestUpdateInternal(_bsuId, sender);
    }

    function calculateEarnings(string memory _bsuId) public view returns (uint256) {
        EarnVault storage earnVault = earnVaults[_bsuId];

        if (earnVault.balance == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - earnVault.stakeTimestamp;
        return (earnVault.balance * EARN_RATE * timeElapsed) / (100 * SECONDS_PER_YEAR);
    }

    function calculateRequiredCollateral(string memory /*_bsuId*/, uint256 _borrowAmount) public view returns (uint256) {
        int btcPrice = bitsriBTC.getChainlinkDataFeedLatestAnswer();
        require(btcPrice > 0, "Invalid BTC price");

        uint256 requiredCollateral = (_borrowAmount * 100 * SATOSHI_TO_BTC) / (uint256(btcPrice) * MAX_LTV);

        return requiredCollateral;
    }

    function getVaultBalances(string calldata _bsuId) public view returns (uint256 mainBalance, uint256 lendBalance, uint256 earnBalance) {
        validateBSUID(_bsuId);

        MainVault storage mainVault = mainVaults[_bsuId];
        LendVault storage lendVault = lendVaults[_bsuId];
        EarnVault storage earnVault = earnVaults[_bsuId];

        return (mainVault.balance, lendVault.balance, earnVault.balance);
    }

    function getLoanDetails(string calldata _bsuId) public view returns (uint256 borrowed, uint256 interest, uint256 totalDue) {
        validateBSUID(_bsuId);

        LendVault storage lendVault = lendVaults[_bsuId];

        borrowed = lendVault.borrowedAmount;

        if (borrowed > 0) {
            uint256 timeElapsed = block.timestamp - lendVault.borrowTimestamp;
            interest = (borrowed * INTEREST_RATE * timeElapsed) / (100 * SECONDS_PER_YEAR);
            totalDue = borrowed + interest;
        } else {
            interest = 0;
            totalDue = 0;
        }

        return (borrowed, interest, totalDue);
    }

    function getBTCBalance(string calldata _bsuId) public view returns (uint256) {
        validateBSUID(_bsuId);

        string memory dbKey = bsuIdToDbKey[_bsuId];
        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);

        return entry.balance;
    }

    function getBTCAddress(string calldata _bsuId) public view returns (string memory) {
        validateBSUID(_bsuId);

        string memory dbKey = bsuIdToDbKey[_bsuId];
        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);

        return entry.btcAddress;
    }

    function isDataUpToDate(string calldata _bsuId) public view returns (bool) {
        validateBSUID(_bsuId);

        string memory dbKey = bsuIdToDbKey[_bsuId];
        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);

        return (block.timestamp - entry.lastUpdated <= 24 hours);
    }

    function timeSinceLastUpdate(string calldata _bsuId) public view returns (uint256) {
        validateBSUID(_bsuId);

        string memory dbKey = bsuIdToDbKey[_bsuId];
        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);

        return block.timestamp - entry.lastUpdated;
    }

    function validateBSUID(string memory _bsuId) internal view {
        if (!userProfiles[_bsuId].exists) {
            revert InvalidBSUID(_bsuId);
        }
    }

    function onlyBSUIDOwner(string memory _bsuId, address sender) internal view {
        if (userProfiles[_bsuId].ethAddress != sender) {
            revert Unauthorized();
        }
    }

    function uintToStr(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        str = string(bstr);
    }

    function getTotalBTCDeposited() public view returns (uint256) {
        uint256 totalDeposited = 0;

        for (uint256 i = 1; i <= bsuCounter; i++) {
            string memory bsuId = string(abi.encodePacked("BSU", uintToStr(i)));
            if (userProfiles[bsuId].exists) {
                MainVault storage mainVault = mainVaults[bsuId];
                EarnVault storage earnVault = earnVaults[bsuId];
                LendVault storage lendVault = lendVaults[bsuId];

                totalDeposited += mainVault.balance + earnVault.balance + lendVault.balance;
            }
        }

        return totalDeposited;
    }

    function getTotalUSDCBorrowed() public view returns (uint256) {
        uint256 totalBorrowed = 0;

        for (uint256 i = 1; i <= bsuCounter; i++) {
            string memory bsuId = string(abi.encodePacked("BSU", uintToStr(i)));
            if (userProfiles[bsuId].exists) {
                LendVault storage lendVault = lendVaults[bsuId];
                totalBorrowed += lendVault.borrowedAmount;
            }
        }

        return totalBorrowed;
    }

    function withdrawUSDC(uint256 _amount) public onlyOwner returns (bool) {
        uint256 contractBalance = usdcToken.balanceOf(address(this));
        require(_amount <= contractBalance, "less USDC Bal");

        return usdcToken.transfer(owner(), _amount);
    }

    function updateBalanceInternal(string calldata _bsuId, uint256 _additionalBalance, uint8 _balanceType) internal {
        validateBSUID(_bsuId);

        if (_balanceType == 0) {
            uint256 newMovedBalance = movedBalances[_bsuId] + _additionalBalance;
            movedBalances[_bsuId] = newMovedBalance;
            emit MovedBalanceUpdated(_bsuId, newMovedBalance);
        } else if (_balanceType == 1) {
            uint256 newWithdrawnBalance = withdrawnBalances[_bsuId] + _additionalBalance;
            withdrawnBalances[_bsuId] = newWithdrawnBalance;
            emit WithdrawnBalanceUpdated(_bsuId, newWithdrawnBalance);
        } else {
            revert("bad bal type");
        }

        string memory dbKey = bsuIdToDbKey[_bsuId];
        IBitsriBTC.DBEntry memory entry = bitsriBTC.getDBEntry(dbKey);

        if (entry.lastUpdated > mainVaults[_bsuId].lastUpdated) {
            uint256 lendVaultBalance = lendVaults[_bsuId].balance;
            uint256 earnVaultBalance = earnVaults[_bsuId].balance;
            uint256 movedBalance = movedBalances[_bsuId];
            uint256 withdrawnBalance = withdrawnBalances[_bsuId];

            mainVaults[_bsuId].balance = entry.balance + movedBalance - lendVaultBalance - earnVaultBalance - withdrawnBalance;
            mainVaults[_bsuId].lastUpdated = entry.lastUpdated;

            emit MainVaultUpdated(_bsuId, mainVaults[_bsuId].balance, entry.lastUpdated);
        }
    }

    function getBalance(string calldata _bsuId, uint8 _balanceType) public view returns (uint256) {
        validateBSUID(_bsuId);

        if (_balanceType == 0) {
            return movedBalances[_bsuId];
        } else if (_balanceType == 1) {
            return withdrawnBalances[_bsuId];
        } else {
            revert("bad bal type");
        }
    }
}
