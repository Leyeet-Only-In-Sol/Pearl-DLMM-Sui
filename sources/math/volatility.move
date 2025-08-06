module sui_dlmm::volatility {
    // Time constants (all in milliseconds)
    const MILLISECONDS_PER_SECOND: u64 = 1000;
    
    // Volatility constants
    const VOLATILITY_SCALE: u64 = 1000;
    const MAX_VOLATILITY: u64 = 1000000; // Maximum volatility accumulator value
    const MIN_TIME_BETWEEN_UPDATES: u64 = 100; // 100ms minimum between updates
    
    // Decay parameters
    const DECAY_RATE_PER_SECOND: u64 = 999; // 0.1% decay per second (multiply by 999/1000)
    const AGGRESSIVE_DECAY_THRESHOLD: u64 = 300000; // 5 minutes
    const AGGRESSIVE_DECAY_RATE: u64 = 900; // 10% decay for long periods
    
    // Error codes
    const EINVALID_TIME: u64 = 1;

    /// Volatility accumulator structure to track market volatility
    public struct VolatilityAccumulator has store, copy, drop {
        value: u64,              // Current volatility value
        last_update_time: u64,   // Timestamp of last update (milliseconds)
        reference_bin_id: u32,   // Reference bin for volatility calculation
        total_swaps: u64,        // Total number of swaps processed
    }

    /// Create a new volatility accumulator
    public fun new_volatility_accumulator(
        initial_bin_id: u32,
        current_time_ms: u64
    ): VolatilityAccumulator {
        VolatilityAccumulator {
            value: 0,
            last_update_time: current_time_ms,
            reference_bin_id: initial_bin_id,
            total_swaps: 0,
        }
    }

    /// Update volatility accumulator based on bins crossed in a swap
    /// 
    /// @param accumulator: Current volatility accumulator
    /// @param current_bin_id: Current active bin ID
    /// @param bins_crossed: Number of bins crossed in this swap
    /// @param current_time_ms: Current timestamp in milliseconds
    /// @returns Updated volatility accumulator
    public fun update_volatility_accumulator(
        mut accumulator: VolatilityAccumulator,
        current_bin_id: u32,
        bins_crossed: u32,
        current_time_ms: u64
    ): VolatilityAccumulator {
        assert!(current_time_ms >= accumulator.last_update_time, EINVALID_TIME);
        
        let time_elapsed = current_time_ms - accumulator.last_update_time;
        
        // Skip update if too soon (prevents manipulation)
        if (time_elapsed < MIN_TIME_BETWEEN_UPDATES) {
            return accumulator
        };

        // Apply time decay to existing volatility
        accumulator.value = apply_time_decay(accumulator.value, time_elapsed);
        
        // Add new volatility from this swap
        let additional_volatility = calculate_additional_volatility(
            accumulator.reference_bin_id,
            current_bin_id,
            bins_crossed
        );
        
        // Update accumulator
        accumulator.value = accumulator.value + additional_volatility;
        accumulator.last_update_time = current_time_ms;
        accumulator.reference_bin_id = current_bin_id;
        accumulator.total_swaps = accumulator.total_swaps + 1;
        
        // Cap volatility to prevent overflow
        if (accumulator.value > MAX_VOLATILITY) {
            accumulator.value = MAX_VOLATILITY;
        };

        accumulator
    }

    /// Calculate additional volatility from a swap
    /// Takes into account both bins crossed and distance from reference
    fun calculate_additional_volatility(
        reference_bin_id: u32,
        current_bin_id: u32,
        bins_crossed: u32
    ): u64 {
        // Base volatility from bins crossed
        let base_volatility = (bins_crossed as u64) * VOLATILITY_SCALE / 10;
        
        // Additional volatility from distance from reference point
        let distance = if (current_bin_id >= reference_bin_id) {
            current_bin_id - reference_bin_id
        } else {
            reference_bin_id - current_bin_id
        };
        
        let distance_volatility = (distance as u64) * VOLATILITY_SCALE / 100;
        
        base_volatility + distance_volatility
    }

    /// Apply time-based decay to volatility
    /// Volatility should decrease over time when there's no trading activity
    public fun apply_time_decay(volatility: u64, time_elapsed_ms: u64): u64 {
        if (volatility == 0 || time_elapsed_ms == 0) return volatility;
        
        // Calculate number of decay periods
        let seconds_elapsed = time_elapsed_ms / MILLISECONDS_PER_SECOND;
        
        if (seconds_elapsed == 0) return volatility;
        
        // Choose decay rate based on time elapsed
        let decay_rate = if (time_elapsed_ms > AGGRESSIVE_DECAY_THRESHOLD) {
            AGGRESSIVE_DECAY_RATE // Aggressive decay for long periods
        } else {
            DECAY_RATE_PER_SECOND // Normal decay
        };
        
        // Apply decay exponentially over time
        apply_exponential_decay(volatility, decay_rate, seconds_elapsed)
    }

    /// Apply exponential decay: value * (rate/1000)^periods
    fun apply_exponential_decay(value: u64, decay_rate: u64, periods: u64): u64 {
        if (periods == 0) return value;
        if (value == 0) return 0;
        
        let mut result = value;
        let mut remaining_periods = periods;
        
        // Apply decay period by period to prevent overflow
        while (remaining_periods > 0 && result > 0) {
            result = (result * decay_rate) / 1000;
            remaining_periods = remaining_periods - 1;
            
            // Early exit if value becomes negligible
            if (result < 10) {
                result = 0;
                break
            };
        };
        
        result
    }

    /// Force decay volatility by a specific amount (for testing or emergency)
    public fun force_decay_volatility(
        mut accumulator: VolatilityAccumulator,
        decay_percentage: u8 // 0-100
    ): VolatilityAccumulator {
        assert!(decay_percentage <= 100, EINVALID_TIME);
        
        let decay_factor = 100 - (decay_percentage as u64);
        accumulator.value = (accumulator.value * decay_factor) / 100;
        
        accumulator
    }

    /// Reset volatility accumulator (for emergency or governance use)
    public fun reset_volatility_accumulator(
        mut accumulator: VolatilityAccumulator,
        current_time_ms: u64
    ): VolatilityAccumulator {
        accumulator.value = 0;
        accumulator.last_update_time = current_time_ms;
        accumulator
    }

    /// Get current volatility value
    public fun get_volatility_value(accumulator: &VolatilityAccumulator): u64 {
        accumulator.value
    }

    /// Get time-decayed volatility value without updating the accumulator
    public fun get_current_volatility_value(
        accumulator: &VolatilityAccumulator,
        current_time_ms: u64
    ): u64 {
        let time_elapsed = if (current_time_ms >= accumulator.last_update_time) {
            current_time_ms - accumulator.last_update_time
        } else {
            0
        };
        
        apply_time_decay(accumulator.value, time_elapsed)
    }

    /// Get last update timestamp
    public fun get_last_update_time(accumulator: &VolatilityAccumulator): u64 {
        accumulator.last_update_time
    }

    /// Get reference bin ID
    public fun get_reference_bin_id(accumulator: &VolatilityAccumulator): u32 {
        accumulator.reference_bin_id
    }

    /// Get total number of swaps processed
    public fun get_total_swaps(accumulator: &VolatilityAccumulator): u64 {
        accumulator.total_swaps
    }

    /// Check if volatility is considered high
    public fun is_high_volatility(accumulator: &VolatilityAccumulator): bool {
        accumulator.value > MAX_VOLATILITY / 4 // More than 25% of maximum
    }

    /// Check if volatility is considered very high
    public fun is_very_high_volatility(accumulator: &VolatilityAccumulator): bool {
        accumulator.value > MAX_VOLATILITY / 2 // More than 50% of maximum
    }

    /// Calculate volatility-based fee multiplier
    /// Returns a multiplier (scaled by 1000) to apply to base fees
    public fun calculate_volatility_fee_multiplier(
        accumulator: &VolatilityAccumulator
    ): u64 {
        // Base multiplier is 1000 (1x)
        let base_multiplier = 1000u64;
        
        // Additional multiplier based on volatility
        let volatility_addition = accumulator.value / 100; // 1% per 100 volatility units
        
        // Cap the total multiplier
        let total_multiplier = base_multiplier + volatility_addition;
        if (total_multiplier > 10000) { // Max 10x multiplier
            10000
        } else {
            total_multiplier
        }
    }

    /// Calculate smoothed volatility using exponential moving average
    /// Useful for less reactive fee adjustments
    public fun calculate_smoothed_volatility(
        accumulator: &VolatilityAccumulator,
        smoothing_factor: u8 // 0-100, higher = more smoothing
    ): u64 {
        assert!(smoothing_factor <= 100, EINVALID_TIME);
        
        // Simple exponential smoothing
        // If we had historical data, we'd use: new_value * α + old_smoothed * (1-α)
        // For now, we'll apply smoothing to current volatility
        let alpha = (smoothing_factor as u64);
        (accumulator.value * (100 - alpha)) / 100
    }

    /// Get volatility statistics for monitoring and analysis
    public fun get_volatility_stats(
        accumulator: &VolatilityAccumulator
    ): (u64, u64, u32, u64, bool) {
        (
            accumulator.value,              // Current volatility
            accumulator.last_update_time,   // Last update time
            accumulator.reference_bin_id,   // Reference bin
            accumulator.total_swaps,        // Total swaps
            is_high_volatility(accumulator) // Is high volatility
        )
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    /// Test volatility accumulator creation and basic operations
    public fun test_volatility_accumulator_basic(): bool {
        let current_time = 1000000u64; // 1M milliseconds
        let initial_bin = 1000u32;
        
        let accumulator = new_volatility_accumulator(initial_bin, current_time);
        
        // Initial state should be zero volatility
        if (get_volatility_value(&accumulator) != 0) return false;
        if (get_last_update_time(&accumulator) != current_time) return false;
        if (get_reference_bin_id(&accumulator) != initial_bin) return false;
        if (get_total_swaps(&accumulator) != 0) return false;
        
        true
    }

    #[test_only]
    /// Test volatility updates and decay
    public fun test_volatility_update_and_decay(): bool {
        let mut accumulator = new_volatility_accumulator(1000, 0);
        
        // Update with some volatility
        accumulator = update_volatility_accumulator(
            accumulator,
            1005, // new bin (5 bins away)
            3,    // 3 bins crossed
            1000  // 1 second later
        );
        
        let volatility_after_update = get_volatility_value(&accumulator);
        if (volatility_after_update == 0) return false; // Should have increased
        
        // Test decay over time
        let decayed_volatility = apply_time_decay(volatility_after_update, 60000); // 1 minute
        if (decayed_volatility >= volatility_after_update) return false; // Should have decreased
        
        // Test that decay approaches zero over long periods
        let long_decay = apply_time_decay(volatility_after_update, 3600000); // 1 hour
        if (long_decay > volatility_after_update / 10) return false; // Should be much smaller
        
        true
    }

    #[test_only]
    /// Test volatility fee multiplier calculation
    public fun test_volatility_fee_multiplier(): bool {
        let mut accumulator = new_volatility_accumulator(1000, 0);
        
        // Low volatility should give base multiplier
        let low_multiplier = calculate_volatility_fee_multiplier(&accumulator);
        if (low_multiplier != 1000) return false; // Should be 1x
        
        // Add significant volatility
        accumulator.value = 50000; // High volatility
        let high_multiplier = calculate_volatility_fee_multiplier(&accumulator);
        if (high_multiplier <= low_multiplier) return false; // Should be higher
        
        // Very high volatility should be capped
        accumulator.value = MAX_VOLATILITY;
        let max_multiplier = calculate_volatility_fee_multiplier(&accumulator);
        if (max_multiplier > 10000) return false; // Should be capped at 10x
        
        true
    }

    #[test_only]
    /// Test exponential decay function
    public fun test_exponential_decay(): bool {
        let initial_value = 10000u64;
        let decay_rate = 900u64; // 90% retention (10% decay)
        
        // One period of decay
        let after_one_period = apply_exponential_decay(initial_value, decay_rate, 1);
        if (after_one_period != 9000) return false; // Should be 90% of original
        
        // Multiple periods should compound
        let after_two_periods = apply_exponential_decay(initial_value, decay_rate, 2);
        if (after_two_periods >= after_one_period) return false; // Should be smaller
        
        // Large number of periods should approach zero
        let after_many_periods = apply_exponential_decay(initial_value, decay_rate, 100);
        if (after_many_periods > 100) return false; // Should be very small
        
        true
    }

    #[test_only]
    /// Test high volatility detection
    public fun test_high_volatility_detection(): bool {
        let mut accumulator = new_volatility_accumulator(1000, 0);
        
        // Initially should not be high volatility
        if (is_high_volatility(&accumulator)) return false;
        if (is_very_high_volatility(&accumulator)) return false;
        
        // Set to high volatility threshold
        accumulator.value = MAX_VOLATILITY / 3; // 33% of max
        if (!is_high_volatility(&accumulator)) return false;
        if (is_very_high_volatility(&accumulator)) return false;
        
        // Set to very high volatility
        accumulator.value = MAX_VOLATILITY * 2 / 3; // 67% of max
        if (!is_high_volatility(&accumulator)) return false;
        if (!is_very_high_volatility(&accumulator)) return false;
        
        true
    }

    #[test_only] 
    /// Test volatility stats extraction
    public fun test_volatility_stats(): bool {
        let accumulator = new_volatility_accumulator(1500, 123456);
        let (value, time, bin_id, swaps, is_high) = get_volatility_stats(&accumulator);
        
        if (value != 0) return false;
        if (time != 123456) return false;
        if (bin_id != 1500) return false;
        if (swaps != 0) return false;
        if (is_high) return false;
        
        true
    }
}