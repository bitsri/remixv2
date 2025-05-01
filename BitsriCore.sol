// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./BitsriCoreBase.sol";

contract BitsriCore is BitsriCoreBase {
    

    enum ActionType {
        AssignBSUID,
        RequestUpdate,
        UpdateMainVault,
        MoveToLendVault,
        MoveFromLendVault,
        MoveToEarnVault,
        MoveFromEarnVault,
        Borrow,
        Repay,
        ClaimEarnings,
        WithdrawRequest,
        SetBTCWithdrawAddress
    }

    struct Transaction {
        uint256 timestamp;
        ActionType action;
        string details;
    }

    mapping(string => Transaction[]) public userTransactions;

    function _recordTransaction(string memory _bsuId, ActionType _action, string memory _details) internal {
        userTransactions[_bsuId].push(Transaction(block.timestamp, _action, _details));
    }

    function getTransactionHistory(string calldata _bsuId)
        external
        view
        returns (
            uint256[] memory serialNumbers,
            uint256[] memory timestamps,
            ActionType[] memory actions
        )
    {
        uint256 len = userTransactions[_bsuId].length;
        serialNumbers = new uint256[](len);
        timestamps = new uint256[](len);
        actions = new ActionType[](len);

        for (uint256 i = 0; i < len; i++) {
            Transaction storage txn = userTransactions[_bsuId][i];
            serialNumbers[i] = i + 1;
            timestamps[i] = txn.timestamp;
            actions[i] = txn.action;
        }
    }

    uint256 public totalInterestAccrued;
    uint256 public totalEarnings;
    uint256 public totalUSDCRepaid;

    struct ProtocolData {
        uint256 totalBTCDeposited;
        uint256 totalUSDCBorrowed;
        uint256 totalInterestAccrued;
        uint256 totalEarnings;
        uint256 totalDepositsMainVault;
        uint256 totalDepositsLendVault;
        uint256 totalDepositsEarnVault;
        uint256 totalUSDCRepaid;
    }

    function getProtocolData() external view returns (ProtocolData memory) {
        uint256 mainTotal = 0;
        uint256 lendTotal = 0;
        uint256 earnTotal = 0;
        for (uint256 i = 1; i <= bsuCounter; i++) {
            string memory bsuId = string(abi.encodePacked("BSU", uintToStr(i)));
            if (userProfiles[bsuId].exists) {
                mainTotal += mainVaults[bsuId].balance;
                lendTotal += lendVaults[bsuId].balance;
                earnTotal += earnVaults[bsuId].balance;
            }
        }
        return ProtocolData({
            totalBTCDeposited: getTotalBTCDeposited(),
            totalUSDCBorrowed: getTotalUSDCBorrowed(),
            totalInterestAccrued: totalInterestAccrued,
            totalEarnings: totalEarnings,
            totalDepositsMainVault: mainTotal,
            totalDepositsLendVault: lendTotal,
            totalDepositsEarnVault: earnTotal,
            totalUSDCRepaid: totalUSDCRepaid
        });
    }

    struct WithdrawRequest {
        string bsuId;
        uint256 amount;
        uint256 timestamp;
        bool fulfilled;
    }

    mapping(string => WithdrawRequest[]) public withdrawRequests;
    string[] public pendingWithdrawBSUIDs;

    function assignBSUID() public {
        assignBSUIDInternal(msg.sender);
        string memory bsuId = ethToBsuId[msg.sender];
        _recordTransaction(bsuId, ActionType.AssignBSUID, "Assigned BSUID");
    }

    function requestUpdate(string calldata _bsuId) public returns (bytes32) {
        bytes32 requestId = requestUpdateInternal(_bsuId, msg.sender);
        _recordTransaction(_bsuId, ActionType.RequestUpdate, string(abi.encodePacked("Requested update, requestId: ", requestId)));
        return requestId;
    }

    function updateMainVault(string calldata _bsuId) public {
        bool updated = updateMainVaultInternal(_bsuId);
        if (updated) {
            _recordTransaction(_bsuId, ActionType.UpdateMainVault, "Updated MainVault");
        } else {
            requestUpdate(_bsuId);
            revert("Data not yet updated, update requested");
        }
    }

    function moveToLendVault(string calldata _bsuId, uint256 _amount) public {
        moveToLendVaultInternal(_bsuId, _amount, msg.sender);
        _recordTransaction(_bsuId, ActionType.MoveToLendVault, string(abi.encodePacked("Moved ", uintToStr(_amount), " from MainVault to LendVault")));
        requestUpdate(_bsuId);
    }

    function moveFromLendVault(string calldata _bsuId, uint256 _amount) public {
        moveFromLendVaultInternal(_bsuId, _amount, msg.sender);
        _recordTransaction(_bsuId, ActionType.MoveFromLendVault, string(abi.encodePacked("Moved ", uintToStr(_amount), " from LendVault to MainVault")));
        requestUpdate(_bsuId);
    }

    function moveToEarnVault(string calldata _bsuId, uint256 _amount) public {
        moveToEarnVaultInternal(_bsuId, _amount, msg.sender);
        _recordTransaction(_bsuId, ActionType.MoveToEarnVault, string(abi.encodePacked("Moved ", uintToStr(_amount), " from MainVault to EarnVault")));
        requestUpdate(_bsuId);
    }

    function moveFromEarnVault(string calldata _bsuId, uint256 _amount) public {
        moveFromEarnVaultInternal(_bsuId, _amount, msg.sender);
        _recordTransaction(_bsuId, ActionType.MoveFromEarnVault, string(abi.encodePacked("Moved ", uintToStr(_amount), " from EarnVault to MainVault")));
        requestUpdate(_bsuId);
    }

    function borrow(string calldata _bsuId, uint256 _borrowAmount) public {
        borrowInternal(_bsuId, _borrowAmount, msg.sender);
        _recordTransaction(_bsuId, ActionType.Borrow, string(abi.encodePacked("Borrowed ", uintToStr(_borrowAmount))));
    }

    function repay(string calldata _bsuId, uint256 _repayAmount) public {
        (uint256 interestPayment, uint256 amountToRepay) = repayInternal(_bsuId, _repayAmount, msg.sender, INTEREST_RATE, SECONDS_PER_YEAR);
        totalInterestAccrued += interestPayment;
        totalUSDCRepaid += amountToRepay;
        _recordTransaction(_bsuId, ActionType.Repay, string(abi.encodePacked("Repaid ", uintToStr(amountToRepay), ", interest paid: ", uintToStr(interestPayment))));
    }

    function claimEarnings(string calldata _bsuId) public {
        uint256 earnings = claimEarningsInternal(_bsuId, msg.sender);
        totalEarnings += earnings;
        _recordTransaction(_bsuId, ActionType.ClaimEarnings, string(abi.encodePacked("Claimed earnings: ", uintToStr(earnings))));
    }

    function requestWithdraw(string calldata _bsuId, uint256 _amount) external {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, msg.sender);
          // Add this check:
         require(_amount <= mainVaults[_bsuId].balance, "Withdraw amount exceeds MainVault balance");
        withdrawRequests[_bsuId].push(WithdrawRequest(_bsuId, _amount, block.timestamp, false));
        pendingWithdrawBSUIDs.push(_bsuId);

        _recordTransaction(_bsuId, ActionType.WithdrawRequest, "Requested BTC withdrawal");
    }

    function getPendingWithdrawRequests() external view returns (WithdrawRequest[] memory) {
        uint256 count = pendingWithdrawBSUIDs.length;
        WithdrawRequest[] memory requests = new WithdrawRequest[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory bsuId = pendingWithdrawBSUIDs[i];
            WithdrawRequest[] storage userRequests = withdrawRequests[bsuId];
            if (userRequests.length > 0) {
                requests[i] = userRequests[userRequests.length - 1];
            }
        }
        return requests;
    }

    function setBTCWithdrawAddress(string calldata _bsuId, string calldata _btcAddress) external {
        validateBSUID(_bsuId);
        onlyBSUIDOwner(_bsuId, msg.sender);
        userProfiles[_bsuId].btcWithdrawAddress = _btcAddress;
        _recordTransaction(_bsuId, ActionType.SetBTCWithdrawAddress, "Updated BTC withdraw address");
    }

    function getBTCWithdrawAddress(string calldata _bsuId) external view returns (string memory) {
        validateBSUID(_bsuId);
        return userProfiles[_bsuId].btcWithdrawAddress;
    }

    function updateBalance(string calldata _bsuId, uint256 _additionalBalance, uint8 _balanceType) public {
        updateBalanceInternal(_bsuId, _additionalBalance, _balanceType);
        // Mark withdraw request as fulfilled if withdrawal
        if (_balanceType == 1) {
            WithdrawRequest[] storage userRequests = withdrawRequests[_bsuId];
            if (userRequests.length > 0) {
                userRequests[userRequests.length - 1].fulfilled = true;
                // Remove from pendingWithdrawBSUIDs
                for (uint256 i = 0; i < pendingWithdrawBSUIDs.length; i++) {
                    if (keccak256(bytes(pendingWithdrawBSUIDs[i])) == keccak256(bytes(_bsuId))) {
                        pendingWithdrawBSUIDs[i] = pendingWithdrawBSUIDs[pendingWithdrawBSUIDs.length - 1];
                        pendingWithdrawBSUIDs.pop();
                        break;
                    }
                }
            }
        }
    }
}