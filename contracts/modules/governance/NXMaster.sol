// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../../abstract/MasterAware.sol";
import "../../interfaces/IClaims.sol";
import "../../interfaces/IClaimsData.sol";
import "../../interfaces/IClaimsReward.sol";
import "../../interfaces/IMemberRoles.sol";
import "../../interfaces/IPool.sol";
import "../../interfaces/IQuotation.sol";
import "../../interfaces/IQuotationData.sol";
import "../../interfaces/ITokenController.sol";
import "../../interfaces/ITokenData.sol";
import "../capital/LegacyPoolData.sol";
import "./external/Governed.sol";
import "./external/OwnedUpgradeabilityProxy.sol";

contract NXMaster is INXMMaster, Governed {
  using SafeMath for uint;

  uint public _unused0;

  bytes2[] public contractCodes;
  mapping(address => bool) public contractsActive;
  mapping(bytes2 => address payable) internal contractAddresses;
  mapping(bytes2 => bool) public isProxy;
  mapping(bytes2 => bool) public isUpgradable;

  address public tokenAddress;
  bool internal reentrancyLock;
  bool public masterInitialized;
  address public owner;
  uint public _unused1;

  address public emergencyAdmin;
  bool public paused;

  modifier noReentrancy() {
    require(!reentrancyLock, "Reentrant call.");
    reentrancyLock = true;
    _;
    reentrancyLock = false;
  }

  modifier onlyEmergencyAdmin() {
    require(msg.sender == emergencyAdmin, "NXMaster: Not emergencyAdmin");
    _;
  }

  function upgradeMultipleImplementations(
    bytes2[] calldata _contractNames,
    address[] calldata _contractAddresses
  )
  external
  onlyAuthorizedToGovern
  {
    require(_contractNames.length == _contractAddresses.length, "Array length should be equal.");
    for (uint i = 0; i < _contractNames.length; i++) {
      require(_contractAddresses[i] != address(0), "null address is not allowed.");
      require(isProxy[_contractNames[i]], "Contract should be proxy.");
      OwnedUpgradeabilityProxy proxy = OwnedUpgradeabilityProxy(contractAddresses[_contractNames[i]]);
      proxy.upgradeTo(_contractAddresses[i]);
    }
  }

  /// @dev Adds new internal contract
  /// @param _contractName contract code for new contract
  /// @param _contractAddress contract address for new contract
  /// @param _type pass 1 if contract is upgradable, 2 if contract is proxy, any other uint if none.
  function addNewInternalContract(
    bytes2 _contractName,
    address payable _contractAddress,
    uint _type
  )
  external
  onlyAuthorizedToGovern {
    require(contractAddresses[_contractName] == address(0), "Contract code is already available.");
    require(_contractAddress != address(0), "NULL address is not allowed.");
    contractCodes.push(_contractName);
    address newInternalContract = _contractAddress;
    if (_type == 1) {
      isUpgradable[_contractName] = true;
    } else if (_type == 2) {
      newInternalContract = _generateProxy(_contractAddress);
      isProxy[_contractName] = true;
    }
    contractAddresses[_contractName] = address(uint160(newInternalContract));
    contractsActive[newInternalContract] = true;
    MasterAware up = MasterAware(contractAddresses[_contractName]);
    up.changeMasterAddress(address(this));
    up.changeDependentContractAddress();
  }

  /// @dev set Emergency pause
  /// @param _paused to toggle emergency pause ON/OFF
  function setEmergencyPause(bool _paused) public onlyEmergencyAdmin {
    paused = _paused;
  }

  /// @dev upgrades multiple contracts at a time
  function upgradeMultipleContracts(
    bytes2[] memory _contractsName,
    address payable[] memory _contractsAddress
  )
  public
  onlyAuthorizedToGovern
  {
    require(_contractsName.length == _contractsAddress.length, "Array length should be equal.");

    for (uint i = 0; i < _contractsName.length; i++) {

      address payable newAddress = _contractsAddress[i];
      require(newAddress != address(0), "NULL address is not allowed.");
      require(isUpgradable[_contractsName[i]], "Contract should be upgradable.");

      if (_contractsName[i] == "QT") {
        IQuotation qt = IQuotation(contractAddresses["QT"]);
        qt.transferAssetsToNewContract(newAddress);

      } else if (_contractsName[i] == "CR") {
        ITokenController tc = ITokenController(getLatestAddress("TC"));
        tc.addToWhitelist(newAddress);
        tc.removeFromWhitelist(contractAddresses["CR"]);
        IClaimsReward cr = IClaimsReward(contractAddresses["CR"]);
        cr.upgrade(newAddress);

      } else if (_contractsName[i] == "P1") {
        IPool p1 = IPool(contractAddresses["P1"]);
        p1.upgradeCapitalPool(newAddress);
      }

      address payable oldAddress = contractAddresses[_contractsName[i]];
      contractsActive[oldAddress] = false;
      contractAddresses[_contractsName[i]] = newAddress;
      contractsActive[newAddress] = true;

      MasterAware up = MasterAware(contractAddresses[_contractsName[i]]);
      up.changeMasterAddress(address(this));
    }

    _changeAllAddress();
  }

  /// @dev checks whether the address is an internal contract address.
  function isInternal(address _contractAddress) public view returns (bool) {
    return contractsActive[_contractAddress];
  }

  /// @dev checks whether the address is the Owner or not.
  function isOwner(address _address) public view returns (bool) {
    return owner == _address;
  }

  /// @dev Checks whether emergency pause id on/not.
  function isPause() public view returns (bool) {
    return paused;
  }

  /// @dev checks whether the address is a member of the mutual or not.
  function isMember(address _add) public view returns (bool) {
    IMemberRoles mr = IMemberRoles(getLatestAddress("MR"));
    return mr.checkRole(_add, uint(IMemberRoles.Role.Member));
  }

  /// @dev Gets latest version name and address
  /// @return contractsName Latest version's contract names
  /// @return contractsAddress Latest version's contract addresses
  function getVersionData()
  public
  view
  returns (
    bytes2[] memory contractsName,
    address[] memory contractsAddress
  )
  {
    contractsName = contractCodes;
    contractsAddress = new address[](contractCodes.length);

    for (uint i = 0; i < contractCodes.length; i++) {
      contractsAddress[i] = contractAddresses[contractCodes[i]];
    }
  }

  /**
   * @dev returns the address of token controller
   * @return address is returned
   */
  function dAppLocker() public view returns (address) {
    return getLatestAddress("TC");
  }

  /// @dev Gets latest contract address
  /// @param _contractName Contract name to fetch
  function getLatestAddress(bytes2 _contractName) public view returns (address payable contractAddress) {
    contractAddress = contractAddresses[_contractName];
  }

  /// @dev Creates a new version of contract addresses
  /// @param _contractAddresses Array of contract addresses which will be generated
  function addNewVersion(address payable[] memory _contractAddresses) public {

    require(msg.sender == owner && !masterInitialized, "Caller should be owner and should only be called once.");
    require(_contractAddresses.length == contractCodes.length, "array length not same");
    masterInitialized = true;

    IMemberRoles mr = IMemberRoles(_contractAddresses[14]);
    // shoud send proxy address for proxy contracts (if not 1st time deploying)
    // bool isMasterUpgrade = mr.nxMasterAddress() != address(0);

    for (uint i = 0; i < contractCodes.length; i++) {
      require(_contractAddresses[i] != address(0), "NULL address is not allowed.");
      contractAddresses[contractCodes[i]] = _contractAddresses[i];
      contractsActive[_contractAddresses[i]] = true;

    }

    // Need to override owner as owner in MR to avoid inconsistency as owner in MR is some other address.
    (, address[] memory mrOwner) = mr.members(uint(IMemberRoles.Role.Owner));
    owner = mrOwner[0];
  }

  /**
   * @dev to check if the address is authorized to govern or not
   * @param _add is the address in concern
   * @return the boolean status status for the check
   */
  function checkIsAuthToGoverned(address _add) public view returns (bool) {
    return isAuthorizedToGovern(_add);
  }

  /**
   * @dev to update the owner parameters
   * @param code is the associated code
   * @param val is value to be set
   */
  function updateOwnerParameters(bytes8 code, address payable val) public onlyAuthorizedToGovern {
    IQuotationData qd;
    LegacyPoolData pd;
    if (code == "MSWALLET") {
      ITokenData td;
      td = ITokenData(getLatestAddress("TD"));
      td.changeWalletAddress(val);

    } else if (code == "MCRNOTA") {

      pd = LegacyPoolData(getLatestAddress("PD"));
      pd.changeNotariseAddress(val);

    } else if (code == "OWNER") {

      IMemberRoles mr = IMemberRoles(getLatestAddress("MR"));
      mr.swapOwner(val);
      owner = val;

    } else if (code == "QUOAUTH") {

      qd = IQuotationData(getLatestAddress("QD"));
      qd.changeAuthQuoteEngine(val);

    } else if (code == "KYCAUTH") {
      qd = IQuotationData(getLatestAddress("QD"));
      qd.setKycAuthAddress(val);

    } else if (code == "EMADMIN") {
      emergencyAdmin = val;
    } else {
      revert("Invalid param code");
    }
  }

  /**
   * @dev to generater proxy
   * @param _implementationAddress of the proxy
   */
  function _generateProxy(address _implementationAddress) internal returns (address) {
    OwnedUpgradeabilityProxy proxy = new OwnedUpgradeabilityProxy(_implementationAddress);
    return address(proxy);
  }

  /// @dev Sets the older versions of contract addresses as inactive and the latest one as active.
  function _changeAllAddress() internal {
    for (uint i = 0; i < contractCodes.length; i++) {
      contractsActive[contractAddresses[contractCodes[i]]] = true;
      MasterAware up = MasterAware(contractAddresses[contractCodes[i]]);
      up.changeDependentContractAddress();
    }
  }
}
