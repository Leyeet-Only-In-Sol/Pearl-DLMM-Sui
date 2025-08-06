module sui_dlmm::bin_math {
    // Mathematical constants for precise calculations
    const PRICE_SCALE: u128 = 18446744073709551616; // 2^64 for fixed-point arithmetic
    const BASIS_POINT_MAX: u128 = 10000; // 100% in basis points
    const MAX_BIN_STEP: u16 = 10000; // Maximum allowed bin step (100%)
    
    // Error codes
    const EINVALID_BIN_STEP: u64 = 1;
    const EPRICE_TOO_HIGH: u64 = 2;
    const EPRICE_TOO_LOW: u64 = 3;
    const EMATH_OVERFLOW: u64 = 4;

    /// Calculate bin price from bin_id and bin_step
    /// Formula: Price(bin_id) = (1 + bin_step/10000)^bin_id
    /// Returns price scaled by PRICE_SCALE (2^64)
    public fun calculate_bin_price(bin_id: u32, bin_step: u16): u128 {
        assert!(bin_step <= MAX_BIN_STEP, EINVALID_BIN_STEP);
        
        // Handle special case: bin_id = 0 returns base price (1.0)
        if (bin_id == 0) {
            return PRICE_SCALE
        };

        // Calculate base = (1 + bin_step/10000) in scaled form
        let base = PRICE_SCALE + (PRICE_SCALE * (bin_step as u128) / BASIS_POINT_MAX);
        
        // Use efficient exponentiation: base^bin_id
        power_u128(base, bin_id)
    }

    /// Get bin_id from price and bin_step (reverse calculation)
    /// This is the inverse of calculate_bin_price
    public fun get_bin_from_price(price: u128, bin_step: u16): u32 {
        assert!(bin_step > 0, EINVALID_BIN_STEP);
        assert!(price > 0, EPRICE_TOO_LOW);
        
        // Handle base case: price = 1.0 (PRICE_SCALE)
        if (price <= PRICE_SCALE) {
            return 0
        };

        // Use logarithm approximation to find bin_id
        // bin_id ≈ log(price) / log(1 + bin_step/10000)
        log_approximation(price, bin_step)
    }

    /// Calculate the next bin_id given current bin and direction
    public fun get_next_bin_id(current_bin_id: u32, zero_for_one: bool): u32 {
        if (zero_for_one) {
            if (current_bin_id == 0) {
                // Handle underflow - this represents negative bin IDs
                // For now, we'll return 0 (could be extended with signed integers)
                0
            } else {
                current_bin_id - 1
            }
        } else {
            current_bin_id + 1
        }
    }

    /// Get the step size between two consecutive bin prices
    /// Returns the multiplicative factor: (1 + bin_step/10000)
    public fun get_bin_step_multiplier(bin_step: u16): u128 {
        PRICE_SCALE + (PRICE_SCALE * (bin_step as u128) / BASIS_POINT_MAX)
    }

    /// Calculate price difference between two bins
    public fun calculate_price_difference(
        lower_bin_id: u32,
        upper_bin_id: u32, 
        bin_step: u16
    ): u128 {
        let lower_price = calculate_bin_price(lower_bin_id, bin_step);
        let upper_price = calculate_bin_price(upper_bin_id, bin_step);
        
        if (upper_price >= lower_price) {
            upper_price - lower_price
        } else {
            lower_price - upper_price
        }
    }

    // ==================== Helper Functions ====================

    /// Efficient integer exponentiation using binary exponentiation
    /// Calculates base^exp where base is scaled by PRICE_SCALE
    fun power_u128(base: u128, exp: u32): u128 {
        if (exp == 0) return PRICE_SCALE;
        if (exp == 1) return base;
        
        let mut result = PRICE_SCALE;
        let mut current_base = base;
        let mut current_exp = exp;
        
        // Binary exponentiation algorithm
        while (current_exp > 0) {
            if (current_exp % 2 == 1) {
                result = multiply_scaled(result, current_base);
            };
            current_base = multiply_scaled(current_base, current_base);
            current_exp = current_exp / 2;
        };
        
        result
    }

    /// Multiply two scaled numbers (both scaled by PRICE_SCALE)
    /// Returns result also scaled by PRICE_SCALE
    fun multiply_scaled(a: u128, b: u128): u128 {
        // Use wider arithmetic to prevent overflow
        let result = (a as u256) * (b as u256) / (PRICE_SCALE as u256);
        assert!(result <= (340282366920938463463374607431768211455u128 as u256), EMATH_OVERFLOW);
        result as u128
    }

    /// Logarithm approximation using Taylor series
    /// Used to calculate bin_id from price
    fun log_approximation(price: u128, bin_step: u16): u32 {
        // For small bin_steps, we can use the approximation:
        // bin_id ≈ (price - PRICE_SCALE) / (bin_step * PRICE_SCALE / 10000)
        
        if (price <= PRICE_SCALE) return 0;
        
        let price_diff = price - PRICE_SCALE;
        let step_size = (bin_step as u128) * PRICE_SCALE / BASIS_POINT_MAX;
        
        // Simple linear approximation for small differences
        if (price_diff < PRICE_SCALE / 10) { // Less than 10% difference
            return (price_diff / step_size) as u32
        };

        // For larger differences, use iterative approach
        iterative_log_approximation(price, bin_step)
    }

    /// Iterative logarithm calculation for larger price differences
    fun iterative_log_approximation(price: u128, bin_step: u16): u32 {
        let step_multiplier = get_bin_step_multiplier(bin_step);
        let mut current_price = PRICE_SCALE;
        let mut bin_count = 0u32;
        
        // Iterate until we find the right bin
        while (current_price < price && bin_count < 1000000) { // Safety limit
            current_price = multiply_scaled(current_price, step_multiplier);
            bin_count = bin_count + 1;
        };
        
        // Return the bin just before exceeding the target price
        if (bin_count > 0) {
            bin_count - 1
        } else {
            0
        }
    }

    /// Square root function using Newton's method
    /// Used for price conversions and calculations
    public fun sqrt(x: u128): u128 {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        
        // Newton's method for square root
        let mut z = x;
        let mut y = (x + 1) / 2;
        
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        };
        
        z
    }

    /// Natural logarithm approximation for advanced calculations
    /// Uses Taylor series expansion: ln(1+x) = x - x²/2 + x³/3 - ...
    public fun ln_approximation(x: u128): u128 {
        assert!(x > 0, EPRICE_TOO_LOW);
        
        if (x == PRICE_SCALE) return 0; // ln(1) = 0
        
        // For x close to 1, use Taylor series
        if (x < PRICE_SCALE * 2) {
            let delta = if (x > PRICE_SCALE) { x - PRICE_SCALE } else { PRICE_SCALE - x };
            taylor_ln(delta)
        } else {
            // For larger values, use properties of logarithms
            // This is a simplified approximation
            (x - PRICE_SCALE) * PRICE_SCALE / x
        }
    }

    /// Taylor series approximation for ln(1+x) where x is small
    fun taylor_ln(x: u128): u128 {
        // ln(1+x) ≈ x - x²/2 + x³/3 - x⁴/4 + ...
        // We'll use first 4 terms for reasonable accuracy
        
        let x_scaled = x * PRICE_SCALE / PRICE_SCALE; // Normalize
        let x2 = multiply_scaled(x_scaled, x_scaled);
        let x3 = multiply_scaled(x2, x_scaled);
        let x4 = multiply_scaled(x3, x_scaled);
        
        // Calculate terms
        let term1 = x_scaled;
        let term2 = x2 / 2;
        let term3 = x3 / 3;
        let term4 = x4 / 4;
        
        // Sum the series: x - x²/2 + x³/3 - x⁴/4
        if (term1 >= term2) {
            let intermediate = term1 - term2;
            if (intermediate >= term4) {
                intermediate + term3 - term4
            } else {
                intermediate + term3
            }
        } else {
            term1 + term3
        }
    }

    // ==================== Test Helper Functions ====================
    
    #[test_only]
    /// Test helper to verify price calculation accuracy
    public fun test_price_calculation_accuracy(bin_step: u16): bool {
        let test_bin_ids = vector[0, 1, 10, 100, 1000];
        let mut i = 0;
        
        while (i < vector::length(&test_bin_ids)) {
            let bin_id = *vector::borrow(&test_bin_ids, i);
            let price = calculate_bin_price(bin_id, bin_step);
            let recovered_bin_id = get_bin_from_price(price, bin_step);
            
            // Allow some tolerance in reverse calculation
            let diff = if (bin_id >= recovered_bin_id) {
                bin_id - recovered_bin_id
            } else {
                recovered_bin_id - bin_id
            };
            
            // Should be within 1 bin of accuracy
            if (diff > 1) return false;
            
            i = i + 1;
        };
        
        true
    }

    #[test_only]
    /// Validate that mathematical properties hold
    public fun test_mathematical_properties(bin_step: u16): bool {
        // Test 1: Monotonicity - higher bin_id should give higher price
        let price_0 = calculate_bin_price(0, bin_step);
        let price_100 = calculate_bin_price(100, bin_step);
        if (price_100 <= price_0) return false;
        
        // Test 2: Multiplicative property
        let price_50 = calculate_bin_price(50, bin_step);
        let step_multiplier = get_bin_step_multiplier(bin_step);
        let calculated_price_51 = multiply_scaled(price_50, step_multiplier);
        let actual_price_51 = calculate_bin_price(51, bin_step);
        
        // Should be approximately equal (within 0.1%)
        let diff = if (calculated_price_51 >= actual_price_51) {
            calculated_price_51 - actual_price_51
        } else {
            actual_price_51 - calculated_price_51
        };
        
        if (diff > actual_price_51 / 1000) return false; // More than 0.1% error
        
        true
    }
}