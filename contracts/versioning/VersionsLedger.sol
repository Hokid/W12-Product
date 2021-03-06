pragma solidity ^0.4.24;

// https://semver.org. Version represent as decimal number, 4 decimals per part, max 9999 9999 9999
// 1.1.1 => 100010001

contract VersionsLedger {
    address public owner;

    // all versions in net
    uint[] public versions;

    // use only one main address to map version
    mapping(uint => address) public addressByVersion;
    mapping(address => uint) public versionByAddress;

    modifier restricted() {
        if (msg.sender == owner) _;
    }

    constructor() public {
        owner = msg.sender;
    }

    function setVersion(address _address, uint version) public restricted returns (bool result) {
        // already exists
        if (addressByVersion[version] != address(0)) return;

        // wrong order
        (uint lastV, bool found) = getLastVersion();

        if (found && lastV > version) return;

        versions.push(version);
        addressByVersion[version] = _address;
        versionByAddress[_address] = version;

        result = true;
    }

    function getVersions() public view returns (uint[]) {
        return versions;
    }

    function getAddresses() public view returns (address[]) {
        if (versions.length == 0) return;

        address[] storage result;

        for (uint i = 0; i < versions.length; i++) {
            result.push(addressByVersion[versions[i]]);
        }

        return result;
    }

    function getLastVersion() public view returns (uint version, bool found) {
        if (versions.length == 0) return;

        found = true;
        version = versions[versions.length - 1];
    }
}
