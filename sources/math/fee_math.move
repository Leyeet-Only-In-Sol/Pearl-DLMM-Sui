module sui_dlmm::fee_math {
    // Mathematical constants
    const BASIS_POINTS_SCALE: u64 = 10000; // 100% in basis points
    const VOLATILITY_SCALE: u64 = 1000; // Scale for volatility calculations
    const MAX_VARIABLE_FEE_MULTIPLIER: u64 = 1000; // Max 10x base fee from volatility
    
    // Fee configuration constants
    const MAX_BASE_FACTOR: u16 = 1000; // Maximum base factor (10x)
    const MAX_PROTOCOL_FEE_RATE: u16 = 5000; // Maximum 50% protocol fee
    
    // Error codes
    const EINVALID_BASE_FACTOR: u64 = 1;
    const EINVALID_PROTOCOL_FEE_RATE: u64 = 2;
    const EINVALID_BIN_STEP: u64 = 3;
    const EMATH_OVERFLOW: u64 = 4;

    /// Calculate dynamic fee based on base fee and volatility - FIXED
    /// Dynamic fee = base_fee + variable_fee(volatility)
    /// 
    /// @param base_factor: Multiplier for base fee calculation (typically 100 = 1x)
    /// @param bin_step: Bin step in basis points (determines base fee)
    /// @param bins_crossed: Number of bins crossed in the swap (volatility indicator)
    /// @returns Dynamic fee in basis points (raw, not divided by BASIS_POINTS_SCALE)
    public fun calculate_dynamic_fee(
        base_factor: u16,
        bin_step: u16,
        bins_crossed: u32
    ): u64 {
        assert!(base_factor <= MAX_BASE_FACTOR, EINVALID_BASE_FACTOR);
        assert!(bin_step > 0 && bin_step <= 10000, EINVALID_BIN_STEP);

        // FIXED: Calculate base fee without premature division
        // This gives us the fee in "raw basis points" that we'll divide later when applying to amounts
        let base_fee = (base_factor as u64) * (bin_step as u64);
        
        // Calculate variable fee based on bins crossed (volatility)
        let variable_fee = calculate_variable_fee_fixed(base_fee, bins_crossed);
        
        // Total dynamic fee (in raw basis points)
        let total_fee = base_fee + variable_fee;
        
        // Ensure we don't overflow
        assert!(total_fee <= (18446744073709551615u64 / 100), EMATH_OVERFLOW);
        
        total_fee
    }

    /// Calculate variable fee component based on volatility (bins crossed) - FIXED
    /// Variable fee increases with volatility to compensate LPs for impermanent loss
    fun calculate_variable_fee_fixed(base_fee: u64, bins_crossed: u32): u64 {
        if (bins_crossed == 0) return 0;
        
        let bins_u64 = bins_crossed as u64;
        
        // FIXED: Simple but effective scaling that guarantees non-zero increases
        // Each bin crossed adds 10% of base fee as variable fee
        let variable_fee = (base_fee * bins_u64) / 10;
        
        // Ensure minimum increase per bin
        let minimum_increase = base_fee / 20; // At least 5% of base fee per bin
        let per_bin_minimum = minimum_increase * bins_u64;
        
        if (variable_fee < per_bin_minimum) {
            per_bin_minimum
        } else {
            variable_fee
        }
    }

    /// Calculate protocol fee from total dynamic fee
    /// Protocol fee is a percentage of the total fee paid to the protocol treasury
    /// 
    /// @param total_fee: Total dynamic fee amount (already applied to swap amount)
    /// @param protocol_fee_rate: Protocol fee rate in basis points (e.g., 300 = 3%)
    /// @returns Protocol fee amount
    public fun calculate_protocol_fee(total_fee: u64, protocol_fee_rate: u16): u64 {
        assert!(protocol_fee_rate <= MAX_PROTOCOL_FEE_RATE, EINVALID_PROTOCOL_FEE_RATE);
        
        (total_fee * (protocol_fee_rate as u64)) / BASIS_POINTS_SCALE
    }

    /// Calculate LP fee (remaining after protocol fee is deducted)
    /// 
    /// @param total_fee: Total dynamic fee amount  
    /// @param protocol_fee_rate: Protocol fee rate in basis points
    /// @returns LP fee amount
    public fun calculate_lp_fee(total_fee: u64, protocol_fee_rate: u16): u64 {
        let protocol_fee = calculate_protocol_fee(total_fee, protocol_fee_rate);
        total_fee - protocol_fee
    }

    /// Calculate fee amount for a specific swap - FIXED
    /// 
    /// @param swap_amount: Amount being swapped
    /// @param fee_rate: Fee rate in raw basis points (from calculate_dynamic_fee)
    /// @returns Fee amount in same units as swap_amount
    public fun calculate_fee_amount(swap_amount: u64, fee_rate: u64): u64 {
        // FIXED: Now we properly divide by BASIS_POINTS_SCALE here
        let fee_amount = (swap_amount * fee_rate) / BASIS_POINTS_SCALE;
        
        // Ensure minimum fee for non-zero swaps and non-zero rates
        if (fee_amount == 0 && swap_amount > 0 && fee_rate > 0) {
            1 // Minimum 1 unit fee
        } else {
            fee_amount
        }
    }

    /// Calculate net amount after fee deduction
    /// 
    /// @param gross_amount: Original amount before fees
    /// @param fee_rate: Fee rate in basis points
    /// @returns Net amount after fee deduction
    public fun calculate_net_amount(gross_amount: u64, fee_rate: u64): u64 {
        let fee_amount = calculate_fee_amount(gross_amount, fee_rate);
        gross_amount - fee_amount
    }

    /// Calculate the effective fee rate for a multi-bin swap
    /// Takes into account different fees as swap progresses through bins
    /// 
    /// @param base_factor: Base factor for fee calculation
    /// @param bin_step: Bin step size
    /// @param total_bins_crossed: Total bins crossed in the swap
    /// @returns Weighted average fee rate
    public fun calculate_effective_fee_rate(
        base_factor: u16,
        bin_step: u16,
        total_bins_crossed: u32
    ): u64 {
        if (total_bins_crossed == 0) {
            return calculate_dynamic_fee(base_factor, bin_step, 0)
        };

        // Calculate weighted average of fees as volatility increases
        let mut total_weighted_fee = 0u64;
        let mut i = 0u32;
        
        while (i <= total_bins_crossed) {
            let fee_at_volatility = calculate_dynamic_fee(base_factor, bin_step, i);
            total_weighted_fee = total_weighted_fee + fee_at_volatility;
            i = i + 1;
        };
        
        // Return average fee
        total_weighted_fee / ((total_bins_crossed + 1) as u64)
    }

    /// Get base fee without volatility component
    /// 
    /// @param base_factor: Base factor multiplier
    /// @param bin_step: Bin step in basis points
    /// @returns Base fee rate
    public fun get_base_fee(base_factor: u16, bin_step: u16): u64 {
        calculate_dynamic_fee(base_factor, bin_step, 0)
    }

    /// Calculate fee tier recommendation based on pair characteristics
    /// Different pairs may benefit from different fee structures
    /// 
    /// @param expected_volatility: Expected volatility level (0-100)
    /// @param is_stable_pair: Whether this is a stablecoin pair
    /// @returns Recommended (base_factor, bin_step)
    public fun recommend_fee_tier(
        expected_volatility: u8,
        is_stable_pair: bool
    ): (u16, u16) {
        if (is_stable_pair) {
            // Stable pairs: lower fees, smaller bin steps
            (50, 10)  // 0.5% base factor, 0.1% bin step
        } else if (expected_volatility < 30) {
            // Low volatility: standard fees
            (100, 25) // 1% base factor, 0.25% bin step
        } else if (expected_volatility < 70) {
            // Medium volatility: slightly higher fees
            (150, 50) // 1.5% base factor, 0.5% bin step  
        } else {
            // High volatility: higher fees to compensate LPs
            (200, 100) // 2% base factor, 1% bin step
        }
    }

    /// Calculate maximum possible fee for a configuration
    /// Useful for setting expectations and limits
    /// 
    /// @param base_factor: Base factor
    /// @param bin_step: Bin step
    /// @returns Maximum possible dynamic fee
    public fun calculate_max_possible_fee(
        base_factor: u16,
        bin_step: u16
    ): u64 {
        // Assume maximum volatility scenario
        let max_bins_crossed = 1000u32; // Reasonable maximum
        calculate_dynamic_fee(base_factor, bin_step, max_bins_crossed)
    }

    /// Estimate total fee for a complex swap across multiple bins
    /// 
    /// @param swap_amount: Total amount being swapped
    /// @param base_factor: Base factor
    /// @param bin_step: Bin step
    /// @param bins_to_cross: Expected bins to cross
    /// @param protocol_fee_rate: Protocol fee rate
    /// @returns (total_fee, protocol_fee, lp_fee)
    public fun estimate_swap_fees(
        swap_amount: u64,
        base_factor: u16,
        bin_step: u16,
        bins_to_cross: u32,
        protocol_fee_rate: u16
    ): (u64, u64, u64) {
        // Calculate effective fee rate
        let effective_fee_rate = calculate_effective_fee_rate(
            base_factor, bin_step, bins_to_cross
        );
        
        // Calculate total fee amount
        let total_fee = calculate_fee_amount(swap_amount, effective_fee_rate);
        
        // Split between protocol and LPs
        let protocol_fee = calculate_protocol_fee(total_fee, protocol_fee_rate);
        let lp_fee = total_fee - protocol_fee;
        
        (total_fee, protocol_fee, lp_fee)
    }

    // ==================== Volatility Accumulator Functions ====================

    /// Update volatility accumulator based on swap activity
    /// This tracks recent volatility to adjust fees dynamically
    /// 
    /// @param current_volatility: Current volatility accumulator value
    /// @param bins_crossed: Bins crossed in this swap
    /// @param time_elapsed: Time since last update (in milliseconds)
    /// @returns New volatility accumulator value
    public fun update_volatility_accumulator(
        current_volatility: u64,
        bins_crossed: u32,
        time_elapsed: u64
    ): u64 {
        // Decay existing volatility over time
        let decayed_volatility = apply_time_decay(current_volatility, time_elapsed);
        
        // Add new volatility from this swap
        let additional_volatility = (bins_crossed as u64) * VOLATILITY_SCALE;
        
        // Update accumulator with cap to prevent overflow
        let new_volatility = decayed_volatility + additional_volatility;
        
        // Cap at maximum to prevent excessive fees
        if (new_volatility > MAX_VARIABLE_FEE_MULTIPLIER * VOLATILITY_SCALE) {
            MAX_VARIABLE_FEE_MULTIPLIER * VOLATILITY_SCALE
        } else {
            new_volatility
        }
    }

    /// Apply time-based decay to volatility accumulator
    /// Volatility should decrease over time when there's no trading activity
    fun apply_time_decay(volatility: u64, time_elapsed_ms: u64): u64 {
        if (volatility == 0 || time_elapsed_ms == 0) return volatility;
        
        // Decay factor: lose 1% per second, more aggressive for longer periods
        let decay_rate = if (time_elapsed_ms > 300000) { // > 5 minutes
            90 // 10% decay
        } else if (time_elapsed_ms > 60000) { // > 1 minute
            95 // 5% decay
        } else if (time_elapsed_ms > 10000) { // > 10 seconds
            98 // 2% decay
        } else {
            99 // 1% decay
        };
        
        (volatility * (decay_rate as u64)) / 100
    }

    /// Reset volatility accumulator (for emergency or governance use)
    public fun reset_volatility_accumulator(): u64 {
        0
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    /// Test dynamic fee scaling with volatility - ENHANCED with debugging
    public fun test_dynamic_fee_scaling(): bool {
        let base_factor = 100u16;
        let bin_step = 25u16;
        
        // Calculate expected values
        let expected_base_fee = (base_factor as u64) * (bin_step as u64); // Should be 2500
        
        // Test fee progression as bins_crossed increases
        let fee_0_bins = calculate_dynamic_fee(base_factor, bin_step, 0);
        let fee_5_bins = calculate_dynamic_fee(base_factor, bin_step, 5);
        let fee_20_bins = calculate_dynamic_fee(base_factor, bin_step, 20);
        
        // DEBUG: Print values for verification
        std::debug::print(&std::string::utf8(b"=== COMPREHENSIVE FEE DEBUG ==="));
        std::debug::print(&std::string::utf8(b"Expected base fee: "));
        std::debug::print(&expected_base_fee);
        std::debug::print(&std::string::utf8(b"Actual fee 0 bins: "));
        std::debug::print(&fee_0_bins);
        std::debug::print(&std::string::utf8(b"Actual fee 5 bins: "));
        std::debug::print(&fee_5_bins);
        std::debug::print(&std::string::utf8(b"Actual fee 20 bins: "));
        std::debug::print(&fee_20_bins);
        
        // Test the base fee calculation
        if (fee_0_bins != expected_base_fee) {
            std::debug::print(&std::string::utf8(b"ERROR: Base fee mismatch"));
            return false
        };
        
        // FIXED: Fees should definitely increase with volatility now
        if (fee_5_bins <= fee_0_bins) {
            std::debug::print(&std::string::utf8(b"ERROR: fee_5_bins not > fee_0_bins"));
            return false
        };
        if (fee_20_bins <= fee_5_bins) {
            std::debug::print(&std::string::utf8(b"ERROR: fee_20_bins not > fee_5_bins"));
            return false
        };
        
        // High volatility should be significantly higher than base
        if (fee_20_bins < fee_0_bins * 2) {
            std::debug::print(&std::string::utf8(b"ERROR: fee_20_bins should be at least 2x base"));
            return false
        };
        
        std::debug::print(&std::string::utf8(b"SUCCESS: All fee scaling tests passed"));
        true
    }

    #[test_only]
    /// Test protocol fee calculation accuracy
    public fun test_protocol_fee_calculation(): bool {
        let total_fee = 10000u64; // 10k units
        let protocol_rate = 3000u16; // 30%
        
        let protocol_fee = calculate_protocol_fee(total_fee, protocol_rate);
        let lp_fee = calculate_lp_fee(total_fee, protocol_rate);
        
        // Protocol fee should be 30% = 3000 units
        if (protocol_fee != 3000) return false;
        
        // LP fee should be 70% = 7000 units
        if (lp_fee != 7000) return false;
        
        // Total should equal sum of parts
        if (protocol_fee + lp_fee != total_fee) return false;
        
        true
    }

    #[test_only]
    /// Test fee amount calculations for swaps - ENHANCED
    public fun test_swap_fee_calculations(): bool {
        let swap_amount = 1000000u64; // 1M units
        let fee_rate = 2500u64; // Raw basis points (2500 = 25% when divided by 10000)
        
        let fee_amount = calculate_fee_amount(swap_amount, fee_rate);
        let net_amount = calculate_net_amount(swap_amount, fee_rate);
        
        // Fee should be 25% = 250k units
        if (fee_amount != 250000) return false;
        
        // Net should be 75% = 750k units
        if (net_amount != 750000) return false;
        
        // Sum should equal original
        if (fee_amount + net_amount != swap_amount) return false;
        
        true
    }

    #[test_only]
    /// Test volatility accumulator behavior
    public fun test_volatility_accumulator(): bool {
        let initial_volatility = 1000u64;
        
        // Test decay over time
        let decayed = apply_time_decay(initial_volatility, 60000); // 1 minute
        if (decayed >= initial_volatility) return false; // Should decrease
        
        // Test volatility update
        let updated = update_volatility_accumulator(100, 5, 1000);
        if (updated <= 100) return false; // Should increase
        
        true
    }

    #[test_only]
    /// Test variable fee calculation directly - ENHANCED
    public fun test_variable_fee_calculation(): bool {
        let base_fee = 2500u64; // 25 basis points base fee (100 * 25)
        
        // Test with 0 bins crossed - should return 0
        let var_fee_0 = calculate_variable_fee_fixed(base_fee, 0);
        if (var_fee_0 != 0) return false;
        
        // Test with 1 bin crossed - should be non-zero
        let var_fee_1 = calculate_variable_fee_fixed(base_fee, 1);
        if (var_fee_1 == 0) return false;
        
        // Test with 5 bins crossed - should be higher
        let var_fee_5 = calculate_variable_fee_fixed(base_fee, 5);
        if (var_fee_5 <= var_fee_1) return false;
        
        // Test with 20 bins crossed - should be even higher
        let var_fee_20 = calculate_variable_fee_fixed(base_fee, 20);
        if (var_fee_20 <= var_fee_5) return false;
        
        std::debug::print(&std::string::utf8(b"Variable fees - 1 bin: "));
        std::debug::print(&var_fee_1);
        std::debug::print(&std::string::utf8(b"Variable fees - 5 bins: "));
        std::debug::print(&var_fee_5);
        std::debug::print(&std::string::utf8(b"Variable fees - 20 bins: "));
        std::debug::print(&var_fee_20);
        
        true
    }

    #[test_only]
    /// Test minimum fee guarantees - ENHANCED
    public fun test_minimum_fee_guarantees(): bool {
        // Test small swap amounts that might result in 0 fees
        let small_amount = 100u64;
        let small_fee_rate = 25u64; // Very small rate
        
        let fee_amount = calculate_fee_amount(small_amount, small_fee_rate);
        
        // Should calculate proper fee (100 * 25 / 10000 = 0.25, rounds to 0, but we guarantee minimum 1)
        if (fee_amount == 0) {
            std::debug::print(&std::string::utf8(b"ERROR: Zero fee for non-zero swap"));
            return false
        };
        
        // Test variable fee minimum guarantees
        let base_fee = 2500u64;
        let var_fee_small = calculate_variable_fee_fixed(base_fee, 1);
        
        if (var_fee_small == 0) {
            std::debug::print(&std::string::utf8(b"ERROR: Zero variable fee"));
            return false
        };
        
        true
    }
}