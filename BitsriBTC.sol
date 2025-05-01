// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title BitsriBTC
 * @notice Fetches Bitcoin transaction data via Chainlink Functions and BTC/USD price data via Chainlink Price Feeds
 */
contract BitsriBTC is FunctionsClient, ConfirmedOwner {
    using FunctionsRequest for FunctionsRequest.Request;

    // Price Feed interface
    AggregatorV3Interface internal dataFeed;

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

    mapping(bytes32 => RequestData) public requests;
    mapping(uint256 => bytes32) public serialToRequestId;
    mapping(string => DBEntry) public dbEntries;
    mapping(string => bool) public btcExists;
    

    uint256 public requestCount;
    uint256 public dbCounter;
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;

    error UnexpectedRequestID(bytes32 requestId);

    event Response(bytes32 indexed requestId, string result, bytes response, bytes err);
    event RequestStored(bytes32 indexed requestId, uint256 serialNumber, string dbKey, string btcAddress);
    event RequestUpdated(bytes32 indexed requestId, string dbKey, uint256 balance, uint256 transactions);

    address router = 0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10;
    string source =
        "const btcAddress = args[0];"
        "const apiKey = 'b0aa3c37c68248f19538eb2ae16d68d2';"
        "const url = `https://api.blockcypher.com/v1/btc/main/addrs/${btcAddress}?token=${apiKey}`;"
        "const apiResponse = await Functions.makeHttpRequest({url: url});"
        "if (apiResponse.error) { throw Error('Request failed'); }"
        "const { balance, n_tx } = apiResponse.data;"
        "return Functions.encodeString(`${balance},${n_tx}`);";

    uint32 gasLimit = 300000;
    bytes32 donID = 0x66756e2d706f6c79676f6e2d6d61696e6e65742d310000000000000000000000;

    string public result;


    /**
     * Constructor initializes both the Functions Client and the Price Feed
     * Network: Polygon
     * Aggregator: BTC/USD
     * Address: 0xc907E116054Ad103354f2D350FD2514433D57F6f
     */
    constructor() FunctionsClient(router) ConfirmedOwner(msg.sender) {
        uploadBTCAddresses(new string[](0));
        
        // Initialize the price feed
        dataFeed = AggregatorV3Interface(
            0xc907E116054Ad103354f2D350FD2514433D57F6f
        );
    }

    /**
     * Returns the latest BTC/USD price from Chainlink Data Feed
     */
    function getChainlinkDataFeedLatestAnswer() public view returns (int) {
        // prettier-ignore
        (
            /* uint80 roundId */,
            int256 answer,
            /*uint256 startedAt*/,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        return answer;
    }

    //  Upload BTC addresses dynamically
    function uploadBTCAddresses(string[] memory btcAddresses) public onlyOwner {
        for (uint256 i = 0; i < btcAddresses.length; i++) {
            string memory btcAddr = btcAddresses[i];
            require(bytes(btcAddr).length > 0, "Empty BTC address");
            require(!btcExists[btcAddr], "Duplicate BTC address");

            dbCounter++;
            string memory dbKey = string(abi.encodePacked("DB", uintToStr(dbCounter)));

            dbEntries[dbKey] = DBEntry(btcAddr, 0, 0, block.timestamp, false);
            btcExists[btcAddr] = true;
        }
    }

 function sendRequest(string calldata dbKey) public returns (bytes32 requestId) {
        require(bytes(dbEntries[dbKey].btcAddress).length > 0, "Invalid DB key");

        string[] memory args = new string[](1);
        args[0] = dbEntries[dbKey].btcAddress;

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        req.setArgs(args);

          uint64 subscriptionId = 131;

        s_lastRequestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donID);
        storeRequestData(s_lastRequestId, dbKey, args[0]);
        return s_lastRequestId;
    }

    function storeRequestData(bytes32 requestId, string memory dbKey, string memory btcAddress) internal {
        requestCount++;
        requests[requestId] = RequestData(requestCount, dbKey, btcAddress, 0, 0, false);
        serialToRequestId[requestCount] = requestId;
        emit RequestStored(requestId, requestCount, dbKey, btcAddress);
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (s_lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId);
        }
        s_lastResponse = response;
        result = string(response);
        s_lastError = err;

        if (err.length == 0) {
            (uint256 balance, uint256 transactions) = parseResponse(result);
            RequestData storage reqData = requests[requestId];
            reqData.balance = balance;
            reqData.transactions = transactions;
            reqData.fulfilled = true;

            DBEntry storage entry = dbEntries[reqData.dbKey];
            entry.balance = balance;
            entry.transactions = transactions;
            entry.lastUpdated = block.timestamp;
            entry.fulfilled = true;

            emit RequestUpdated(requestId, reqData.dbKey, balance, transactions);
        }

        emit Response(requestId, result, s_lastResponse, s_lastError);
    }

    function getRequestData(bytes32 requestId) external view returns (RequestData memory) {
        return requests[requestId];
    }

    function getRequestDataBySerial(uint256 serialNumber) external view returns (RequestData memory) {
        bytes32 requestId = serialToRequestId[serialNumber];
        require(requestId != bytes32(0), "Invalid serial number");
        return requests[requestId];
    }

    function getDBEntry(string memory dbKey) external view returns (DBEntry memory) {
        return dbEntries[dbKey];
    }

    function parseResponse(string memory data) internal pure returns (uint256, uint256) {
        bytes memory b = bytes(data);
        uint256 balance;
        uint256 transactions;
        uint256 parsedResult;
        bool parsingBalance = true;

        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= "0" && b[i] <= "9") {
                parsedResult = parsedResult * 10 + (uint8(b[i]) - 48);
            } else if (b[i] == ",") {
                if (parsingBalance) {
                    balance = parsedResult;
                    parsedResult = 0;
                    parsingBalance = false;
                }
            }
        }
        transactions = parsedResult;
        return (balance, transactions);
    }

    function parseUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 resultValue;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] < "0" || b[i] > "9") {
                continue;
            }
            resultValue = resultValue * 10 + (uint8(b[i]) - 48);
        }
        return resultValue;
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
}