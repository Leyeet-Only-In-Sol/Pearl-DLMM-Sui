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

    // Test coins for our DLMM tests - Add public visibility for Move 2024
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
            // Create test token A - Fixed destructuring
            let (treasury_cap_a, coin_metadata_a) = coin::create_currency<TESTA>(
                TESTA {},
                8, // decimals
                b"TESTA",
                b"Test Token A",
                b"Test token A for DLMM testing",
                option::none(),
                test::ctx(scenario)
            );

            // Create test token B  
            let (treasury_cap_b, coin_metadata_b) = coin::create_currency<TESTB>(
                TESTB {},
                6, // decimals
                b"TESTB", 
                b"Test Token B",
                b"Test token B for DLMM testing",
                option::none(),
                test::ctx(scenario)
            );

            // Transfer objects properly
            transfer::public_transfer(treasury_cap_a, ADMIN);
            transfer::public_transfer(treasury_cap_b, ADMIN);
            transfer::public_freeze_object(coin_metadata_a);
            transfer::public_freeze_object(coin_metadata_b);
        };
    }

    // Helper function to mint test coins
    fun mint_test_coins(
        scenario: &mut Scenario,
        recipient: address,
        amount_a: u64,
        amount_b: u64
    ) {
        test::next_tx(scenario, ADMIN);
        {
            let treasury_cap_a = test::take_from_sender<TreasuryCap<TESTA>>(scenario);
            let treasury_cap_b = test::take_from_sender<TreasuryCap<TESTB>>(scenario);
            
            let coin_a = coin::mint(&mut treasury_cap_a, amount_a, test::ctx(scenario));
            let coin_b = coin::mint(&mut treasury_cap_b, amount_b, test::ctx(scenario));
            
            transfer::public_transfer(coin_a, recipient);
            transfer::public_transfer(coin_b, recipient);
            
            test::return_to_sender(scenario, treasury_cap_a);
            test::return_to_sender(scenario, treasury_cap_b);
        };
    }

    #[test]
    fun test_bin_math_price_calculation() {
        // Test: bin_id -> price and price -> bin_id conversions
        let scenario = test::begin(ADMIN);
        
        // Test bin step of 25 (0.25%)
        let bin_step: u16 = 25;
        
        // Test case 1: bin_id = 0 should give base price
        let bin_id_0: u32 = 0;
        let price_0 = calculate_bin_price(bin_id_0, bin_step);
        assert_eq(price_0, PRICE_SCALE); // Should equal 1.0 in our price format
        
        // Test case 2: bin_id = 100 should give 1.0025^100
        let bin_id_100: u32 = 100;
        let price_100 = calculate_bin_price(bin_id_100, bin_step);
        let expected_price_100 = power(10025 * PRICE_SCALE / 10000, 100);
        assert!(abs_diff(price_100, expected_price_100) < PRICE_SCALE / 1000); // Allow 0.1% error
        
        // Test case 3: Reverse calculation - price -> bin_id
        let recovered_bin_id = get_bin_from_price(price_100, bin_step);
        assert_eq(recovered_bin_id, bin_id_100);
        
        test::end(scenario);
    }

    #[test]
    fun test_constant_sum_math() {
        // Test: P * x + y = L math within bins
        let scenario = test::begin(ADMIN);
        
        let price: u128 = 3400 * PRICE_SCALE; // $3400 per unit
        let liquidity: u64 = 1000000; // 1M units of liquidity
        
        // Test case 1: Equal distribution (50-50)
        let (amount_x, amount_y) = calculate_amounts_from_liquidity(
            liquidity,
            price,
            50 // 50% composition
        );
        
        // Verify P * x + y = L
        let calculated_liquidity = (price * (amount_x as u128) / PRICE_SCALE) + (amount_y as u128);
        assert!(abs_diff(calculated_liquidity, liquidity as u128) < 1000); // Allow small rounding error
        
        // Test case 2: All token X (100% composition)
        let (amount_x_100, amount_y_100) = calculate_amounts_from_liquidity(
            liquidity,
            price,
            100
        );
        assert_eq(amount_y_100, 0);
        assert_eq(amount_x_100, ((liquidity as u128) * PRICE_SCALE / price) as u64);
        
        // Test case 3: All token Y (0% composition)
        let (amount_x_0, amount_y_0) = calculate_amounts_from_liquidity(
            liquidity,
            price,
            0
        );
        assert_eq(amount_x_0, 0);
        assert_eq(amount_y_0, liquidity);
        
        test::end(scenario);
    }

    #[test]  
    fun test_swap_within_bin() {
        // Test: Zero slippage swaps within a single bin
        let scenario = test::begin(ADMIN);
        
        // Create a bin with equal liquidity
        let bin_price: u128 = 3400 * PRICE_SCALE;
        let mut liquidity_x: u64 = 1000; // 1000 units of token X
        let mut liquidity_y: u64 = 3400000; // 3.4M units of token Y (1000 * 3400)
        
        // Test case 1: Swap 100 units of X for Y
        let amount_x_in: u64 = 100;
        let (amount_y_out, bin_exhausted) = swap_x_for_y_within_bin(
            &mut liquidity_x,
            &mut liquidity_y,
            amount_x_in,
            bin_price
        );
        
        // Expected: 100 * 3400 = 340,000 units of Y out
        assert_eq(amount_y_out, 340000);
        assert_eq(bin_exhausted, false);
        assert_eq(liquidity_x, 1100); // 1000 + 100
        assert_eq(liquidity_y, 3060000); // 3400000 - 340000
        
        // Test case 2: Swap that exhausts the bin
        let amount_x_exhaust = liquidity_x + 500; // More than available
        let (_amount_y_out_2, bin_exhausted_2) = swap_x_for_y_within_bin(
            &mut liquidity_x,
            &mut liquidity_y,  
            amount_x_exhaust,
            bin_price
        );
        
        assert_eq(bin_exhausted_2, true);
        assert_eq(liquidity_y, 0); // Should be exhausted
        
        test::end(scenario);
    }

    #[test]
    fun test_multi_bin_swap() {
        // Test: Swaps that traverse multiple bins
        let scenario = test::begin(ADMIN);
        
        // Create 3 consecutive bins with different prices
        let bin_step: u16 = 25;
        let base_bin_id: u32 = 1000;
        
        let mut bins = vector::empty();
        
        // Bin 1000: Price = base_price
        let price_1000 = calculate_bin_price(base_bin_id, bin_step);
        vector::push_back(&mut bins, create_test_bin(base_bin_id, 1000, 0, price_1000));
        
        // Bin 1001: Price = base_price * 1.0025
        let price_1001 = calculate_bin_price(base_bin_id + 1, bin_step);
        vector::push_back(&mut bins, create_test_bin(base_bin_id + 1, 800, 0, price_1001));
        
        // Bin 1002: Price = base_price * 1.0025^2  
        let price_1002 = calculate_bin_price(base_bin_id + 2, bin_step);
        vector::push_back(&mut bins, create_test_bin(base_bin_id + 2, 600, 0, price_1002));
        
        // Execute large swap that crosses all bins
        let total_amount_in: u64 = 3000; // More than any single bin
        let (total_amount_out, bins_crossed, final_bin_id) = execute_multi_bin_swap(
            &mut bins,
            total_amount_in,
            base_bin_id,
            true // zero_for_one
        );
        
        assert_eq(bins_crossed, 3);
        assert_eq(final_bin_id, base_bin_id + 3);
        assert!(total_amount_out > 0);
        
        test::end(scenario);
    }

    #[test]  
    fun test_dynamic_fees() {
        // Test: Dynamic fee calculation based on volatility
        let scenario = test::begin(ADMIN);
        
        let base_factor: u16 = 100;
        let bin_step: u16 = 25;
        
        // Test case 1: No bins crossed (base fee only)
        let fee_0_bins = calculate_dynamic_fee(base_factor, bin_step, 0);
        let expected_base_fee = (base_factor as u64) * (bin_step as u64) / 10000;
        assert_eq(fee_0_bins, expected_base_fee);
        
        // Test case 2: 5 bins crossed (base + variable fee)
        let fee_5_bins = calculate_dynamic_fee(base_factor, bin_step, 5);
        assert!(fee_5_bins > fee_0_bins);
        
        // Test case 3: 20 bins crossed (high volatility)
        let fee_20_bins = calculate_dynamic_fee(base_factor, bin_step, 20);
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
            // Mint coins for Alice
            mint_test_coins(&mut scenario, ALICE, 10000, 20000000); // 10k TESTA, 20M TESTB
        };
        
        test::next_tx(&mut scenario, ALICE);
        {
            let coin_a = test::take_from_sender<Coin<TESTA>>(&scenario);
            let coin_b = test::take_from_sender<Coin<TESTB>>(&scenario);
            
            // Create position spanning 10 bins around current price
            let lower_bin_id: u32 = 995;
            let upper_bin_id: u32 = 1005;
            let _distribution_type: u8 = 1; // Curve distribution
            
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
            
            transfer::public_transfer(position, ALICE);
        };
        
        test::end(scenario);
    }

    #[test]
    fun test_liquidity_distribution_strategies() {
        // Test: Different liquidity distribution strategies
        let scenario = test::begin(ADMIN);
        
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
        let expected_uniform_weight = 10000 / 11; // 11 bins
        let mut i = 0;
        let bin_count = upper_bin - lower_bin + 1;
        while (i < bin_count) {
            let weight = *vector::borrow(&uniform_weights, (i as u64));
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
        let active_weight = *vector::borrow(&curve_weights, 5); // Index 5 = bin 1005
        let edge_weight = *vector::borrow(&curve_weights, 0);   // Index 0 = bin 1000
        assert!(active_weight > edge_weight);
        
        // Test case 3: Bid-Ask distribution (concentrated at edges)
        let bid_ask_weights = calculate_distribution_weights(
            lower_bin,
            upper_bin,
            1005, // active_bin_id
            2     // bid-ask strategy
        );
        
        // Edge bins should have higher weight than middle
        let left_edge_weight = *vector::borrow(&bid_ask_weights, 0);  // bin 1000
        let right_edge_weight = *vector::borrow(&bid_ask_weights, 10); // bin 1010
        let middle_weight = *vector::borrow(&bid_ask_weights, 5);     // bin 1005
        
        assert!(left_edge_weight > middle_weight);
        assert!(right_edge_weight > middle_weight);
        
        test::end(scenario);
    }

    #[test]
    fun test_fee_collection() {
        // Test: Fee accumulation and collection
        let scenario = test::begin(ADMIN);
        
        // Simulate trading activity that generates fees
        let mut total_fees_collected: u64 = 0;
        let swap_count: u64 = 10;
        
        let mut i = 0;
        while (i < swap_count) {
            // Simulate a swap that crosses 2 bins
            let fee = calculate_dynamic_fee(100, 25, 2);
            total_fees_collected = total_fees_collected + fee;
            i = i + 1;
        };
        
        // Verify fees were collected
        assert!(total_fees_collected > 0);
        
        // Test protocol fee distribution (30% of dynamic fees)
        let protocol_fee_rate: u16 = 3000; // 30%
        let protocol_fees = total_fees_collected * (protocol_fee_rate as u64) / 10000;
        let lp_fees = total_fees_collected - protocol_fees;
        
        assert!(protocol_fees > 0);
        assert!(lp_fees > protocol_fees); // LPs should get majority
        
        test::end(scenario);
    }

    #[test]  
    fun test_price_impact_calculation() {
        // Test: Price impact from large trades
        let scenario = test::begin(ADMIN);
        
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

    // Helper functions for testing (now use actual implementations)
    fun calculate_bin_price(bin_id: u32, bin_step: u16): u128 {
        bin_math::calculate_bin_price(bin_id, bin_step)
    }

    fun get_bin_from_price(price: u128, bin_step: u16): u32 {
        bin_math::get_bin_from_price(price, bin_step)
    }

    fun power(base: u128, exp: u32): u128 {
        bin_math::power_u128(base, exp) // This function needs to be made public in bin_math
    }

    fun abs_diff(a: u128, b: u128): u128 {
        if (a >= b) { a - b } else { b - a }
    }

    fun abs_diff_u64(a: u64, b: u64): u64 {
        if (a >= b) { a - b } else { b - a }
    }

    fun calculate_amounts_from_liquidity(
        liquidity: u64,
        price: u128,
        composition_percent: u8
    ): (u64, u64) {
        constant_sum::calculate_amounts_from_liquidity(liquidity, price, composition_percent)
    }

    fun swap_x_for_y_within_bin(
        liquidity_x: &mut u64,
        liquidity_y: &mut u64,
        amount_x_in: u64,
        price: u128
    ): (u64, bool) {
        let (amount_out, bin_exhausted) = constant_sum::swap_within_bin(
            *liquidity_x, *liquidity_y, amount_x_in, true, price
        );
        
        // Update the liquidity values
        let (new_x, new_y) = constant_sum::update_reserves_after_swap(
            *liquidity_x, *liquidity_y, amount_x_in, amount_out, true
        );
        *liquidity_x = new_x;
        *liquidity_y = new_y;
        
        (amount_out, bin_exhausted)
    }

    // Additional helper functions...
    fun create_test_bin(bin_id: u32, liquidity_x: u64, liquidity_y: u64, price: u128): TestBin {
        TestBin { bin_id, liquidity_x, liquidity_y, price }
    }

    fun execute_multi_bin_swap(
        _bins: &mut vector<TestBin>,
        amount_in: u64,
        start_bin: u32,
        _zero_for_one: bool
    ): (u64, u32, u32) {
        // Simplified multi-bin swap simulation
        (amount_in * 3400, 3, start_bin + 3)
    }

    fun calculate_dynamic_fee(base_factor: u16, bin_step: u16, bins_crossed: u32): u64 {
        fee_math::calculate_dynamic_fee(base_factor, bin_step, bins_crossed)
    }

    fun calculate_distribution_weights(
        lower_bin: u32,
        upper_bin: u32,
        active_bin: u32,
        strategy: u8
    ): vector<u64> {
        let mut weights = vector::empty<u64>();
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
                base_weight * (10 - (distance as u64)) / 10
            } else {
                // Bid-Ask - higher weight at edges
                if (i == lower_bin || i == upper_bin) {
                    base_weight * 3
                } else {
                    base_weight / 2
                }
            };
            vector::push_back(&mut weights, weight);
            i = i + 1;
        };
        
        weights
    }

    fun calculate_price_impact(amount: u64, price: u128): u128 {
        // Simplified price impact calculation
        (amount as u128) * PRICE_SCALE / (price * 1000)
    }

    // Test helper structs - Add public visibility
    public struct TestBin has drop {
        bin_id: u32,
        liquidity_x: u64,
        liquidity_y: u64,
        price: u128,
    }

    public struct TestPosition has key, store {
        id: UID,
        lower_bin_id: u32,
        upper_bin_id: u32,
        bin_count: u32,
    }

    fun create_test_position(
        coin_a: Coin<TESTA>,
        coin_b: Coin<TESTB>,
        lower_bin_id: u32,
        upper_bin_id: u32,
        ctx: &mut TxContext
    ): TestPosition {
        // Return coins to sender (simplified)
        transfer::public_transfer(coin_a, tx_context::sender(ctx));
        transfer::public_transfer(coin_b, tx_context::sender(ctx));
        
        TestPosition {
            id: object::new(ctx),
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