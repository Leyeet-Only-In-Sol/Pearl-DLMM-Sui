#[test_only]
module sui_dlmm::test_bin_math_comprehensive {
    use sui::test_scenario::{Self as test};
    use sui::test_utils::assert_eq;
    
    use sui_dlmm::bin_math;

    const ADMIN: address = @0x1;
    const PRICE_SCALE: u128 = 18446744073709551616; // 2^64

    /// Test: Comprehensive bin math validation - Price calculations, bin conversions, edge cases
    #[test]
    fun test_bin_math_comprehensive() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== BIN MATH COMPREHENSIVE TEST ==="));
        
        // Test 1: Various bin steps accuracy
        test_bin_step_accuracy();
        
        // Test 2: Price calculation precision
        test_price_calculation_precision();
        
        // Test 3: Bin conversion round-trip accuracy
        test_bin_conversion_round_trip();
        
        // Test 4: Edge cases and extreme values
        test_edge_cases_and_extremes();
        
        // Test 5: Mathematical properties validation
        test_mathematical_properties();
        
        std::debug::print(&std::string::utf8(b"✅ All bin math comprehensive tests passed"));
        
        test::end(scenario);
    }

    /// Test accuracy across different bin steps
    fun test_bin_step_accuracy() {
        std::debug::print(&std::string::utf8(b"--- Testing bin step accuracy ---"));
        
        let bin_steps = vector[1, 5, 10, 25, 50, 100, 200, 500, 1000];
        let mut i = 0;
        
        while (i < vector::length(&bin_steps)) {
            let bin_step = *vector::borrow(&bin_steps, i);
            
            // Test price calculation accuracy using built-in test function
            assert!(bin_math::test_price_calculation_accuracy(bin_step), 0);
            
            // Test mathematical properties using built-in test function
            assert!(bin_math::test_mathematical_properties(bin_step), 0);
            
            std::debug::print(&std::string::utf8(b"✓ Bin step validated: "));
            std::debug::print(&bin_step);
            
            i = i + 1;
        };
    }

    /// Test price calculation precision for specific cases
    fun test_price_calculation_precision() {
        std::debug::print(&std::string::utf8(b"--- Testing price calculation precision ---"));
        
        let bin_step = 25u16; // 0.25%
        
        // Test case 1: bin_id = 0 should give base price (1.0)
        let price_0 = bin_math::calculate_bin_price(0, bin_step);
        assert_eq(price_0, PRICE_SCALE);
        
        // Test case 2: bin_id = 1 should give 1.0025
        let price_1 = bin_math::calculate_bin_price(1, bin_step);
        let expected_price_1 = PRICE_SCALE + (PRICE_SCALE * 25) / 10000; // 1.0025
        let diff_1 = abs_diff(price_1, expected_price_1);
        assert!(diff_1 < PRICE_SCALE / 100000, 0); // 0.001% tolerance
        
        // Test case 3: bin_id = 100 should give 1.0025^100
        let price_100 = bin_math::calculate_bin_price(100, bin_step);
        assert!(price_100 > PRICE_SCALE, 0); // Should be > 1.0
        assert!(price_100 < PRICE_SCALE * 2, 0); // Should be reasonable
        
        // Test case 4: Very large bin_id (but safe)
        let price_large = bin_math::calculate_bin_price(10000, bin_step);
        assert!(price_large > price_100, 0); // Should be larger
        
        std::debug::print(&std::string::utf8(b"✓ Price precision validated"));
    }

    /// Test bin conversion round-trip accuracy
    fun test_bin_conversion_round_trip() {
        std::debug::print(&std::string::utf8(b"--- Testing bin conversion round-trip ---"));
        
        let bin_step = 25u16;
        let test_bin_ids = vector[0, 1, 10, 100, 1000, 5000];
        
        let mut i = 0;
        while (i < vector::length(&test_bin_ids)) {
            let original_bin_id = *vector::borrow(&test_bin_ids, i);
            
            // Forward: bin_id -> price
            let price = bin_math::calculate_bin_price(original_bin_id, bin_step);
            
            // Reverse: price -> bin_id
            let recovered_bin_id = bin_math::get_bin_from_price(price, bin_step);
            
            // Check accuracy (allow 1 bin tolerance due to precision)
            let bin_diff = abs_diff_u32(original_bin_id, recovered_bin_id);
            assert!(bin_diff <= 1, 0);
            
            std::debug::print(&std::string::utf8(b"✓ Round-trip: "));
            std::debug::print(&original_bin_id);
            std::debug::print(&std::string::utf8(b" -> "));
            std::debug::print(&recovered_bin_id);
            
            i = i + 1;
        };
    }

    /// Test edge cases and extreme values
    fun test_edge_cases_and_extremes() {
        std::debug::print(&std::string::utf8(b"--- Testing edge cases and extremes ---"));
        
        // Test minimum bin step
        let min_bin_step = 1u16;
        let price_min = bin_math::calculate_bin_price(100, min_bin_step);
        assert!(price_min > PRICE_SCALE, 0);
        
        // Test maximum reasonable bin step
        let max_bin_step = 1000u16; // 10%
        let price_max = bin_math::calculate_bin_price(10, max_bin_step);
        assert!(price_max > PRICE_SCALE, 0);
        
        // Test zero bin_id
        let price_zero = bin_math::calculate_bin_price(0, 25);
        assert_eq(price_zero, PRICE_SCALE);
        
        // Test get_next_bin_id function
        let current_bin = 1000u32;
        let next_up = bin_math::get_next_bin_id(current_bin, false); // false = up
        let next_down = bin_math::get_next_bin_id(current_bin, true); // true = down
        
        assert_eq(next_up, current_bin + 1);
        assert_eq(next_down, current_bin - 1);
        
        // Test zero bin edge case
        let next_from_zero = bin_math::get_next_bin_id(0, true);
        assert_eq(next_from_zero, 0); // Should handle underflow
        
        std::debug::print(&std::string::utf8(b"✓ Edge cases validated"));
    }

    /// Test mathematical properties and invariants
    fun test_mathematical_properties() {
        std::debug::print(&std::string::utf8(b"--- Testing mathematical properties ---"));
        
        let bin_step = 25u16;
        
        // Property 1: Monotonicity - higher bin_id = higher price
        let price_low = bin_math::calculate_bin_price(100, bin_step);
        let price_high = bin_math::calculate_bin_price(200, bin_step);
        assert!(price_high > price_low, 0);
        
        // Property 2: Multiplicative step consistency
        let price_n = bin_math::calculate_bin_price(50, bin_step);
        let price_n_plus_1 = bin_math::calculate_bin_price(51, bin_step);
        let step_multiplier = bin_math::get_bin_step_multiplier(bin_step);
        
        // price_n * step_multiplier ≈ price_n_plus_1
        let calculated_next = multiply_scaled(price_n, step_multiplier);
        let diff = abs_diff(calculated_next, price_n_plus_1);
        assert!(diff < price_n_plus_1 / 1000, 0); // 0.1% tolerance
        
        // Property 3: Price difference calculation
        let price_diff = bin_math::calculate_price_difference(100, 110, bin_step);
        assert!(price_diff > 0, 0);
        
        // Property 4: Step multiplier is > 1.0
        let multiplier = bin_math::get_bin_step_multiplier(bin_step);
        assert!(multiplier > PRICE_SCALE, 0);
        
        std::debug::print(&std::string::utf8(b"✓ Mathematical properties validated"));
    }

    /// Helper function: multiply two scaled numbers
    fun multiply_scaled(a: u128, b: u128): u128 {
        (a * b) / PRICE_SCALE
    }

    /// Helper function: absolute difference
    fun abs_diff(a: u128, b: u128): u128 {
        if (a >= b) { a - b } else { b - a }
    }

    /// Helper function: absolute difference for u32
    fun abs_diff_u32(a: u32, b: u32): u32 {
        if (a >= b) { a - b } else { b - a }
    }

    /// Additional test: Power function accuracy
    #[test]
    fun test_power_function_accuracy() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== POWER FUNCTION ACCURACY TEST ==="));
        
        // Test base cases
        let result_0 = bin_math::power_u128(PRICE_SCALE * 2, 0);
        assert_eq(result_0, PRICE_SCALE); // x^0 = 1
        
        let result_1 = bin_math::power_u128(PRICE_SCALE * 3, 1);
        assert_eq(result_1, PRICE_SCALE * 3); // x^1 = x
        
        // Test small exponents
        let base = PRICE_SCALE + PRICE_SCALE / 100; // 1.01
        let result_2 = bin_math::power_u128(base, 2);
        let expected_2 = multiply_scaled(base, base);
        let diff_2 = abs_diff(result_2, expected_2);
        assert!(diff_2 < PRICE_SCALE / 10000, 0); // 0.01% tolerance
        
        // Test larger exponents
        let result_10 = bin_math::power_u128(base, 10);
        assert!(result_10 > base, 0); // Should be larger than base
        
        std::debug::print(&std::string::utf8(b"✓ Power function accuracy validated"));
        
        test::end(scenario);
    }

    /// Additional test: Sqrt function accuracy
    #[test]
    fun test_sqrt_function_accuracy() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== SQRT FUNCTION ACCURACY TEST ==="));
        
        // Test perfect squares
        let sqrt_0 = bin_math::sqrt(0);
        assert_eq(sqrt_0, 0);
        
        let sqrt_1 = bin_math::sqrt(1);
        assert_eq(sqrt_1, 1);
        
        let sqrt_4 = bin_math::sqrt(4);
        assert_eq(sqrt_4, 2);
        
        let sqrt_9 = bin_math::sqrt(9);
        assert_eq(sqrt_9, 3);
        
        // Test large numbers
        let large_num = 1000000u128;
        let sqrt_large = bin_math::sqrt(large_num);
        assert_eq(sqrt_large, 1000); // sqrt(1,000,000) = 1,000
        
        // Test precision for non-perfect squares
        let num_10 = 10u128;
        let sqrt_10 = bin_math::sqrt(num_10);
        assert!(sqrt_10 >= 3, 0); // sqrt(10) ≈ 3.16, should be at least 3
        assert!(sqrt_10 <= 4, 0); // Should not exceed 4
        
        std::debug::print(&std::string::utf8(b"✓ Sqrt function accuracy validated"));
        
        test::end(scenario);
    }

    /// Additional test: Price scale consistency
    #[test]
    fun test_price_scale_consistency() {
        let scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== PRICE SCALE CONSISTENCY TEST ==="));
        
        let bin_step = 25u16;
        
        // Test that price scale is consistent across calculations
        let bin_id_1000 = 1000u32;
        let price_1000 = bin_math::calculate_bin_price(bin_id_1000, bin_step);
        
        // Price should be properly scaled
        assert!(price_1000 > PRICE_SCALE, 0); // Should be > 1.0
        assert!(price_1000 < PRICE_SCALE * 1000, 0); // Should be reasonable
        
        // Test step multiplier scaling
        let multiplier = bin_math::get_bin_step_multiplier(bin_step);
        assert!(multiplier > PRICE_SCALE, 0); // > 1.0
        assert!(multiplier < PRICE_SCALE * 2, 0); // < 2.0 for reasonable bin steps
        
        // Test price difference scaling
        let diff = bin_math::calculate_price_difference(1000, 1001, bin_step);
        assert!(diff > 0, 0);
        assert!(diff < price_1000, 0); // Difference should be less than absolute price
        
        std::debug::print(&std::string::utf8(b"✓ Price scale consistency validated"));
        
        test::end(scenario);
    }
}