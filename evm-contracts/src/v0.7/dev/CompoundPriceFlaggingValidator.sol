// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "./ConfirmedOwner.sol";
import "../vendor/SafeMathChainlink.sol";
import "../interfaces/FlagsInterface.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../interfaces/UniswapAnchoredView.sol";
import "../interfaces/UpkeepInterface.sol";

/**
 * @notice This validator compares the price of Chainlink aggregators against
 * their equivalent Compound Open Oracle feeds. For each aggregator, a Compound
 * feed is configured with its symbol, number of decimals, and deviation threshold.
 * An aggregator address is flagged when its corresponding Compound feed price deviates
 * by more than the configured threshold from the aggregator price.
 */
contract CompoundPriceFlaggingValidator is ConfirmedOwner, UpkeepInterface {
  using SafeMathChainlink for uint256;

  struct CompoundFeedDetails {
    // Used to call the Compound Open Oracle
    string symbol;
    // Used to convert price to match aggregator decimals
    uint8 decimals;
    // 1        = 100%
    // 5        = 20%
    // 10       = 10%
    // 20       = 5%
    // 50       = 2%
    // 100      = 1%
    // 200      = 0.5%
    // 500      = 0.2%
    // 1000     = 0.1%
    uint32 deviationThresholdDenominator;
  }

  FlagsInterface private s_flags;
  UniswapAnchoredView private s_compOpenOracle;
  mapping(address => CompoundFeedDetails) private s_feedDetails;

  event CompoundOpenOracleAddressUpdated(
    address indexed from,
    address indexed to
  );
  event FlagsAddressUpdated(
    address indexed from,
    address indexed to
  );
  event FeedDetailsSet(
    address indexed aggregator,
    string symbol,
    uint8 decimals,
    uint32 deviationThresholdDenominator
  );
  
  /**
   * @notice Create a new CompoundPriceFlaggingValidator
   * @dev Use this contract to compare Chainlink aggregator prices
   * against the Compound Open Oracle prices
   * @param flagsAddress Address of the flag contract
   * @param compoundOracleAddress Address of the Compound Open Oracle UniswapAnchoredView contract
   */
  constructor(
    address flagsAddress,
    address compoundOracleAddress
  )
    ConfirmedOwner(msg.sender)
  {
    setFlagsAddress(flagsAddress);
    setCompoundOpenOracleAddress(compoundOracleAddress);
  }

  /**
   * @notice Set the address of the Compound Open Oracle UniswapAnchoredView contract
   * @param oracleAddress Compound Open Oracle UniswapAnchoredView address
   */
  function setCompoundOpenOracleAddress(
    address oracleAddress
  )
    public
    onlyOwner()
  {
    address previous = address(s_compOpenOracle);
    if (previous != oracleAddress) {
      s_compOpenOracle = UniswapAnchoredView(oracleAddress);
      emit CompoundOpenOracleAddressUpdated(previous, oracleAddress);
    }
  }

  /**
   * @notice Updates the flagging contract address for raising flags
   * @param flagsAddress sets the address of the flags contract
   */
  function setFlagsAddress(
    address flagsAddress
  )
    public
    onlyOwner()
  {
    address previous = address(s_flags);
    if (previous != flagsAddress) {
      s_flags = FlagsInterface(flagsAddress);
      emit FlagsAddressUpdated(previous, flagsAddress);
    }
  }

  /**
   * @notice Set the threshold details for comparing a Chainlink aggregator
   * to a Compound Open Oracle feed.
   * @param aggregator The Chainlink aggregator address
   * @param compoundSymbol The symbol used by Compound for this feed
   * @param compoundDecimals The number of decimals in the Compound feed
   * @param compoundDeviationThresholdDenominator The threshold denominator use to determine
   * the percentage with which the difference in prices must reside within. For example:
   * If the prices are valid within a 5% threshold, and 1 / denominator, this denominator
   * = 20, since 1/20 = 5.
   */
  function setFeedDetails(
    address aggregator,
    string calldata compoundSymbol,
    uint8 compoundDecimals,
    uint32 compoundDeviationThresholdDenominator
  ) 
    public 
    onlyOwner() 
  {
    require(compoundDeviationThresholdDenominator != 0, "Invalid threshold denominator");
    require(compoundPriceOf(compoundSymbol) != 0, "Invalid Compound price");
    s_feedDetails[aggregator] = CompoundFeedDetails({
      symbol: compoundSymbol,
      decimals: compoundDecimals,
      deviationThresholdDenominator: compoundDeviationThresholdDenominator
    });
    emit FeedDetailsSet(
      aggregator,
      compoundSymbol,
      compoundDecimals,
      compoundDeviationThresholdDenominator
    );
  }

  /**
   * @notice Check the price deviation of an array of aggregators
   * @dev If any of the aggregators provided have an equivalent Compound Oracle feed
   * that with a price outside of the configured deviation, this function will return them.
   * @param aggregators address[] memory
   * @return address[] invalid feeds
   */
  function check(
    address[] memory aggregators
  )
    public
    view
    returns (
      address[] memory
    )
  {
    address[] memory invalidAggregators = new address[](aggregators.length);
    uint256 invalidCount = 0;
    for (uint256 i = 0; i < aggregators.length; i++) {
      address aggregator = aggregators[i];
      if (isInvalid(aggregator)) {
        invalidAggregators[invalidCount] = aggregator;
        invalidCount++;
      }
    }

    if (aggregators.length != invalidCount) {
      assembly {
        mstore(invalidAggregators, invalidCount)
      }
    }
    return invalidAggregators;
  }

  /**
   * @notice Check and raise flags for any aggregator that has an equivalent Compound
   * Open Oracle feed with a price deviation exceeding the configured setting.
   * @dev This contract must have write permissions on the Flags contract
   * @param aggregators address[] memory
   * @return address[] memory invalid aggregators
   */
  function update(
    address[] memory aggregators
  )
    public
    returns (
      address[] memory
    )
  {
    address[] memory invalidAggregators = check(aggregators);
    s_flags.raiseFlags(invalidAggregators);
    return invalidAggregators;
  }

  /**
   * @notice Check the price deviation of an array of aggregators
   * @dev If any of the aggregators provided have an equivalent Compound Oracle feed
   * that with a price outside of the configured deviation, this function will return them.
   * @param data bytes encoded address array
   * @return needsUpkeep bool indicating whether upkeep needs to be performed
   * @return invalid aggregators - bytes encoded address array of invalid aggregator addresses
   */
  function checkUpkeep(
    bytes calldata data
  )
    external
    view
    override
    returns (
      bool,
      bytes memory
    )
  {
    address[] memory invalidAggregators = check(abi.decode(data, (address[])));
    bool needsUpkeep = (invalidAggregators.length > 0);
    return (needsUpkeep, abi.encode(invalidAggregators));
  }

  /**
   * @notice Check and raise flags for any aggregator that has an equivalent Compound
   * Open Oracle feed with a price deviation exceeding the configured setting.
   * @dev This contract must have write permissions on the Flags contract
   * @param data bytes encoded address array
   */
  function performUpkeep(
    bytes calldata data
  )
    external
    override
  {
    update(abi.decode(data, (address[])));
  }

  /**
   * @notice Get the threshold of an aggregator
   * @param aggregator address
   * @return string Compound Oracle Symbol
   * @return uint8 Compound Oracle Decimals
   * @return uint32 Deviation Threshold Denominator
   */
  function getFeedDetails(
    address aggregator
  )
    public
    view
    returns (
      string memory,
      uint8,
      uint32
    )
  {
    CompoundFeedDetails memory compDetails = s_feedDetails[aggregator];
    return(
      compDetails.symbol,
      compDetails.decimals,
      compDetails.deviationThresholdDenominator
    );
  }

  /**
   * @notice Get the flags address
   * @return address
   */
  function flags()
    external
    view
    returns (
      address
    )
  {
    return address(s_flags);
  }

  /**
   * @notice Get the Compound Open Oracle address
   * @return address
   */
  function compoundOpenOracle()
    external
    view
    returns (
      address
    )
  {
    return address(s_compOpenOracle);
  }

  /**
   * @notice Return the Compound oracle price of an asset using its symbol
   * @param symbol string
   * @return price uint256
   */
  function compoundPriceOf(
    string memory symbol
  )
    private
    view
    returns (
      uint256
    )
  {
    return s_compOpenOracle.price(symbol);
  }

  // VALIDATION FUNCTIONS

  /**
   * @notice Check if an aggregator has an equivalent Compound Oracle feed
   * that's price is deviated more than the threshold.
   * @param aggregator address of the Chainlink aggregator
   * @return invalid bool. True if the deviation exceeds threshold.
   */
  function isInvalid(
    address aggregator
  )
    private
    view
    returns (
      bool invalid
    )
  {
    CompoundFeedDetails memory compDetails = s_feedDetails[aggregator];
    if (compDetails.deviationThresholdDenominator == 0) {
      return false;
    }
    // Get both oracle price details
    uint256 compPrice = compoundPriceOf(compDetails.symbol);
    (uint256 aggregatorPrice, uint8 aggregatorDecimals) = aggregatorValues(aggregator);

    // Adjust the prices so the number of decimals in each align
    (aggregatorPrice, compPrice) = adjustPriceDecimals(
      aggregatorPrice,
      aggregatorDecimals,
      compPrice,
      compDetails.decimals
    );

    // Check whether the prices deviate beyond the threshold.
    return deviatesBeyondThreshold(aggregatorPrice, compPrice, compDetails.deviationThresholdDenominator);
  }

  /**
   * @notice Retrieve the price and the decimals from an Aggregator
   * @param aggregator address
   * @return price uint256
   * @return decimals uint8
   */
  function aggregatorValues(
    address aggregator
  )
    private
    view
    returns (
      uint256 price,
      uint8 decimals
    )
  {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(aggregator);
    (,int256 signedPrice,,,) = priceFeed.latestRoundData();
    price = uint256(signedPrice);
    decimals = priceFeed.decimals();
  }

  /**
   * @notice Adjust the price values of the Aggregator and Compound feeds so that
   * their decimal places align. This enables deviation to be calculated.
   * @param aggregatorPrice uint256
   * @param aggregatorDecimals uint8 - decimal places included in the aggregator price
   * @param compoundPrice uint256
   * @param compoundDecimals uint8 - decimal places included in the compound price
   * @return adjustedAggregatorPrice uint256
   * @return adjustedCompoundPrice uint256
   */
  function adjustPriceDecimals(
    uint256 aggregatorPrice,
    uint8 aggregatorDecimals,
    uint256 compoundPrice,
    uint8 compoundDecimals
  )
    private
    pure
    returns (
      uint256 adjustedAggregatorPrice,
      uint256 adjustedCompoundPrice
    )
  {
    if (aggregatorDecimals > compoundDecimals) {
      uint8 diff = aggregatorDecimals - compoundDecimals;
      uint256 multiplier = 10**uint256(diff);
      compoundPrice = compoundPrice * multiplier;
    }
    else if (aggregatorDecimals < compoundDecimals) {
      uint8 diff = compoundDecimals - aggregatorDecimals;
      uint256 multiplier = 10**uint256(diff);
      aggregatorPrice = aggregatorPrice * multiplier;
    }
    adjustedAggregatorPrice = aggregatorPrice;
    adjustedCompoundPrice = compoundPrice;
  }

  /**
   * @notice Check whether the compound price deviates from the aggregator price
   * beyond the given threshold
   * @dev Prices must be adjusted to match decimals prior to calling this function
   * @param aggregatorPrice uint256
   * @param compPrice uint256
   * @param deviationThresholdDenominator uint32
   * @return beyondThreshold boolean. Returns true if deviation is beyond threshold.
   */
  function deviatesBeyondThreshold(
    uint256 aggregatorPrice,
    uint256 compPrice,
    uint32 deviationThresholdDenominator
  )
    private
    pure
    returns (
      bool beyondThreshold
    )
  {
    // Deviation amount threshold from the aggregator price
    uint256 deviationAmountThreshold = aggregatorPrice.div(uint256(deviationThresholdDenominator));

    // Calculate deviation
    uint256 deviation;
    if (aggregatorPrice > compPrice) {
      deviation = aggregatorPrice.sub(compPrice);
    }
    else if (aggregatorPrice < compPrice) {
      deviation = compPrice.sub(aggregatorPrice);
    }
    beyondThreshold = (deviation >= deviationAmountThreshold);
  }
}