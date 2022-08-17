pragma solidity 0.6.4;

import "./System.sol";
import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./interface/IApplication.sol";
import "./interface/ICrossChain.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ITokenHub.sol";
import "./lib/CmnPkg.sol";
import "./lib/SafeMath.sol";
import "./lib/RLPEncode.sol";
import "./lib/RLPDecode.sol";
import "./interface/IStaking.sol";

contract Staking is IStaking, System, IParamSubscriber, IApplication {
  using SafeMath for uint256;
  using RLPEncode for *;
  using RLPDecode for *;

  // Cross Stake Event type
  uint8 public constant EVENT_DELEGATE = 0x01;
  uint8 public constant EVENT_UNDELEGATE = 0x02;
  uint8 public constant EVENT_REDELEGATE = 0x03;
  uint8 public constant EVENT_DISTRIBUTE_REWARD = 0x04;
  uint8 public constant EVENT_DISTRIBUTE_UNDELEGATED = 0x05;

  // Error code
  uint32 public constant ERROR_WITHDRAW_BNB = 101;

  uint256 public constant TEN_DECIMALS = 1e10;

  uint256 public constant INIT_ORACLE_RELAYER_FEE = 6e15;
  uint256 public constant INIT_MIN_DELEGATION = 100 * 1e18;

  uint256 public oracleRelayerFee;
  uint256 public minDelegation;

  mapping(address => uint256) delegated; // delegator => totalAmount
  mapping(address => mapping(address => uint256)) delegatedOfValidator; // delegator => validator => amount
  mapping(address => uint256) distributedReward; // delegator => reward
  mapping(address => mapping(address => uint256)) pendingUndelegateTime; // delegator => validator => minTime
  mapping(address => uint256) undelegated; // delegator => totalUndelegated
  mapping(address => mapping(address => mapping(address => uint256))) pendingRedelegateTime; // delegator => srcValidator => dstValidator => minTime

  bool internal locked;

  modifier noReentrant() {
    require(!locked, "No re-entrancy");
    locked = true;
    _;
    locked = false;
  }

  modifier tenDecimalPrecision(uint256 amount) {
    require(msg.value%TEN_DECIMALS==0 && amount%TEN_DECIMALS==0, "precision loss in conversion");
    _;
  }

  modifier initParams() {
    if (!alreadyInit) {
      oracleRelayerFee = INIT_ORACLE_RELAYER_FEE;
      minDelegation = INIT_MIN_DELEGATION;
      alreadyInit = true;
    }
    _;
  }

  /*********************************** Events **********************************/
  event delegateSubmitted(address indexed delegator, address indexed validator, uint256 amount, uint256 oracleRelayerFee);
  event undelegateSubmitted(address indexed delegator, address indexed validator, uint256 amount, uint256 oracleRelayerFee);
  event redelegateSubmitted(address indexed delegator, address indexed validatorSrc, address indexed validatorDst, uint256 amount, uint256 oracleRelayerFee);
  event rewardReceived(address indexed delegator, uint256 amount);
  event rewardClaimed(address indexed delegator, uint256 amount);
  event undelegatedReceived(address indexed delegator, address indexed validator, uint256 amount);
  event undelegatedClaimed(address indexed delegator, uint256 amount);
  event failedDelegate(address indexed delegator, address indexed validator, uint256 amount, uint8 errCode);
  event failedUndelegate(address indexed delegator, address indexed validator, uint256 amount, uint8 errCode);
  event failedRedelegate(address indexed delegator, address indexed valSrc, address indexed valDst, uint256 amount, uint8 errCode);
  event paramChange(string key, bytes value);
  event failedSynPackage(uint8 indexed eventType, uint256 errCode);
  event crashResponse(uint8 indexed eventType);

  receive() external payable {}

  /************************* Implement cross chain app *************************/
  function handleSynPackage(uint8, bytes calldata msgBytes) external onlyCrossChainContract initParams override returns(bytes memory) {
    RLPDecode.Iterator memory iter = msgBytes.toRLPItem().iterator();
    uint8 eventType = uint8(iter.next().toUint());
    uint32 resCode;
    bytes memory ackPackage;
    if (eventType == EVENT_DISTRIBUTE_REWARD) {
      (resCode, ackPackage) = _handleDistributeRewardSynPackage(iter);
    } else if (eventType == EVENT_DISTRIBUTE_UNDELEGATED) {
      (resCode, ackPackage) = _handleDistributeUndelegatedSynPackage(iter);
    } else {
      require(false, "unknown event type");
    }

    if (resCode != CODE_OK) {
      emit failedSynPackage(eventType, resCode);
    }
    return ackPackage;
  }

  function handleAckPackage(uint8, bytes calldata msgBytes) external onlyCrossChainContract initParams override {
    RLPDecode.Iterator memory iter = msgBytes.toRLPItem().iterator();
    uint8 eventType = uint8(iter.next().toUint());
    if (eventType == EVENT_DELEGATE) {
      _handleDelegateAckPackage(iter);
    } else if (eventType == EVENT_UNDELEGATE) {
      _handleUndelegateAckPackage(iter);
    } else if (eventType == EVENT_REDELEGATE) {
      _handleRedelegateAckPackage(iter);
    } else {
      require(false, "unknown event type");
    }
    return;
  }

  function handleFailAckPackage(uint8, bytes calldata msgBytes) external onlyCrossChainContract initParams override {
    RLPDecode.Iterator memory iter = msgBytes.toRLPItem().iterator();
    uint8 eventType = uint8(iter.next().toUint());
    if (eventType == EVENT_DELEGATE) {
      _handleDelegateFailAckPackage(iter);
    } else if (eventType == EVENT_UNDELEGATE) {
      _handleUndelegateFailAckPackage(iter);
    } else if (eventType == EVENT_REDELEGATE) {
      _handleRedelegateFailAckPackage(iter);
    } else {
      require(false, "unknown event type");
    }
    return;
  }

  /***************************** External functions *****************************/
  function delegate(address validator, uint256 amount) override external payable tenDecimalPrecision(amount) initParams {
    require(amount >= minDelegation, "invalid delegate amount");
    require(msg.value >= amount.add(oracleRelayerFee), "not enough msg value");
    require(payable(msg.sender).send(0), "invalid delegator"); // the msg sender must be payable

    uint256 convertedAmount = amount.div(TEN_DECIMALS); // native bnb decimals is 8 on BBC, while the native bnb decimals on BSC is 18
    uint256 _oracleRelayerFee = (msg.value).sub(amount);

    bytes[] memory elements = new bytes[](3);
    elements[0] = msg.sender.encodeAddress();
    elements[1] = validator.encodeAddress();
    elements[2] = convertedAmount.encodeUint();
    bytes memory msgBytes = elements.encodeList();
    ICrossChain(CROSS_CHAIN_CONTRACT_ADDR).sendSynPackage(CROSS_STAKE_CHANNELID, _RLPEncode(EVENT_DELEGATE, msgBytes), _oracleRelayerFee.div(TEN_DECIMALS));
    payable(TOKEN_HUB_ADDR).transfer(msg.value);

    delegated[msg.sender] = delegated[msg.sender].add(amount);
    delegatedOfValidator[msg.sender][validator] = delegatedOfValidator[msg.sender][validator].add(amount);

    emit delegateSubmitted(msg.sender, validator, amount, _oracleRelayerFee);
  }

  function undelegate(address validator, uint256 amount) override external payable tenDecimalPrecision(amount) initParams {
    require(msg.value >= oracleRelayerFee, "not enough relay fee");
    if (amount < minDelegation) {
      require(amount >= oracleRelayerFee, "not enough funds");
      require(amount == delegatedOfValidator[msg.sender][validator], "invalid amount");
    }
    require(block.timestamp >= pendingUndelegateTime[msg.sender][validator], "pending undelegation exist");
    delegatedOfValidator[msg.sender][validator] = delegatedOfValidator[msg.sender][validator].sub(amount, "not enough funds");

    uint256 convertedAmount = amount.div(TEN_DECIMALS); // native bnb decimals is 8 on BBC, while the native bnb decimals on BSC is 18
    uint256 _oracleRelayerFee = msg.value;

    bytes[] memory elements = new bytes[](3);
    elements[0] = msg.sender.encodeAddress();
    elements[1] = validator.encodeAddress();
    elements[2] = convertedAmount.encodeUint();
    bytes memory msgBytes = elements.encodeList();
    ICrossChain(CROSS_CHAIN_CONTRACT_ADDR).sendSynPackage(CROSS_STAKE_CHANNELID, _RLPEncode(EVENT_UNDELEGATE, msgBytes), _oracleRelayerFee.div(TEN_DECIMALS));
    payable(TOKEN_HUB_ADDR).transfer(_oracleRelayerFee);

    delegated[msg.sender] = delegated[msg.sender].sub(amount);
    pendingUndelegateTime[msg.sender][validator] = block.timestamp.add(691200); // 8*24*3600

    emit undelegateSubmitted(msg.sender, validator, amount, _oracleRelayerFee);
  }

  function redelegate(address validatorSrc, address validatorDst, uint256 amount) override external payable tenDecimalPrecision(amount) initParams {
    require(validatorSrc != validatorDst, "invalid redelegation");
    require(msg.value >= oracleRelayerFee, "not enough relay fee");
    require(amount >= minDelegation, "invalid amount");
    require(block.timestamp >= pendingRedelegateTime[msg.sender][validatorSrc][validatorDst] &&
      block.timestamp >= pendingRedelegateTime[msg.sender][validatorDst][validatorSrc], "pending redelegation exist");
    delegatedOfValidator[msg.sender][validatorSrc] = delegatedOfValidator[msg.sender][validatorSrc].sub(amount, "not enough funds");
    delegatedOfValidator[msg.sender][validatorDst] = delegatedOfValidator[msg.sender][validatorDst].add(amount);

    uint256 convertedAmount = amount.div(TEN_DECIMALS);// native bnb decimals is 8 on BBC, while the native bnb decimals on BSC is 18
    uint256 _oracleRelayerFee = msg.value;

    bytes[] memory elements = new bytes[](4);
    elements[0] = msg.sender.encodeAddress();
    elements[1] = validatorSrc.encodeAddress();
    elements[2] = validatorDst.encodeAddress();
    elements[3] = convertedAmount.encodeUint();
    bytes memory msgBytes = elements.encodeList();
    ICrossChain(CROSS_CHAIN_CONTRACT_ADDR).sendSynPackage(CROSS_STAKE_CHANNELID, _RLPEncode(EVENT_REDELEGATE, msgBytes), _oracleRelayerFee.div(TEN_DECIMALS));
    payable(TOKEN_HUB_ADDR).transfer(_oracleRelayerFee);

    pendingRedelegateTime[msg.sender][validatorSrc][validatorDst] = block.timestamp.add(691200); // 8*24*3600
    pendingRedelegateTime[msg.sender][validatorDst][validatorSrc] = block.timestamp.add(691200); // 8*24*3600

    emit redelegateSubmitted(msg.sender, validatorSrc, validatorDst, amount, _oracleRelayerFee);
  }

  function claimReward() override external noReentrant returns(uint256 amount) {
    require(distributedReward[msg.sender] > 0, "no pending reward");

    amount = distributedReward[msg.sender];
    distributedReward[msg.sender] = 0;
    payable(msg.sender).transfer(amount);
    emit rewardClaimed(msg.sender, amount);
  }

  function claimUndeldegated() override external noReentrant returns(uint256 amount) {
    require(undelegated[msg.sender] > 0, "no undelegated funds");

    amount = undelegated[msg.sender];
    undelegated[msg.sender] = 0;
    payable(msg.sender).transfer(amount);
    emit undelegatedClaimed(msg.sender, amount);
  }

  function getDelegated(address delegator, address validator) override external view returns(uint256) {
    return delegatedOfValidator[delegator][validator];
  }

  function getTotalDelegated(address delegator) override external view returns(uint256) {
    return delegated[delegator];
  }

  function getDistributedReward(address delegator) override external view returns(uint256) {
    return distributedReward[delegator];
  }

  function getPendingRedelegateTime(address delegator, address valSrc, address valDst) override external view returns(uint256) {
    return pendingRedelegateTime[delegator][valSrc][valDst];
  }

  function getUndelegated(address delegator) override external view returns(uint256) {
    return undelegated[delegator];
  }

  function getPendingUndelegateTime(address delegator, address validator) override external view returns(uint256) {
    return pendingUndelegateTime[delegator][validator];
  }

  function getOracleRelayerFee() override external view returns(uint256) {
    return oracleRelayerFee;
  }

  function getMinDelegation() override external view returns(uint256) {
    return minDelegation;
  }

  /***************************** Internal functions *****************************/
  function _RLPEncode(uint8 eventType, bytes memory msgBytes) internal pure returns(bytes memory output) {
    bytes[] memory elements = new bytes[](2);
    elements[0] = eventType.encodeUint();
    elements[1] = msgBytes.encodeBytes();
    output = elements.encodeList();
  }

  function _encodeRefundPackage(uint8 eventType, uint256 amount, address recipient, uint32 errorCode) internal pure returns(uint32, bytes memory) {
    amount = amount.div(TEN_DECIMALS);
    bytes[] memory elements = new bytes[](4);
    elements[0] = eventType.encodeUint();
    elements[1] = amount.encodeUint();
    elements[2] = recipient.encodeAddress();
    elements[3] = errorCode.encodeUint();
    bytes memory packageBytes = elements.encodeList();
    return (errorCode, packageBytes);
  }

  /******************************** Param update ********************************/
  function updateParam(string calldata key, bytes calldata value) override external onlyInit onlyGov {
    if (Memory.compareStrings(key, "oracleRelayerFee")) {
      require(value.length == 32, "length of oracleRelayerFee mismatch");
      uint256 newOracleRelayerFee = BytesToTypes.bytesToUint256(32, value);
      require(newOracleRelayerFee >0, "the oracleRelayerFee must be greater than 0");
      oracleRelayerFee = newOracleRelayerFee;
    } else if (Memory.compareStrings(key, "minDelegation")) {
      require(value.length == 32, "length of minDelegation mismatch");
      uint256 newMinDelegation = BytesToTypes.bytesToUint256(32, value);
      require(newMinDelegation > 0, "the minDelegation must be greater than 0");
      minDelegation = newMinDelegation;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }

  /************************* Handle cross-chain package *************************/
  function _handleDelegateAckPackage(RLPDecode.Iterator memory iter) internal {
    bool success = false;
    uint256 idx = 0;
    address delegator;
    address validator;
    uint256 amount;
    uint8 errCode;
    while (iter.hasNext()) {
      if (idx == 0) {
        delegator = address(uint160(iter.next().toAddress()));
      } else if (idx == 1) {
        validator = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        amount = uint256(iter.next().toUint());
      } else if (idx == 3) {
        errCode = uint8(iter.next().toUint());
        success = true;
      } else {
        break;
      }
      idx++;
    }
    require(success, "rlp decode package failed");

    require(ITokenHub(TOKEN_HUB_ADDR).withdrawStakingBNB(amount), "withdraw from tokenhub failed");

    delegated[delegator] = delegated[delegator].sub(amount);
    undelegated[delegator] = undelegated[delegator].add(amount);
    delegatedOfValidator[delegator][validator] = delegatedOfValidator[delegator][validator].sub(amount);

    emit failedDelegate(delegator, validator, amount, errCode);
  }

  function _handleDelegateFailAckPackage(RLPDecode.Iterator memory paramBytes) internal {
    RLPDecode.Iterator memory iter;
    if (paramBytes.hasNext()) {
      iter = paramBytes.next().toBytes().toRLPItem().iterator();
    } else {
      require(false, "empty fail ack package");
    }

    bool success = false;
    uint256 idx = 0;
    address delegator;
    address validator;
    uint256 bcAmount;
    while (iter.hasNext()) {
      if (idx == 0) {
        delegator = address(uint160(iter.next().toAddress()));
      } else if (idx == 1) {
        validator = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        bcAmount = uint256(iter.next().toUint());
        success = true;
      } else {
        break;
      }
      idx++;
    }
    require(success, "rlp decode package failed");

    uint256 amount = bcAmount.mul(TEN_DECIMALS);
    require(ITokenHub(TOKEN_HUB_ADDR).withdrawStakingBNB(amount), "withdraw from tokenhub failed");

    delegated[delegator] = delegated[delegator].sub(amount);
    undelegated[delegator] = undelegated[delegator].add(amount);
    delegatedOfValidator[delegator][validator] = delegatedOfValidator[delegator][validator].sub(amount);

    emit crashResponse(EVENT_DELEGATE);
  }

  function _handleUndelegateAckPackage(RLPDecode.Iterator memory iter) internal {
    bool success = false;
    uint256 idx = 0;
    address delegator;
    address validator;
    uint256 amount;
    uint8 errCode;
    while (iter.hasNext()) {
      if (idx == 0) {
        delegator = address(uint160(iter.next().toAddress()));
      } else if (idx == 1) {
        validator = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        amount = uint256(iter.next().toUint());
      } else if (idx == 3) {
        errCode = uint8(iter.next().toUint());
        success = true;
      } else {
        break;
      }
      idx++;
    }
    require(success, "rlp decode package failed");

    delegated[delegator] = delegated[delegator].add(amount);
    delegatedOfValidator[delegator][validator] = delegatedOfValidator[delegator][validator].add(amount);
    pendingUndelegateTime[delegator][validator] = 0;

    emit failedUndelegate(delegator, validator, amount, errCode);
  }

  function _handleUndelegateFailAckPackage(RLPDecode.Iterator memory paramBytes) internal {
    RLPDecode.Iterator memory iter;
    if (paramBytes.hasNext()) {
      iter = paramBytes.next().toBytes().toRLPItem().iterator();
    } else {
      require(false, "empty fail ack package");
    }

    bool success = false;
    uint256 idx = 0;
    address delegator;
    address validator;
    uint256 bcAmount;
    while (iter.hasNext()) {
      if (idx == 0) {
        delegator = address(uint160(iter.next().toAddress()));
      } else if (idx == 1) {
        validator = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        bcAmount = uint256(iter.next().toUint());
        success = true;
      } else {
        break;
      }
      idx++;
    }
    require(success, "rlp decode package failed");

    uint256 amount = bcAmount.mul(TEN_DECIMALS);
    delegated[delegator] = delegated[delegator].add(amount);
    delegatedOfValidator[delegator][validator] = delegatedOfValidator[delegator][validator].add(amount);
    pendingUndelegateTime[delegator][validator] = 0;

    emit crashResponse(EVENT_UNDELEGATE);
  }

  function _handleRedelegateAckPackage(RLPDecode.Iterator memory iter) internal {
    bool success = false;
    uint256 idx = 0;
    address delegator;
    address valSrc;
    address valDst;
    uint256 amount;
    uint8 errCode;
    while (iter.hasNext()) {
      if (idx == 0) {
        delegator = address(uint160(iter.next().toAddress()));
      } else if (idx == 1) {
        valSrc = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        valDst = address(uint160(iter.next().toAddress()));
      } else if (idx == 3) {
        amount = uint256(iter.next().toUint());
      } else if (idx == 4) {
        errCode = uint8(iter.next().toUint());
        success = true;
      } else {
        break;
      }
      idx++;
    }
    require(success, "rlp decode package failed");

    delegatedOfValidator[delegator][valSrc] = delegatedOfValidator[delegator][valSrc].add(amount);
    delegatedOfValidator[delegator][valDst] = delegatedOfValidator[delegator][valDst].sub(amount);
    pendingRedelegateTime[delegator][valSrc][valDst] = 0;
    pendingRedelegateTime[delegator][valDst][valSrc] = 0;

    emit failedRedelegate(delegator, valSrc, valDst, amount, errCode);
  }

  function _handleRedelegateFailAckPackage(RLPDecode.Iterator memory paramBytes) internal {
    RLPDecode.Iterator memory iter;
    if (paramBytes.hasNext()) {
      iter = paramBytes.next().toBytes().toRLPItem().iterator();
    } else {
      require(false, "empty fail ack package");
    }

    bool success = false;
    uint256 idx = 0;
    address delegator;
    address valSrc;
    address valDst;
    uint256 bcAmount;
    while (iter.hasNext()) {
      if (idx == 0) {
        delegator = address(uint160(iter.next().toAddress()));
      } else if (idx == 1) {
        valSrc = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        valDst = address(uint160(iter.next().toAddress()));
      } else if (idx == 3) {
        bcAmount = uint256(iter.next().toUint());
        success = true;
      } else {
        break;
      }
      idx++;
    }
    require(success, "rlp decode package failed");

    uint256 amount = bcAmount.mul(TEN_DECIMALS);
    delegatedOfValidator[delegator][valSrc] = delegatedOfValidator[delegator][valSrc].add(amount);
    delegatedOfValidator[delegator][valDst] = delegatedOfValidator[delegator][valDst].sub(amount);
    pendingRedelegateTime[delegator][valSrc][valDst] = 0;
    pendingRedelegateTime[delegator][valDst][valSrc] = 0;

    emit crashResponse(EVENT_REDELEGATE);
  }

  function _handleDistributeRewardSynPackage(RLPDecode.Iterator memory iter) internal returns(uint32, bytes memory) {
    bool success = false;
    uint256 idx = 0;
    uint256 amount;
    address recipient;
    while (iter.hasNext()) {
      if (idx == 0) {
        amount = uint256(iter.next().toUint());
      } else if (idx == 1) {
        recipient = address(uint160(iter.next().toAddress()));
        success = true;
      } else {
        break;
      }
      idx++;
    }
    if (!success) {
      return _encodeRefundPackage(EVENT_DISTRIBUTE_REWARD, amount, recipient, ERROR_FAIL_DECODE);
    }

    bool ok = ITokenHub(TOKEN_HUB_ADDR).withdrawStakingBNB(amount);
    if (!ok) {
      return _encodeRefundPackage(EVENT_DISTRIBUTE_REWARD, amount, recipient, ERROR_WITHDRAW_BNB);
    }

    distributedReward[recipient] = distributedReward[recipient].add(amount);

    emit rewardReceived(recipient, amount);
    return (CODE_OK, new bytes(0));
  }

  function _handleDistributeUndelegatedSynPackage(RLPDecode.Iterator memory iter) internal returns(uint32, bytes memory) {
    bool success = false;
    uint256 idx = 0;
    uint256 amount;
    address recipient;
    address validator;
    while (iter.hasNext()) {
      if (idx == 0) {
        amount = uint256(iter.next().toUint());
      } else if (idx == 1) {
        recipient = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        validator = address(uint160(iter.next().toAddress()));
        success = true;
      } else {
        break;
      }
      idx++;
    }
    if (!success) {
      return _encodeRefundPackage(EVENT_DISTRIBUTE_UNDELEGATED, amount, recipient, ERROR_FAIL_DECODE);
    }

    bool ok = ITokenHub(TOKEN_HUB_ADDR).withdrawStakingBNB(amount);
    if (!ok) {
      return _encodeRefundPackage(EVENT_DISTRIBUTE_UNDELEGATED, amount, recipient, ERROR_WITHDRAW_BNB);
    }

    pendingUndelegateTime[recipient][validator] = 0;
    undelegated[recipient] = undelegated[recipient].add(amount);

    emit undelegatedReceived(recipient, validator, amount);
    return (CODE_OK, new bytes(0));
  }
}