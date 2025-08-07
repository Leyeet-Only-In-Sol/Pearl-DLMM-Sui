module sui_dlmm::constant_sum {
    // Mathematical constants
    const PRICE_SCALE: u128 = 18446744073709551616; // 2^64 for fixed-point arithmetic
    const PERCENTAGE_SCALE: u8 = 100; // 100% scale

    // Error codes
    const EINVALID_COMPOSITION: u64 = 1;
    const EINSUFFICIENT_LIQUIDITY: u64 = 2;
    const EINVALID_PRICE: u64 = 3;
    const EMATH_OVERFLOW: u64 = 4;
    const EZERO_LIQUIDITY: u64 = 5;

    /// Calculate token amounts from liquidity using constant sum formula: P*x + y = L
    /// 
    /// @param liquidity: Total liquidity in the bin
    /// @param price: Price of token X in terms of token Y (scaled by PRICE_SCALE)
    /// @param composition_percent: Percentage of liquidity that should be token Y (0-100)
    /// @returns (amount_x, amount_y): Token amounts that satisfy P*x + y = L
    public fun calculate_amounts_from_liquidity(
        liquidity: u64,
        price: u128,
        composition_percent: u8
    ): (u64, u64) {
        assert!(composition_percent <= PERCENTAGE_SCALE, EINVALID_COMPOSITION);
        assert!(price > 0, EINVALID_PRICE);
        assert!(liquidity > 0, EZERO_LIQUIDITY);

        // Calculate amount_y based on composition percentage
        let amount_y = (liquidity as u128) * (composition_percent as u128) / (PERCENTAGE_SCALE as u128);
        
        // Calculate amount_x using: P*x + y = L => x = (L - y) / P
        let remaining_liquidity = (liquidity as u128) - amount_y;
        let amount_x = (remaining_liquidity * PRICE_SCALE) / price;

        // Ensure we don't overflow u64 limits
        assert!(amount_x <= (18446744073709551615u64 as u128), EMATH_OVERFLOW);
        assert!(amount_y <= (18446744073709551615u64 as u128), EMATH_OVERFLOW);

        (amount_x as u64, amount_y as u64)
    }

    /// Calculate total liquidity from token amounts using: L = P*x + y
    ///
    /// @param amount_x: Amount of token X
    /// @param amount_y: Amount of token Y  
    /// @param price: Price of token X in terms of token Y (scaled by PRICE_SCALE)
    /// @returns Total liquidity in the bin
    public fun calculate_liquidity_from_amounts(
        amount_x: u64,
        amount_y: u64,
        price: u128
    ): u64 {
        assert!(price > 0, EINVALID_PRICE);

        // L = P*x + y
        let liquidity_from_x = ((amount_x as u128) * price) / PRICE_SCALE;
        let total_liquidity = liquidity_from_x + (amount_y as u128);

        assert!(total_liquidity <= (18446744073709551615u64 as u128), EMATH_OVERFLOW);
        total_liquidity as u64
    }

    /// Execute zero-slippage swap within a single bin using constant sum formula
    /// 
    /// @param liquidity_x: Current token X reserves in bin
    /// @param liquidity_y: Current token Y reserves in bin
    /// @param amount_in: Amount of input tokens to swap
    /// @param zero_for_one: True if swapping token X for Y, false for Y to X
    /// @param price: Bin price (scaled by PRICE_SCALE)
    /// @returns (amount_out, bin_exhausted): Output amount and whether bin is exhausted
    public fun swap_within_bin(
        liquidity_x: u64,
        liquidity_y: u64,
        amount_in: u64,
        zero_for_one: bool,
        price: u128
    ): (u64, bool) {
        assert!(price > 0, EINVALID_PRICE);
        assert!(amount_in > 0, EINSUFFICIENT_LIQUIDITY);

        if (zero_for_one) {
            // Swapping X for Y: add X, remove Y
            swap_x_for_y(liquidity_x, liquidity_y, amount_in, price)
        } else {
            // Swapping Y for X: add Y, remove X  
            swap_y_for_x(liquidity_x, liquidity_y, amount_in, price)
        }
    }

    /// Swap token X for token Y within bin
    /// Using constant sum: for each unit of X added, price units of Y are removed
    fun swap_x_for_y(
        _liquidity_x: u64,
        liquidity_y: u64,
        amount_x_in: u64,
        price: u128
    ): (u64, bool) {
        // Calculate how much Y we can get for amount_x_in
        // Each unit of X gives us 'price' units of Y (scaled)
        let amount_y_out_ideal = ((amount_x_in as u128) * price) / PRICE_SCALE;
        
        // Check if we have enough Y reserves
        let amount_y_out = if (amount_y_out_ideal <= (liquidity_y as u128)) {
            amount_y_out_ideal as u64
        } else {
            liquidity_y // Take all available Y
        };

        // Determine if bin is exhausted (no more Y tokens)
        let bin_exhausted = amount_y_out == liquidity_y;

        (amount_y_out, bin_exhausted)
    }

    /// Swap token Y for token X within bin
    /// Using constant sum: for each unit of Y added, 1/price units of X are removed
    fun swap_y_for_x(
        liquidity_x: u64,
        _liquidity_y: u64,
        amount_y_in: u64,
        price: u128
    ): (u64, bool) {
        // Calculate how much X we can get for amount_y_in
        // Each unit of Y gives us 1/price units of X
        let amount_x_out_ideal = ((amount_y_in as u128) * PRICE_SCALE) / price;
        
        // Check if we have enough X reserves
        let amount_x_out = if (amount_x_out_ideal <= (liquidity_x as u128)) {
            amount_x_out_ideal as u64
        } else {
            liquidity_x // Take all available X
        };

        // Determine if bin is exhausted (no more X tokens)
        let bin_exhausted = amount_x_out == liquidity_x;

        (amount_x_out, bin_exhausted)
    }

    /// Calculate the composition percentage of a bin given current reserves
    /// @param liquidity_x: Current X token reserves
    /// @param liquidity_y: Current Y token reserves  
    /// @param price: Bin price (scaled by PRICE_SCALE)
    /// @returns Percentage of total liquidity that is token Y (0-100)
    public fun calculate_composition_percentage(
        liquidity_x: u64,
        liquidity_y: u64,
        price: u128
    ): u8 {
        assert!(price > 0, EINVALID_PRICE);
        
        if (liquidity_x == 0 && liquidity_y == 0) return 0;

        // Calculate total liquidity: L = P*x + y
        let total_liquidity = calculate_liquidity_from_amounts(liquidity_x, liquidity_y, price);
        
        if (total_liquidity == 0) return 0;

        // Calculate Y percentage: (y / L) * 100
        let y_percentage = ((liquidity_y as u128) * (PERCENTAGE_SCALE as u128)) / (total_liquidity as u128);
        
        // Ensure it doesn't exceed 100%
        if (y_percentage > (PERCENTAGE_SCALE as u128)) {
            PERCENTAGE_SCALE
        } else {
            y_percentage as u8
        }
    }

    /// Check if the constant sum invariant holds for given amounts and price
    /// Verifies that P*x + y equals the expected liquidity within tolerance
    public fun verify_constant_sum_invariant(
        amount_x: u64,
        amount_y: u64,
        price: u128,
        expected_liquidity: u64,
        tolerance_bps: u16 // Tolerance in basis points (e.g., 100 = 1%)
    ): bool {
        let calculated_liquidity = calculate_liquidity_from_amounts(amount_x, amount_y, price);
        let diff = if (calculated_liquidity >= expected_liquidity) {
            calculated_liquidity - expected_liquidity
        } else {
            expected_liquidity - calculated_liquidity
        };

        // Check if difference is within tolerance
        let max_allowed_diff = ((expected_liquidity as u128) * (tolerance_bps as u128)) / 10000;
        (diff as u128) <= max_allowed_diff
    }

    /// Calculate maximum swap amount that can be executed within a bin - FIXED
    /// @param liquidity_x: Current X token reserves
    /// @param liquidity_y: Current Y token reserves
    /// @param zero_for_one: Direction of swap (X->Y or Y->X)
    /// @param price: Bin price
    /// @returns Maximum input amount that can be swapped
    public fun calculate_max_swap_amount(
        liquidity_x: u64,
        liquidity_y: u64,
        zero_for_one: bool,
        price: u128
    ): u64 {
        assert!(price > 0, EINVALID_PRICE);

        if (zero_for_one) {
            // Swapping X for Y - limited by available Y
            if (liquidity_y == 0) return 0; // FIXED: Handle zero liquidity case
            
            // max_x_in = liquidity_y * PRICE_SCALE / price
            let max_amount = ((liquidity_y as u128) * PRICE_SCALE) / price;
            
            // FIXED: Ensure we don't overflow u64 and handle edge cases
            if (max_amount > (18446744073709551615u64 as u128)) {
                18446744073709551615u64 // u64::MAX - prevent overflow
            } else if (max_amount == 0 && liquidity_y > 0) {
                1 // Minimum 1 unit if there's any liquidity Y available
            } else {
                max_amount as u64
            }
        } else {
            // Swapping Y for X - limited by available X  
            if (liquidity_x == 0) return 0; // FIXED: Handle zero liquidity case
            
            // max_y_in = liquidity_x * price / PRICE_SCALE
            let max_amount = ((liquidity_x as u128) * price) / PRICE_SCALE;
            
            // FIXED: Ensure we don't overflow u64 and handle edge cases
            if (max_amount > (18446744073709551615u64 as u128)) {
                18446744073709551615u64 // u64::MAX - prevent overflow
            } else if (max_amount == 0 && liquidity_x > 0) {
                1 // Minimum 1 unit if there's any liquidity X available
            } else {
                max_amount as u64
            }
        }
    }

    /// Calculate the effective exchange rate for a swap within a bin
    /// This should equal the bin price for zero-slippage swaps
    public fun calculate_effective_rate(
        amount_in: u64,
        amount_out: u64,
        zero_for_one: bool
    ): u128 {
        assert!(amount_in > 0 && amount_out > 0, EINSUFFICIENT_LIQUIDITY);

        if (zero_for_one) {
            // Rate = amount_out / amount_in (Y per X)
            ((amount_out as u128) * PRICE_SCALE) / (amount_in as u128)
        } else {
            // Rate = amount_in / amount_out (Y per X)
            ((amount_in as u128) * PRICE_SCALE) / (amount_out as u128)
        }
    }

    /// Update bin reserves after a swap
    /// @param liquidity_x: Current X reserves (will be updated)
    /// @param liquidity_y: Current Y reserves (will be updated)
    /// @param amount_in: Input amount
    /// @param amount_out: Output amount  
    /// @param zero_for_one: Swap direction
    /// @returns (new_liquidity_x, new_liquidity_y)
    public fun update_reserves_after_swap(
        liquidity_x: u64,
        liquidity_y: u64,
        amount_in: u64,
        amount_out: u64,
        zero_for_one: bool
    ): (u64, u64) {
        if (zero_for_one) {
            // X in, Y out
            (liquidity_x + amount_in, liquidity_y - amount_out)
        } else {
            // Y in, X out
            (liquidity_x - amount_out, liquidity_y + amount_in)
        }
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    /// Test the constant sum invariant for various scenarios
    public fun test_constant_sum_invariant(): bool {
        // Test different scenarios one by one instead of using tuple vectors
        
        // Test case 1: (1000000u64, 3400 * PRICE_SCALE, 50u8)
        let liquidity1 = 1000000u64;
        let price1 = 3400 * PRICE_SCALE;
        let composition1 = 50u8;
        
        let (amount_x1, amount_y1) = calculate_amounts_from_liquidity(
            liquidity1, price1, composition1
        );
        
        if (!verify_constant_sum_invariant(
            amount_x1, amount_y1, price1, liquidity1, 100
        )) {
            return false
        };
        
        // Test case 2: (5000000u64, 2500 * PRICE_SCALE, 25u8)
        let liquidity2 = 5000000u64;
        let price2 = 2500 * PRICE_SCALE;
        let composition2 = 25u8;
        
        let (amount_x2, amount_y2) = calculate_amounts_from_liquidity(
            liquidity2, price2, composition2
        );
        
        if (!verify_constant_sum_invariant(
            amount_x2, amount_y2, price2, liquidity2, 100
        )) {
            return false
        };
        
        // Test case 3: Edge cases
        let liquidity3 = 100000u64;
        let price3 = 1 * PRICE_SCALE;
        
        // 0% composition
        let (amount_x3a, amount_y3a) = calculate_amounts_from_liquidity(
            liquidity3, price3, 0
        );
        
        if (!verify_constant_sum_invariant(
            amount_x3a, amount_y3a, price3, liquidity3, 100
        )) {
            return false
        };
        
        // 100% composition
        let (amount_x3b, amount_y3b) = calculate_amounts_from_liquidity(
            liquidity3, price3, 100
        );
        
        if (!verify_constant_sum_invariant(
            amount_x3b, amount_y3b, price3, liquidity3, 100
        )) {
            return false
        };

        true
    }

    #[test_only]
    /// Test zero-slippage property of within-bin swaps
    public fun test_zero_slippage_swaps(): bool {
        let liquidity_x = 1000u64;
        let liquidity_y = 3400000u64;
        let price = 3400 * PRICE_SCALE;
        let swap_amount = 100u64;

        // Test X->Y swap
        let (amount_y_out, _) = swap_within_bin(
            liquidity_x, liquidity_y, swap_amount, true, price
        );
        
        // Verify rate equals bin price
        let effective_rate = calculate_effective_rate(swap_amount, amount_y_out, true);
        let rate_diff = if (effective_rate >= price) {
            effective_rate - price
        } else {
            price - effective_rate
        };
        
        // Rate should be within 0.1% of bin price (zero slippage)
        if (rate_diff > price / 1000) return false;

        // Test Y->X swap  
        let (amount_x_out, _) = swap_within_bin(
            liquidity_x, liquidity_y, 340000u64, false, price
        );
        
        let effective_rate_reverse = calculate_effective_rate(340000u64, amount_x_out, false);
        let rate_diff_reverse = if (effective_rate_reverse >= price) {
            effective_rate_reverse - price  
        } else {
            price - effective_rate_reverse
        };
        
        if (rate_diff_reverse > price / 1000) return false;

        true
    }

    #[test_only]
    /// Test max swap amount calculation - ENHANCED
    public fun test_max_swap_amount_calculation(): bool {
        let price = 3400 * PRICE_SCALE; // $3400 per X token
        
        // Test case 1: Normal liquidity amounts
        let liquidity_x = 1000u64;
        let liquidity_y = 3400000u64; // 1000 * 3400
        
        let max_x_to_y = calculate_max_swap_amount(liquidity_x, liquidity_y, true, price);
        let max_y_to_x = calculate_max_swap_amount(liquidity_x, liquidity_y, false, price);
        
        // DEBUG: Print calculated values
        std::debug::print(&std::string::utf8(b"Max X->Y swap: "));
        std::debug::print(&max_x_to_y);
        std::debug::print(&std::string::utf8(b"Max Y->X swap: "));
        std::debug::print(&max_y_to_x);
        
        // Both should be positive
        if (max_x_to_y == 0) {
            std::debug::print(&std::string::utf8(b"ERROR: max_x_to_y is 0"));
            return false
        };
        if (max_y_to_x == 0) {
            std::debug::print(&std::string::utf8(b"ERROR: max_y_to_x is 0"));
            return false
        };
        
        // Test case 2: Zero liquidity edge cases
        let max_zero_x = calculate_max_swap_amount(0, liquidity_y, false, price);
        let max_zero_y = calculate_max_swap_amount(liquidity_x, 0, true, price);
        
        // Should return 0 when relevant liquidity is 0
        if (max_zero_x != 0) return false;
        if (max_zero_y != 0) return false;
        
        // Test case 3: Very high price edge case
        let high_price = 1000000 * PRICE_SCALE; // Very high price
        let max_high_price = calculate_max_swap_amount(1000, 1000, true, high_price);
        
        // Should handle high prices without overflow
        if (max_high_price > liquidity_y) return false; // Can't exceed available liquidity
        
        true
    }

    #[test_only]
    /// Test mathematical consistency - NEW
    public fun test_mathematical_consistency(): bool {
        let price = 2500 * PRICE_SCALE;
        let liquidity = 1000000u64;
        
        // Test round-trip: liquidity -> amounts -> liquidity
        let (amount_x, amount_y) = calculate_amounts_from_liquidity(liquidity, price, 50);
        let recovered_liquidity = calculate_liquidity_from_amounts(amount_x, amount_y, price);
        
        // Should be approximately equal (within 1%)
        let diff = if (recovered_liquidity >= liquidity) {
            recovered_liquidity - liquidity
        } else {
            liquidity - recovered_liquidity
        };
        
        if (diff > liquidity / 100) return false; // More than 1% error
        
        // Test swap consistency
        let swap_amount = 1000u64;
        let (out_amount, _) = swap_within_bin(amount_x, amount_y, swap_amount, true, price);
        
        // Output should be reasonable (not zero, not excessive)
        if (out_amount == 0) return false;
        if (out_amount > amount_y) return false;
        
        true
    }
}