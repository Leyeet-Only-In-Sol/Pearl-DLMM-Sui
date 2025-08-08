#[test_only]
module sui_dlmm::math_tests {
    use sui::test_scenario::{Self as test};
    use sui::test_utils::assert_eq;
    
    use sui_dlmm::bin_math;
    use sui_dlmm::constant_sum;
    use sui_dlmm::fee_math;
    use sui_dlmm::volatility;

    const ADMIN: address = @0x1;
    const PRICE_SCALE: u128 = 18446744073709551616; // 2^64

    // ==================== 📊 BIN MATH TESTS ====================

    #[test]
    fun test_bin_math_comprehensive() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== BIN MATH COMPREHENSIVE TEST ==="));
        
        // Test various bin steps
        let bin_steps = vector[1, 5, 10, 25, 50, 100, 200, 500, 1000];
        let mut i = 0;
        
        while (i < vector::length(&bin_steps)) {
            let bin_step = *vector::borrow(&bin_steps, i);
            
            // Test price calculation accuracy
            assert!(bin_math::test_price_calculation_accuracy(bin_step), 0);
            
            // Test mathematical properties
            assert!(bin_math::test_mathematical_properties(bin_step), 0);
            
            std::debug::print(&std::string::utf8(b"✅ Bin step validated: "));
            std::debug::print(&bin_step);
            
            i = i + 1;
        };
        
        // Test specific price calculations
        let bin_id_100 = 100u32;
        let bin_step_25 = 25u16;
        let price_100 = bin_math::calculate_bin_price(bin_id_100, bin_step_25);
        
        // Reverse calculation should be accurate
        let recovered_bin = bin_math::get_bin_from_price(price_100, bin_step_25);
        let bin_diff = if (recovered_bin >= bin_id_100) {
            recovered_bin - bin_id_100
        } else {
            bin_id_100 - recovered_bin
        };
        assert!(bin_diff <= 1, 0); // Within 1 bin accuracy
        
        std::debug::print(&std::string::utf8(b"✅ Bin math comprehensive test passed"));
        
        test::end(scenario);
    }

    #[test]
    fun test_mathematical_precision_stress() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== MATHEMATICAL PRECISION STRESS TEST ==="));
        
        // Test extreme values and edge cases
        let extreme_bin_steps = vector[1u16, 5000u16, 10000u16];
        let extreme_bin_ids = vector[0u32, 1u32, 100000u32, 4294967295u32]; // Including u32::MAX
        
        let mut i = 0;
        while (i < vector::length(&extreme_bin_steps)) {
            let bin_step = *vector::borrow(&extreme_bin_steps, i);
            
            let mut j = 0;
            while (j < vector::length(&extreme_bin_ids)) {
                let bin_id = *vector::borrow(&extreme_bin_ids, j);
                
                // Skip combinations that would overflow
                if (bin_id < 100000 || bin_step < 1000) {
                    let price = bin_math::calculate_bin_price(bin_id, bin_step);
                    assert!(price > 0, 0);
                    
                    // Test reverse calculation for reasonable ranges
                    if (bin_id < 10000) {
                        let recovered_bin = bin_math::get_bin_from_price(price, bin_step);
                        let diff = if (recovered_bin >= bin_id) {
                            recovered_bin - bin_id
                        } else {
                            bin_id - recovered_bin
                        };
                        assert!(diff <= 2, 0); // Allow 2 bin tolerance for extreme values
                    };
                };
                
                j = j + 1;
            };
            i = i + 1;
        };
        
        std::debug::print(&std::string::utf8(b"✅ Mathematical precision stress test passed"));
        test::end(scenario);
    }

    // ==================== 🧮 CONSTANT SUM TESTS ====================

    #[test]
    fun test_constant_sum_comprehensive() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== CONSTANT SUM COMPREHENSIVE TEST ==="));
        
        // Test constant sum invariant
        assert!(constant_sum::test_constant_sum_invariant(), 0);
        
        // Test zero-slippage swaps
        assert!(constant_sum::test_zero_slippage_swaps(), 0);
        
        // Test max swap calculations
        assert!(constant_sum::test_max_swap_amount_calculation(), 0);
        
        // Test mathematical consistency
        assert!(constant_sum::test_mathematical_consistency(), 0);
        
        std::debug::print(&std::string::utf8(b"✅ Constant sum comprehensive test passed"));
        test::end(scenario);
    }

    #[test]
    fun test_constant_sum_edge_cases() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== CONSTANT SUM EDGE CASES TEST ==="));
        
        // Test extreme liquidity compositions - FIXED: No tuples in vectors
        let test_price = bin_math::calculate_bin_price(1000, 25);
        
        // Test case 1: Very imbalanced (favor X)
        let amount_x_1 = 1u64;
        let amount_y_1 = 1000000000u64;
        let liquidity_1 = constant_sum::calculate_liquidity_from_amounts(amount_x_1, amount_y_1, test_price);
        assert!(liquidity_1 > 0, 0);
        let composition_1 = constant_sum::calculate_composition_percentage(amount_x_1, amount_y_1, test_price);
        assert!(composition_1 <= 100, 0);
        
        // Test case 2: Very imbalanced (favor Y)  
        let amount_x_2 = 1000000000u64;
        let amount_y_2 = 1u64;
        let liquidity_2 = constant_sum::calculate_liquidity_from_amounts(amount_x_2, amount_y_2, test_price);
        assert!(liquidity_2 > 0, 0);
        let composition_2 = constant_sum::calculate_composition_percentage(amount_x_2, amount_y_2, test_price);
        assert!(composition_2 <= 100, 0);
        
        // Test case 3: Near u64::MAX (but safe)
        let max_safe = 18446744073709551615u64 / 1000; // Much safer value
        let amount_x_3 = max_safe;
        let amount_y_3 = max_safe;
        let liquidity_3 = constant_sum::calculate_liquidity_from_amounts(amount_x_3, amount_y_3, test_price);
        assert!(liquidity_3 > 0, 0);
        let composition_3 = constant_sum::calculate_composition_percentage(amount_x_3, amount_y_3, test_price);
        assert!(composition_3 <= 100, 0);
        
        std::debug::print(&std::string::utf8(b"Liquidity 1: "));
        std::debug::print(&liquidity_1);
        std::debug::print(&std::string::utf8(b"Composition 1: "));
        std::debug::print(&composition_1);
        std::debug::print(&std::string::utf8(b"Liquidity 2: "));
        std::debug::print(&liquidity_2);
        std::debug::print(&std::string::utf8(b"Composition 2: "));
        std::debug::print(&composition_2);
        
        std::debug::print(&std::string::utf8(b"✅ Constant sum edge cases test passed"));
        test::end(scenario);
    }

    // ==================== 💰 FEE MATH TESTS ====================

    #[test]
    fun test_fee_math_comprehensive() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== FEE MATH COMPREHENSIVE TEST ==="));
        
        // Test dynamic fee scaling
        assert!(fee_math::test_dynamic_fee_scaling(), 0);
        
        // Test protocol fee calculation
        assert!(fee_math::test_protocol_fee_calculation(), 0);
        
        // Test swap fee calculations
        assert!(fee_math::test_swap_fee_calculations(), 0);
        
        // Test volatility accumulator
        assert!(fee_math::test_volatility_accumulator(), 0);
        
        // Test variable fee calculation
        assert!(fee_math::test_variable_fee_calculation(), 0);
        
        // Test minimum fee guarantees
        assert!(fee_math::test_minimum_fee_guarantees(), 0);
        
        std::debug::print(&std::string::utf8(b"✅ Fee math comprehensive test passed"));
        test::end(scenario);
    }

    #[test]
    fun test_fee_calculation_edge_cases() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== FEE CALCULATION EDGE CASES TEST ==="));
        
        // Test minimum fee guarantees
        let small_amount = 1u64;
        let small_rate = 1u64;
        let fee = fee_math::calculate_fee_amount(small_amount, small_rate);
        
        // Should either be 0 (due to rounding) or minimum 1
        assert!(fee <= 1, 0);
        
        // Test large amounts don't overflow
        let large_amount = 18446744073709551615u64 / 10000; // Safe large amount
        let normal_rate = 2500u64; // 25% when properly scaled
        let large_fee = fee_math::calculate_fee_amount(large_amount, normal_rate);
        assert!(large_fee <= large_amount, 0); // Fee shouldn't exceed input
        
        // Test dynamic fee scaling edge cases
        let extreme_volatility = 1000u32; // Very high bin crossings
        let extreme_fee = fee_math::calculate_dynamic_fee(100, 25, extreme_volatility);
        assert!(extreme_fee > 0, 0); // Should still be calculable
        
        // Test protocol fee edge cases
        let zero_total_fee = 0u64;
        let protocol_fee_zero = fee_math::calculate_protocol_fee(zero_total_fee, 3000);
        assert_eq(protocol_fee_zero, 0);
        
        let max_protocol_rate = 5000u16; // 50%
        let half_fee = fee_math::calculate_protocol_fee(1000, max_protocol_rate);
        assert_eq(half_fee, 500); // Should be exactly half
        
        std::debug::print(&std::string::utf8(b"✅ Fee calculation edge cases test passed"));
        test::end(scenario);
    }

    // ==================== 📈 VOLATILITY TESTS ====================

    #[test]
    fun test_volatility_comprehensive() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== VOLATILITY COMPREHENSIVE TEST ==="));
        
        // Test volatility accumulator basic operations
        assert!(volatility::test_volatility_accumulator_basic(), 0);
        
        // Test volatility updates and decay
        assert!(volatility::test_volatility_update_and_decay(), 0);
        
        // Test volatility fee multiplier
        assert!(volatility::test_volatility_fee_multiplier(), 0);
        
        // Test exponential decay
        assert!(volatility::test_exponential_decay(), 0);
        
        // Test high volatility detection
        assert!(volatility::test_high_volatility_detection(), 0);
        
        // Test volatility stats
        assert!(volatility::test_volatility_stats(), 0);
        
        std::debug::print(&std::string::utf8(b"✅ Volatility comprehensive test passed"));
        test::end(scenario);
    }

    #[test]
    fun test_volatility_advanced_scenarios() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== VOLATILITY ADVANCED SCENARIOS TEST ==="));
        
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
        assert!(new_volatility > 0, 0); // Should have increased
        
        // Test high volatility scenarios
        let high_vol_accumulator = volatility::update_volatility_accumulator(
            updated_accumulator,
            1050, // Far away
            25,   // Many bins crossed
            current_time + 10000
        );
        
        assert!(volatility::is_high_volatility(&high_vol_accumulator), 0);
        
        // Test volatility decay over long periods
        let decayed_accumulator = volatility::update_volatility_accumulator(
            high_vol_accumulator,
            1050,
            0, // No new bins crossed
            current_time + 3600000 // 1 hour later
        );
        
        let decayed_value = volatility::get_volatility_value(&decayed_accumulator);
        let original_value = volatility::get_volatility_value(&high_vol_accumulator);
        assert!(decayed_value < original_value, 0); // Should have decayed
        
        std::debug::print(&std::string::utf8(b"Initial volatility: "));
        std::debug::print(&new_volatility);
        std::debug::print(&std::string::utf8(b"High volatility: "));
        std::debug::print(&original_value);
        std::debug::print(&std::string::utf8(b"Decayed volatility: "));
        std::debug::print(&decayed_value);
        
        std::debug::print(&std::string::utf8(b"✅ Volatility advanced scenarios test passed"));
        test::end(scenario);
    }

    // ==================== 🧪 MATHEMATICAL INTEGRATION TESTS ====================

    #[test]
    fun test_math_module_integration() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== MATH MODULE INTEGRATION TEST ==="));
        
        // Test bin math + constant sum integration
        let bin_id = 1000u32;
        let bin_step = 25u16;
        let price = bin_math::calculate_bin_price(bin_id, bin_step);
        
        let liquidity_x = 100000u64;
        let liquidity_y = 330000u64;
        
        // Calculate liquidity using price from bin math
        let total_liquidity = constant_sum::calculate_liquidity_from_amounts(
            liquidity_x, liquidity_y, price
        );
        assert!(total_liquidity > 0, 0);
        
        // Verify constant sum invariant holds
        let invariant_holds = constant_sum::verify_constant_sum_invariant(
            liquidity_x, liquidity_y, price, total_liquidity, 100
        );
        assert!(invariant_holds, 0);
        
        // Test fee math + volatility integration
        let base_factor = 100u16;
        let bins_crossed = 5u32;
        
        let dynamic_fee = fee_math::calculate_dynamic_fee(base_factor, bin_step, bins_crossed);
        assert!(dynamic_fee > 0, 0);
        
        // Fee should increase with volatility
        let higher_volatility_fee = fee_math::calculate_dynamic_fee(base_factor, bin_step, bins_crossed * 2);
        assert!(higher_volatility_fee > dynamic_fee, 0);
        
        // Test swap amount with calculated fee
        let swap_amount = 10000u64;
        let fee_amount = fee_math::calculate_fee_amount(swap_amount, dynamic_fee);
        assert!(fee_amount > 0, 0);
        assert!(fee_amount < swap_amount, 0);
        
        std::debug::print(&std::string::utf8(b"Price from bin math: "));
        std::debug::print(&price);
        std::debug::print(&std::string::utf8(b"Total liquidity: "));
        std::debug::print(&total_liquidity);
        std::debug::print(&std::string::utf8(b"Dynamic fee: "));
        std::debug::print(&dynamic_fee);
        std::debug::print(&std::string::utf8(b"Fee amount: "));
        std::debug::print(&fee_amount);
        
        std::debug::print(&std::string::utf8(b"✅ Math module integration test passed"));
        test::end(scenario);
    }

    // ==================== 🎯 MATHEMATICAL ACCURACY VALIDATION ====================

    #[test]
    fun test_price_calculation_accuracy() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== PRICE CALCULATION ACCURACY TEST ==="));
        
        // Test: bin_id -> price and price -> bin_id conversions
        let bin_step: u16 = 25;
        
        // Test case 1: bin_id = 0 should give base price
        let bin_id_0: u32 = 0;
        let price_0 = bin_math::calculate_bin_price(bin_id_0, bin_step);
        assert_eq(price_0, PRICE_SCALE); // Should equal 1.0 in our price format
        
        // Test case 2: bin_id = 100 should give 1.0025^100
        let bin_id_100: u32 = 100;
        let price_100 = bin_math::calculate_bin_price(bin_id_100, bin_step);
        let expected_price_100 = bin_math::power_u128(10025 * PRICE_SCALE / 10000, 100);
        assert!(abs_diff(price_100, expected_price_100) < PRICE_SCALE / 1000, 0); // Allow 0.1% error
        
        // Test case 3: Reverse calculation - price -> bin_id
        let recovered_bin_id = bin_math::get_bin_from_price(price_100, bin_step);
        assert_eq(recovered_bin_id, bin_id_100);
        
        std::debug::print(&std::string::utf8(b"Price 0: "));
        std::debug::print(&price_0);
        std::debug::print(&std::string::utf8(b"Price 100: "));
        std::debug::print(&price_100);
        std::debug::print(&std::string::utf8(b"Recovered bin: "));
        std::debug::print(&recovered_bin_id);
        
        std::debug::print(&std::string::utf8(b"✅ Price calculation accuracy test passed"));
        test::end(scenario);
    }

    #[test]
    fun test_constant_sum_math() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== CONSTANT SUM MATH TEST ==="));
        
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
        assert!(abs_diff_u64(calculated_liquidity, liquidity) < 1000, 0); // Allow small rounding error
        
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
        
        std::debug::print(&std::string::utf8(b"Amount X (50%): "));
        std::debug::print(&amount_x);
        std::debug::print(&std::string::utf8(b"Amount Y (50%): "));
        std::debug::print(&amount_y);
        std::debug::print(&std::string::utf8(b"Calculated liquidity: "));
        std::debug::print(&calculated_liquidity);
        
        std::debug::print(&std::string::utf8(b"✅ Constant sum math test passed"));
        test::end(scenario);
    }

    #[test]
    fun test_swap_within_bin() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== SWAP WITHIN BIN TEST ==="));
        
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
        
        std::debug::print(&std::string::utf8(b"Amount Y out: "));
        std::debug::print(&amount_y_out);
        std::debug::print(&std::string::utf8(b"New liquidity X: "));
        std::debug::print(&new_liquidity_x);
        std::debug::print(&std::string::utf8(b"New liquidity Y: "));
        std::debug::print(&new_liquidity_y);
        
        std::debug::print(&std::string::utf8(b"✅ Swap within bin test passed"));
        test::end(scenario);
    }

    // ==================== 🔧 HELPER FUNCTIONS ====================

    fun abs_diff(a: u128, b: u128): u128 {
        if (a >= b) { a - b } else { b - a }
    }

    fun abs_diff_u64(a: u64, b: u64): u64 {
        if (a >= b) { a - b } else { b - a }
    }
}