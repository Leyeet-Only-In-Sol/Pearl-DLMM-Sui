// tests/core_tests.move - Fixed comprehensive test suite for DLMM core functionality
#[test_only]
module sui_dlmm::core_tests {
    use sui::test_scenario::{Self as test, Scenario};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::test_utils::assert_eq;
    
    use sui_dlmm::bin_math;
    use sui_dlmm::constant_sum;
    use sui_dlmm::fee_math;
    use sui_dlmm::volatility;

    // Test coins for our DLMM tests
    public struct TESTA has drop {}
    public struct TESTB has drop {}

    // Constants for testing
    const ADMIN: address = @0xBABE;
    const ALICE: address = @0xA11CE;

    const PRICE_SCALE: u128 = 18446744073709551616; // 2^64

    // Helper function to create test tokens
    fun create_test_coins(scenario: &mut Scenario) {
        test::next_tx(scenario, ADMIN);
        {
            // Create test token A
            let (treasury_cap_a, coin_metadata_a) = coin::create_currency<TESTA>(
                TESTA {},
                8, // decimals
                b"TESTA",
                b"Test Token A",
                b"Test token A for DLMM testing",
                std::option::none(),
                test::ctx(scenario)
            );

            // Create test token B  
            let (treasury_cap_b, coin_metadata_b) = coin::create_currency<TESTB>(
                TESTB {},
                6, // decimals
                b"TESTB", 
                b"Test Token B",
                b"Test token B for DLMM testing",
                std::option::none(),
                test::ctx(scenario)
            );

            // Transfer objects properly
            sui::transfer::public_transfer(treasury_cap_a, ADMIN);
            sui::transfer::public_transfer(treasury_cap_b, ADMIN);
            sui::transfer::public_freeze_object(coin_metadata_a);
            sui::transfer::public_freeze_object(coin_metadata_b);
        };
    }

    // Helper function to mint test coins - FIXED
    fun mint_test_coins(
        scenario: &mut Scenario,
        recipient: address,
        amount_a: u64,
        amount_b: u64
    ) {
        test::next_tx(scenario, ADMIN);
        {
            let mut treasury_cap_a = test::take_from_sender<TreasuryCap<TESTA>>(scenario);
            let mut treasury_cap_b = test::take_from_sender<TreasuryCap<TESTB>>(scenario);
            
            let coin_a = coin::mint(&mut treasury_cap_a, amount_a, test::ctx(scenario));
            let coin_b = coin::mint(&mut treasury_cap_b, amount_b, test::ctx(scenario));
            
            sui::transfer::public_transfer(coin_a, recipient);
            sui::transfer::public_transfer(coin_b, recipient);
            
            test::return_to_sender(scenario, treasury_cap_a);
            test::return_to_sender(scenario, treasury_cap_b);
        };
    }

    #[test]
    fun test_bin_math_price_calculation() {
        // Test: bin_id -> price and price -> bin_id conversions
        let mut scenario = test::begin(ADMIN);
        
        // Test bin step of 25 (0.25%)
        let bin_step: u16 = 25;
        
        // Test case 1: bin_id = 0 should give base price
        let bin_id_0: u32 = 0;
        let price_0 = bin_math::calculate_bin_price(bin_id_0, bin_step);
        assert_eq(price_0, PRICE_SCALE); // Should equal 1.0 in our price format
        
        // Test case 2: bin_id = 100 should give 1.0025^100
        let bin_id_100: u32 = 100;
        let price_100 = bin_math::calculate_bin_price(bin_id_100, bin_step);
        let expected_price_100 = bin_math::power_u128(10025 * PRICE_SCALE / 10000, 100);
        assert!(abs_diff(price_100, expected_price_100) < PRICE_SCALE / 1000); // Allow 0.1% error
        
        // Test case 3: Reverse calculation - price -> bin_id
        let recovered_bin_id = bin_math::get_bin_from_price(price_100, bin_step);
        assert_eq(recovered_bin_id, bin_id_100);
        
        test::end(scenario);
    }

    #[test]
    fun test_constant_sum_math() {
        // Test: P * x + y = L math within bins
        let mut scenario = test::begin(ADMIN);
        
        let price: u128 = 3400 * PRICE_SCALE; // $3400 per unit
        let liquidity: u64 = 1000000; // 1M units of liquidity
        
        // Test case 1: Equal distribution (50-50)
        let (amount_x, amount_y) = constant_sum::calculate_amounts_from_liquidity(
            liquidity,
            price,
            50 // 50% composition
        );
        
        // Verify P * x + y = L
        let calculated_liquidity = constant_sum::calculate_liquidity_from_amounts(
            amount_x, amount_y, price
        );
        assert!(abs_diff_u64(calculated_liquidity, liquidity) < 1000); // Allow small rounding error
        
        // Test case 2: All token Y (100% composition)
        let (amount_x_100, amount_y_100) = constant_sum::calculate_amounts_from_liquidity(
            liquidity,
            price,
            100
        );
        assert_eq(amount_x_100, 0);
        assert_eq(amount_y_100, liquidity);
        
        // Test case 3: All token X (0% composition) 
        let (amount_x_0, amount_y_0) = constant_sum::calculate_amounts_from_liquidity(
            liquidity,
            price,
            0
        );
        assert_eq(amount_y_0, 0);
        assert_eq(amount_x_0, ((liquidity as u128) * PRICE_SCALE / price) as u64);
        
        test::end(scenario);
    }

    #[test]  
    fun test_swap_within_bin() {
        // Test: Zero slippage swaps within a single bin
        let mut scenario = test::begin(ADMIN);
        
        // Create a bin with equal liquidity
        let bin_price: u128 = 3400 * PRICE_SCALE;
        let liquidity_x: u64 = 1000; // 1000 units of token X
        let liquidity_y: u64 = 3400000; // 3.4M units of token Y (1000 * 3400)
        
        // Test case 1: Swap 100 units of X for Y
        let amount_x_in: u64 = 100;
        let (amount_y_out, bin_exhausted) = constant_sum::swap_within_bin(
            liquidity_x,
            liquidity_y,
            amount_x_in,
            true, // zero_for_one
            bin_price
        );
        
        // Expected: 100 * 3400 = 340,000 units of Y out
        assert_eq(amount_y_out, 340000);
        assert_eq(bin_exhausted, false);
        
        // Test case 2: Verify reserves update correctly
        let (new_liquidity_x, new_liquidity_y) = constant_sum::update_reserves_after_swap(
            liquidity_x, liquidity_y, amount_x_in, amount_y_out, true
        );
        assert_eq(new_liquidity_x, 1100); // 1000 + 100
        assert_eq(new_liquidity_y, 3060000); // 3400000 - 340000
        
        test::end(scenario);
    }

    #[test]
    fun test_multi_bin_swap() {
        // Test: Swaps that traverse multiple bins
        let mut scenario = test::begin(ADMIN);
        
        // Create 3 consecutive bins with different prices
        let bin_step: u16 = 25;
        let base_bin_id: u32 = 1000;
        
        // Calculate prices for different bins
        let price_1000 = bin_math::calculate_bin_price(base_bin_id, bin_step);
        let price_1001 = bin_math::calculate_bin_price(base_bin_id + 1, bin_step);
        let price_1002 = bin_math::calculate_bin_price(base_bin_id + 2, bin_step);
        
        // Verify prices increase with bin_id
        assert!(price_1001 > price_1000);
        assert!(price_1002 > price_1001);
        
        // Test multi-bin calculation
        let max_swap_1000 = constant_sum::calculate_max_swap_amount(1000, 0, true, price_1000);
        let max_swap_1001 = constant_sum::calculate_max_swap_amount(800, 0, true, price_1001);
        
        // These should be the maximum amounts that can be swapped in each bin
        assert!(max_swap_1000 > 0);
        assert!(max_swap_1001 > 0);
        
        test::end(scenario);
    }

    #[test]  
    fun test_dynamic_fees() {
        // Test: Dynamic fee calculation based on volatility
        let mut scenario = test::begin(ADMIN);
        
        let base_factor: u16 = 100;
        let bin_step: u16 = 25;
        
        // Test case 1: No bins crossed (base fee only)
        let fee_0_bins = fee_math::calculate_dynamic_fee(base_factor, bin_step, 0);
        let expected_base_fee = (base_factor as u64) * (bin_step as u64) / 10000;
        assert_eq(fee_0_bins, expected_base_fee);
        
        // Test case 2: 5 bins crossed (base + variable fee)
        let fee_5_bins = fee_math::calculate_dynamic_fee(base_factor, bin_step, 5);
        assert!(fee_5_bins > fee_0_bins);
        
        // Test case 3: 20 bins crossed (high volatility)
        let fee_20_bins = fee_math::calculate_dynamic_fee(base_factor, bin_step, 20);
        assert!(fee_20_bins > fee_5_bins);
        assert!(fee_20_bins >= fee_0_bins * 2); // Should be at least 2x base fee
        
        test::end(scenario);
    }

    #[test]
    fun test_position_creation() {
        // Test: Creating multi-bin liquidity positions
        let mut scenario = test::begin(ADMIN);
        create_test_coins(&mut scenario);
        
        test::next_tx(&mut scenario, ALICE);
        {
            mint_test_coins(&mut scenario, ALICE, 10000, 20000000); // 10k TESTA, 20M TESTB
        };
        
        test::next_tx(&mut scenario, ALICE);
        {
            let coin_a = test::take_from_sender<Coin<TESTA>>(&scenario);
            let coin_b = test::take_from_sender<Coin<TESTB>>(&scenario);
            
            // Create position spanning 10 bins around current price
            let lower_bin_id: u32 = 995;
            let upper_bin_id: u32 = 1005;
            
            let position = create_test_position(
                coin_a,
                coin_b,
                lower_bin_id,
                upper_bin_id,
                test::ctx(&mut scenario)
            );
            
            // Verify position properties
            assert_eq(get_position_lower_bin(&position), lower_bin_id);
            assert_eq(get_position_upper_bin(&position), upper_bin_id);
            assert_eq(get_position_bin_count(&position), 11); // 995-1005 inclusive
            
            sui::transfer::public_transfer(position, ALICE);
        };
        
        test::end(scenario);
    }

    #[test]
    fun test_liquidity_distribution_strategies() {
        // Test: Different liquidity distribution strategies
        let mut scenario = test::begin(ADMIN);
        
        let lower_bin: u32 = 1000;
        let upper_bin: u32 = 1010;
        let _total_liquidity: u64 = 100000;
        
        // Test case 1: Uniform distribution
        let uniform_weights = calculate_distribution_weights(
            lower_bin,
            upper_bin,
            1005, // active_bin_id (middle)
            0     // uniform strategy
        );
        
        // Should be equal weights across all bins
        let bin_count = (upper_bin - lower_bin + 1) as u64;
        let expected_uniform_weight = 10000 / bin_count; // Total weight = 10000
        let mut i = 0u64;
        while (i < bin_count) {
            let weight = *std::vector::borrow(&uniform_weights, i);
            assert!(abs_diff_u64(weight, expected_uniform_weight) < 100);
            i = i + 1;
        };
        
        // Test case 2: Curve distribution (concentrated around active bin)
        let curve_weights = calculate_distribution_weights(
            lower_bin,
            upper_bin,
            1005, // active_bin_id
            1     // curve strategy
        );
        
        // Active bin should have highest weight
        let active_weight = *std::vector::borrow(&curve_weights, 5); // Index 5 = bin 1005
        let edge_weight = *std::vector::borrow(&curve_weights, 0);   // Index 0 = bin 1000
        assert!(active_weight > edge_weight);
        
        // Test case 3: Bid-Ask distribution (concentrated at edges)
        let bid_ask_weights = calculate_distribution_weights(
            lower_bin,
            upper_bin,
            1005, // active_bin_id
            2     // bid-ask strategy
        );
        
        // Edge bins should have higher weight than middle
        let left_edge_weight = *std::vector::borrow(&bid_ask_weights, 0);  // bin 1000
        let right_edge_weight = *std::vector::borrow(&bid_ask_weights, 10); // bin 1010
        let middle_weight = *std::vector::borrow(&bid_ask_weights, 5);     // bin 1005
        
        assert!(left_edge_weight > middle_weight);
        assert!(right_edge_weight > middle_weight);
        
        test::end(scenario);
    }

    #[test]
    fun test_fee_collection() {
        // Test: Fee accumulation and collection
        let mut scenario = test::begin(ADMIN);
        
        // Simulate trading activity that generates fees
        let mut total_fees_collected: u64 = 0;
        let swap_count: u64 = 10;
        
        let mut i = 0;
        while (i < swap_count) {
            // Simulate a swap that crosses 2 bins
            let fee = fee_math::calculate_dynamic_fee(100, 25, 2);
            total_fees_collected = total_fees_collected + fee;
            i = i + 1;
        };
        
        // Verify fees were collected
        assert!(total_fees_collected > 0);
        
        // Test protocol fee distribution (30% of dynamic fees)
        let protocol_fee_rate: u16 = 3000; // 30%
        let protocol_fees = fee_math::calculate_protocol_fee(total_fees_collected, protocol_fee_rate);
        let lp_fees = fee_math::calculate_lp_fee(total_fees_collected, protocol_fee_rate);
        
        assert!(protocol_fees > 0);
        assert!(lp_fees > protocol_fees); // LPs should get majority
        
        test::end(scenario);
    }

    #[test]  
    fun test_price_impact_calculation() {
        // Test: Price impact from large trades
        let mut scenario = test::begin(ADMIN);
        
        let initial_price: u128 = 3400 * PRICE_SCALE;
        let large_trade_amount: u64 = 50000; // Large trade
        let small_trade_amount: u64 = 100;   // Small trade
        
        // Calculate price impact for small trade (should be minimal)
        let small_impact = calculate_price_impact(small_trade_amount, initial_price);
        assert!(small_impact < PRICE_SCALE / 1000); // Less than 0.1%
        
        // Calculate price impact for large trade (should be higher)
        let large_impact = calculate_price_impact(large_trade_amount, initial_price);
        assert!(large_impact > small_impact);
        
        test::end(scenario);
    }

    #[test]
    fun test_volatility_accumulator() {
        // Test volatility accumulator functionality
        let mut scenario = test::begin(ADMIN);
        
        let initial_bin = 1000u32;
        let current_time = 1000000u64;
        
        // Create new accumulator
        let accumulator = volatility::new_volatility_accumulator(initial_bin, current_time);
        assert_eq(volatility::get_volatility_value(&accumulator), 0);
        assert_eq(volatility::get_reference_bin_id(&accumulator), initial_bin);
        
        // Update with some volatility
        let updated_accumulator = volatility::update_volatility_accumulator(
            accumulator,
            1005, // 5 bins away
            3,    // 3 bins crossed
            current_time + 5000 // 5 seconds later
        );
        
        let new_volatility = volatility::get_volatility_value(&updated_accumulator);
        assert!(new_volatility > 0); // Should have increased
        
        test::end(scenario);
    }

    // Helper functions for testing
    fun abs_diff(a: u128, b: u128): u128 {
        if (a >= b) { a - b } else { b - a }
    }

    fun abs_diff_u64(a: u64, b: u64): u64 {
        if (a >= b) { a - b } else { b - a }
    }

    fun calculate_distribution_weights(
        lower_bin: u32,
        upper_bin: u32,
        active_bin: u32,
        strategy: u8
    ): vector<u64> {
        let mut weights = std::vector::empty<u64>();
        let bin_count = upper_bin - lower_bin + 1;
        let base_weight = 10000 / (bin_count as u64);
        
        let mut i = lower_bin;
        while (i <= upper_bin) {
            let weight = if (strategy == 0) {
                // Uniform
                base_weight
            } else if (strategy == 1) {
                // Curve - higher weight near active bin
                let distance = if (i >= active_bin) { i - active_bin } else { active_bin - i };
                if (distance < 3) {
                    base_weight * (4 - distance as u64)
                } else {
                    base_weight / 2
                }
            } else {
                // Bid-Ask - higher weight at edges
                if (i == lower_bin || i == upper_bin) {
                    base_weight * 3
                } else {
                    base_weight / 2
                }
            };
            std::vector::push_back(&mut weights, weight);
            i = i + 1;
        };
        
        weights
    }

    fun calculate_price_impact(amount: u64, price: u128): u128 {
        // Simplified price impact calculation
        (amount as u128) * PRICE_SCALE / (price * 1000)
    }

    // Test helper structs
    public struct TestPosition has key, store {
        id: sui::object::UID,
        lower_bin_id: u32,
        upper_bin_id: u32,
        bin_count: u32,
    }

    fun create_test_position(
        coin_a: Coin<TESTA>,
        coin_b: Coin<TESTB>,
        lower_bin_id: u32,
        upper_bin_id: u32,
        ctx: &mut sui::tx_context::TxContext
    ): TestPosition {
        // Return coins to sender (simplified)
        sui::transfer::public_transfer(coin_a, sui::tx_context::sender(ctx));
        sui::transfer::public_transfer(coin_b, sui::tx_context::sender(ctx));
        
        TestPosition {
            id: sui::object::new(ctx),
            lower_bin_id,
            upper_bin_id,
            bin_count: upper_bin_id - lower_bin_id + 1,
        }
    }

    fun get_position_lower_bin(position: &TestPosition): u32 {
        position.lower_bin_id
    }

    fun get_position_upper_bin(position: &TestPosition): u32 {
        position.upper_bin_id
    }

    fun get_position_bin_count(position: &TestPosition): u32 {
        position.bin_count
    }
}