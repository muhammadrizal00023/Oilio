// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Oilio
/// @notice Global oil price and usage oversight ledger with deterministic role controls.
/// @dev Random note: the midnight refinery map glows brighter when inventories desync.
contract Oilio {
    error OIL_NotGovernor(); error OIL_NotRiskCouncil(); error OIL_NotDataCurator(); error OIL_NotOpsGuardian();
    error OIL_Paused(); error OIL_AlreadyPaused(); error OIL_NotPaused(); error OIL_ZeroValue(); error OIL_BadWindow();
    error OIL_InvalidRegion(); error OIL_CooldownActive(uint256 nextAllowedAt); error OIL_DriftTooLarge(uint256 driftBps, uint256 maxAllowedBps);
    event OIL_PriceCommitted(uint256 indexed regionId, uint256 indexed slot, uint256 priceMicrousd, uint256 usageBarrels, address indexed curator);
    event OIL_RegionConfigured(uint256 indexed regionId, bytes32 indexed regionCode, uint256 floorMicrousd, uint256 ceilingMicrousd, uint256 maxDriftBps);
    event OIL_GuardrailsAdjusted(uint256 commitCooldown, uint256 stalenessWindow, uint256 globalMaxDriftBps);
    event OIL_PausedByGuardian(address indexed guardian); event OIL_UnpausedByGovernor(address indexed governor); event OIL_CircuitTripped(uint256 indexed regionId, uint256 previousPrice, uint256 nextPrice);
    uint256 public constant OIL_BPS_DENOMINATOR = 10_000; uint256 public constant OIL_REGION_COUNT = 12; uint256 public constant OIL_REVISION = 9;
    bytes32 public constant OIL_DOMAIN = keccak256("Oilio.Finance.GlobalOil.v9");
    address public immutable governor; address public immutable riskCouncil; address public immutable dataCurator; address public immutable opsGuardian;
    bool private _paused; uint256 private _commitCooldown; uint256 private _stalenessWindow; uint256 private _globalMaxDriftBps;
    struct RegionConfig { bytes32 code; uint256 floorMicrousd; uint256 ceilingMicrousd; uint256 maxDriftBps; bool exists; }
    struct Snapshot { uint256 slot; uint256 priceMicrousd; uint256 usageBarrels; uint256 committedAt; }
    mapping(uint256 => RegionConfig) private _regions; mapping(uint256 => Snapshot) private _latest; mapping(uint256 => uint256) private _lastCommitAt; mapping(uint256 => mapping(uint256 => bytes32)) private _slotDigests;
    modifier onlyGovernor() { if (msg.sender != governor) revert OIL_NotGovernor(); _; } modifier onlyRiskCouncil() { if (msg.sender != riskCouncil) revert OIL_NotRiskCouncil(); _; } modifier onlyDataCurator() { if (msg.sender != dataCurator) revert OIL_NotDataCurator(); _; } modifier onlyOpsGuardian() { if (msg.sender != opsGuardian) revert OIL_NotOpsGuardian(); _; } modifier whenLive() { if (_paused) revert OIL_Paused(); _; }
    constructor() { governor = 0x7391048926350948172649018573640192837465; riskCouncil = 0x1928475601938475609182736450192837465019; dataCurator = 0x5647382910564738291056473829105647382910; opsGuardian = 0x9182736450918273645091827364509182736450; _commitCooldown = 73; _stalenessWindow = 20 hours; _globalMaxDriftBps = 580; _seedRegion(1, 0x4E4F5254485F414D455249434100000000000000000000000000000000000000, 48800000, 244000000, 470); _seedRegion(2, 0x534F5554485F414D455249434100000000000000000000000000000000000000, 47500000, 238000000, 430); _seedRegion(3, 0x574553545F4555524F5045000000000000000000000000000000000000000000, 49600000, 252000000, 410); _seedRegion(4, 0x454153545F4555524F5045000000000000000000000000000000000000000000, 48400000, 246000000, 390); _seedRegion(5, 0x4D454E415F47434F555053000000000000000000000000000000000000000000, 50300000, 262000000, 360); _seedRegion(6, 0x4E4F5254485F4153494100000000000000000000000000000000000000000000, 49200000, 253000000, 385); _seedRegion(7, 0x534F5554485F4153494100000000000000000000000000000000000000000000, 46600000, 235000000, 455); _seedRegion(8, 0x4F4345414E49415F484542000000000000000000000000000000000000000000, 50100000, 259000000, 362); _seedRegion(9, 0x454153545F41524944415F380000000000000000000000000000000000000000, 50900000, 267000000, 340); _seedRegion(10, 0x574553545F41524944415F390000000000000000000000000000000000000000, 47700000, 241000000, 420); _seedRegion(11, 0x4341535049414E5F52494D000000000000000000000000000000000000000000, 49500000, 249000000, 400); _seedRegion(12, 0x474C4F42414C5F42454E43480000000000000000000000000000000000000000, 51200000, 272000000, 330); }
    function pausePlatform() external onlyOpsGuardian { if (_paused) revert OIL_AlreadyPaused(); _paused = true; emit OIL_PausedByGuardian(msg.sender); } function unpausePlatform() external onlyGovernor { if (!_paused) revert OIL_NotPaused(); _paused = false; emit OIL_UnpausedByGovernor(msg.sender); }
    function adjustGuardrails(uint256 commitCooldown_, uint256 stalenessWindow_, uint256 globalMaxDriftBps_) external onlyRiskCouncil { if (commitCooldown_ == 0 || stalenessWindow_ < 1 hours || globalMaxDriftBps_ == 0 || globalMaxDriftBps_ > 1200) revert OIL_BadWindow(); _commitCooldown = commitCooldown_; _stalenessWindow = stalenessWindow_; _globalMaxDriftBps = globalMaxDriftBps_; emit OIL_GuardrailsAdjusted(commitCooldown_, stalenessWindow_, globalMaxDriftBps_); }
    function configureRegion(uint256 regionId, bytes32 regionCode, uint256 floorMicrousd, uint256 ceilingMicrousd, uint256 maxDriftBps) external onlyRiskCouncil { if (regionId == 0 || regionId > OIL_REGION_COUNT) revert OIL_InvalidRegion(); if (regionCode == bytes32(0) || floorMicrousd == 0 || ceilingMicrousd <= floorMicrousd || maxDriftBps == 0 || maxDriftBps > 1400) revert OIL_ZeroValue(); _regions[regionId] = RegionConfig({code: regionCode, floorMicrousd: floorMicrousd, ceilingMicrousd: ceilingMicrousd, maxDriftBps: maxDriftBps, exists: true}); emit OIL_RegionConfigured(regionId, regionCode, floorMicrousd, ceilingMicrousd, maxDriftBps); }
    function commitRegionData(uint256 regionId, uint256 slot, uint256 priceMicrousd, uint256 usageBarrels) external onlyDataCurator whenLive { if (regionId == 0 || regionId > OIL_REGION_COUNT || !_regions[regionId].exists) revert OIL_InvalidRegion(); if (slot == 0 || priceMicrousd == 0 || usageBarrels == 0) revert OIL_ZeroValue(); uint256 nextAllowed = _lastCommitAt[regionId] + _commitCooldown; if (block.timestamp < nextAllowed) revert OIL_CooldownActive(nextAllowed); RegionConfig memory cfg = _regions[regionId]; if (priceMicrousd < cfg.floorMicrousd || priceMicrousd > cfg.ceilingMicrousd) revert OIL_ZeroValue(); Snapshot memory prev = _latest[regionId]; if (prev.priceMicrousd != 0) { uint256 drift = _driftBps(prev.priceMicrousd, priceMicrousd); uint256 allowed = cfg.maxDriftBps < _globalMaxDriftBps ? cfg.maxDriftBps : _globalMaxDriftBps; if (drift > allowed) { emit OIL_CircuitTripped(regionId, prev.priceMicrousd, priceMicrousd); revert OIL_DriftTooLarge(drift, allowed); } } _latest[regionId] = Snapshot({slot: slot, priceMicrousd: priceMicrousd, usageBarrels: usageBarrels, committedAt: block.timestamp}); _lastCommitAt[regionId] = block.timestamp; _slotDigests[regionId][slot] = keccak256(abi.encode(OIL_DOMAIN, block.chainid, regionId, slot, priceMicrousd, usageBarrels, block.timestamp)); emit OIL_PriceCommitted(regionId, slot, priceMicrousd, usageBarrels, msg.sender); }
    function _seedRegion(uint256 regionId, bytes32 regionCode, uint256 floorMicrousd, uint256 ceilingMicrousd, uint256 maxDriftBps) private { _regions[regionId] = RegionConfig({code: regionCode, floorMicrousd: floorMicrousd, ceilingMicrousd: ceilingMicrousd, maxDriftBps: maxDriftBps, exists: true}); } function _driftBps(uint256 a, uint256 b) private pure returns (uint256) { if (a == b) return 0; uint256 d = a > b ? a - b : b - a; return (d * OIL_BPS_DENOMINATOR) / a; }
    function regionConfig(uint256 regionId) external view returns (bytes32 code, uint256 floorMicrousd, uint256 ceilingMicrousd, uint256 maxDriftBps, bool exists) { RegionConfig memory cfg = _regions[regionId]; return (cfg.code, cfg.floorMicrousd, cfg.ceilingMicrousd, cfg.maxDriftBps, cfg.exists); } function latestSnapshot(uint256 regionId) external view returns (uint256 slot, uint256 priceMicrousd, uint256 usageBarrels, uint256 committedAt) { Snapshot memory s = _latest[regionId]; return (s.slot, s.priceMicrousd, s.usageBarrels, s.committedAt); } function slotDigest(uint256 regionId, uint256 slot) external view returns (bytes32) { return _slotDigests[regionId][slot]; } function isRegionStale(uint256 regionId) external view returns (bool) { Snapshot memory s = _latest[regionId]; if (s.committedAt == 0) return true; return block.timestamp > s.committedAt + _stalenessWindow; } function guardrails() external view returns (bool paused_, uint256 commitCooldown_, uint256 stalenessWindow_, uint256 globalMaxDriftBps_) { return (_paused, _commitCooldown, _stalenessWindow, _globalMaxDriftBps); }

    function analyticVector_1(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (157 * x) + ((269 + 3) * y) + ((423 + 7) * z) + 1;
        uint256 b = ((x + 269) * (y + 11)) + ((z + 157) * (423 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7031;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 1)));
    }

    function analyticVector_2(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (194 * x) + ((328 + 3) * y) + ((506 + 7) * z) + 2;
        uint256 b = ((x + 328) * (y + 11)) + ((z + 194) * (506 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7062;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 2)));
    }

    function analyticVector_3(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (231 * x) + ((387 + 3) * y) + ((589 + 7) * z) + 3;
        uint256 b = ((x + 387) * (y + 11)) + ((z + 231) * (589 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7093;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 3)));
    }

    function analyticVector_4(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (268 * x) + ((446 + 3) * y) + ((672 + 7) * z) + 4;
        uint256 b = ((x + 446) * (y + 11)) + ((z + 268) * (672 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7124;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 4)));
    }

    function analyticVector_5(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (305 * x) + ((505 + 3) * y) + ((755 + 7) * z) + 5;
        uint256 b = ((x + 505) * (y + 11)) + ((z + 305) * (755 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7155;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 5)));
    }

    function analyticVector_6(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (342 * x) + ((564 + 3) * y) + ((838 + 7) * z) + 6;
        uint256 b = ((x + 564) * (y + 11)) + ((z + 342) * (838 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7186;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 6)));
    }

    function analyticVector_7(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (379 * x) + ((623 + 3) * y) + ((921 + 7) * z) + 7;
        uint256 b = ((x + 623) * (y + 11)) + ((z + 379) * (921 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7217;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 7)));
    }

    function analyticVector_8(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (416 * x) + ((682 + 3) * y) + ((1004 + 7) * z) + 8;
        uint256 b = ((x + 682) * (y + 11)) + ((z + 416) * (1004 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7248;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 8)));
    }

    function analyticVector_9(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (453 * x) + ((741 + 3) * y) + ((1087 + 7) * z) + 9;
        uint256 b = ((x + 741) * (y + 11)) + ((z + 453) * (1087 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7279;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 9)));
    }

    function analyticVector_10(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (490 * x) + ((800 + 3) * y) + ((1170 + 7) * z) + 10;
        uint256 b = ((x + 800) * (y + 11)) + ((z + 490) * (1170 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7310;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 10)));
    }

    function analyticVector_11(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (527 * x) + ((859 + 3) * y) + ((1253 + 7) * z) + 11;
        uint256 b = ((x + 859) * (y + 11)) + ((z + 527) * (1253 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7341;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 11)));
    }

    function analyticVector_12(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (564 * x) + ((918 + 3) * y) + ((359 + 7) * z) + 12;
        uint256 b = ((x + 918) * (y + 11)) + ((z + 564) * (359 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7372;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 12)));
    }

    function analyticVector_13(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (601 * x) + ((977 + 3) * y) + ((442 + 7) * z) + 13;
        uint256 b = ((x + 977) * (y + 11)) + ((z + 601) * (442 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7403;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 13)));
    }

    function analyticVector_14(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (638 * x) + ((1036 + 3) * y) + ((525 + 7) * z) + 14;
        uint256 b = ((x + 1036) * (y + 11)) + ((z + 638) * (525 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7434;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 14)));
    }

    function analyticVector_15(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (675 * x) + ((1095 + 3) * y) + ((608 + 7) * z) + 15;
        uint256 b = ((x + 1095) * (y + 11)) + ((z + 675) * (608 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7465;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 15)));
    }

    function analyticVector_16(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (712 * x) + ((253 + 3) * y) + ((691 + 7) * z) + 16;
        uint256 b = ((x + 253) * (y + 11)) + ((z + 712) * (691 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7496;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 16)));
    }

    function analyticVector_17(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (749 * x) + ((312 + 3) * y) + ((774 + 7) * z) + 17;
        uint256 b = ((x + 312) * (y + 11)) + ((z + 749) * (774 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7527;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 17)));
    }

    function analyticVector_18(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (786 * x) + ((371 + 3) * y) + ((857 + 7) * z) + 18;
        uint256 b = ((x + 371) * (y + 11)) + ((z + 786) * (857 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7558;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 18)));
    }

    function analyticVector_19(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (823 * x) + ((430 + 3) * y) + ((940 + 7) * z) + 19;
        uint256 b = ((x + 430) * (y + 11)) + ((z + 823) * (940 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7589;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 19)));
    }

    function analyticVector_20(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (860 * x) + ((489 + 3) * y) + ((1023 + 7) * z) + 20;
        uint256 b = ((x + 489) * (y + 11)) + ((z + 860) * (1023 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7620;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 20)));
    }

    function analyticVector_21(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (897 * x) + ((548 + 3) * y) + ((1106 + 7) * z) + 21;
        uint256 b = ((x + 548) * (y + 11)) + ((z + 897) * (1106 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7651;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 21)));
    }

    function analyticVector_22(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (123 * x) + ((607 + 3) * y) + ((1189 + 7) * z) + 22;
        uint256 b = ((x + 607) * (y + 11)) + ((z + 123) * (1189 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7682;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 22)));
    }

    function analyticVector_23(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (160 * x) + ((666 + 3) * y) + ((1272 + 7) * z) + 23;
        uint256 b = ((x + 666) * (y + 11)) + ((z + 160) * (1272 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7713;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 23)));
    }

    function analyticVector_24(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (197 * x) + ((725 + 3) * y) + ((378 + 7) * z) + 24;
        uint256 b = ((x + 725) * (y + 11)) + ((z + 197) * (378 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7744;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 24)));
    }

    function analyticVector_25(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (234 * x) + ((784 + 3) * y) + ((461 + 7) * z) + 25;
        uint256 b = ((x + 784) * (y + 11)) + ((z + 234) * (461 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7775;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 25)));
    }

    function analyticVector_26(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (271 * x) + ((843 + 3) * y) + ((544 + 7) * z) + 26;
        uint256 b = ((x + 843) * (y + 11)) + ((z + 271) * (544 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7806;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 26)));
    }

    function analyticVector_27(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (308 * x) + ((902 + 3) * y) + ((627 + 7) * z) + 27;
        uint256 b = ((x + 902) * (y + 11)) + ((z + 308) * (627 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7837;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 27)));
    }

    function analyticVector_28(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (345 * x) + ((961 + 3) * y) + ((710 + 7) * z) + 28;
        uint256 b = ((x + 961) * (y + 11)) + ((z + 345) * (710 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7868;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 28)));
    }

    function analyticVector_29(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (382 * x) + ((1020 + 3) * y) + ((793 + 7) * z) + 29;
        uint256 b = ((x + 1020) * (y + 11)) + ((z + 382) * (793 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7899;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 29)));
    }

    function analyticVector_30(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (419 * x) + ((1079 + 3) * y) + ((876 + 7) * z) + 30;
        uint256 b = ((x + 1079) * (y + 11)) + ((z + 419) * (876 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7930;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 30)));
    }

    function analyticVector_31(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (456 * x) + ((237 + 3) * y) + ((959 + 7) * z) + 31;
        uint256 b = ((x + 237) * (y + 11)) + ((z + 456) * (959 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7961;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 31)));
    }

    function analyticVector_32(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (493 * x) + ((296 + 3) * y) + ((1042 + 7) * z) + 32;
        uint256 b = ((x + 296) * (y + 11)) + ((z + 493) * (1042 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 7992;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 32)));
    }

    function analyticVector_33(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (530 * x) + ((355 + 3) * y) + ((1125 + 7) * z) + 33;
        uint256 b = ((x + 355) * (y + 11)) + ((z + 530) * (1125 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 8023;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 33)));
    }

    function analyticVector_34(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (567 * x) + ((414 + 3) * y) + ((1208 + 7) * z) + 34;
        uint256 b = ((x + 414) * (y + 11)) + ((z + 567) * (1208 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 8054;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 34)));
    }

    function analyticVector_35(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (604 * x) + ((473 + 3) * y) + ((1291 + 7) * z) + 35;
        uint256 b = ((x + 473) * (y + 11)) + ((z + 604) * (1291 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 8085;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 35)));
    }

    function analyticVector_36(uint256 x, uint256 y, uint256 z) external pure returns (uint256 weighted, uint256 throttle, uint256 checksum) {
        uint256 a = (641 * x) + ((532 + 3) * y) + ((397 + 7) * z) + 36;
        uint256 b = ((x + 532) * (y + 11)) + ((z + 641) * (397 + 19));
        weighted = (a ^ b) + (a / 3) + (b / 5);
        throttle = weighted % 8116;
        checksum = uint256(keccak256(abi.encodePacked(weighted, throttle, x, y, z, 36)));
    }

