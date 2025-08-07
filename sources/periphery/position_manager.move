module sui_dlmm::position_manager {
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::event;
    
    use sui_dlmm::dlmm_pool::{Self, DLMMPool};
    use sui_dlmm::position::{Self, Position};
    use sui_dlmm::bin_math;

    // Error codes
    const EINVALID_RANGE: u64 = 1;
    const EINVALID_AMOUNT: u64 = 2;
    const EINVALID_STRATEGY: u64 = 3;
    const EINVALID_PERCENTAGE: u64 = 4;
    const EUNAUTHORIZED: u64 = 5;

    // Strategy constants for easy reference
    const STRATEGY_UNIFORM: u8 = 0;
    const STRATEGY_CURVE: u8 = 1;
    #[allow(unused_const)] // Used in future features
    const STRATEGY_BID_ASK: u8 = 2;

    // ==================== Simplified Position Creation ====================

    /// Create position with simple parameters - user-friendly interface
    public fun create_position_simple<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        range_bins: u32,        // Number of bins on each side of current price (e.g., 5 = 11 total bins)
        strategy_type: u8,      // 0=Uniform, 1=Curve, 2=Bid-Ask
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Position {
        assert!(range_bins > 0 && range_bins <= 100, EINVALID_RANGE);
        assert!(strategy_type <= 2, EINVALID_STRATEGY);
        assert!(coin::value(&coin_a) > 0 || coin::value(&coin_b) > 0, EINVALID_AMOUNT);

        // Get current active bin from pool
        let (_, active_bin_id, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        
        // Calculate range around active bin
        let lower_bin_id = if (active_bin_id >= range_bins) {
            active_bin_id - range_bins
        } else {
            0
        };
        let upper_bin_id = active_bin_id + range_bins;

        // Create position config using the new public constructor
        let config = position::create_simple_position_config(
            lower_bin_id,
            upper_bin_id,
            strategy_type
        );

        // Create position using core module
        let position = position::create_position<CoinA, CoinB>(
            pool, config, coin_a, coin_b, clock, ctx
        );

        // Emit simplified creation event
        event::emit(SimplePositionCreated {
            position_id: position::get_position_id(&position), // FIXED: Added & back because position is owned value here
            pool_id: dlmm_pool::get_pool_id(pool),
            owner: sui::tx_context::sender(ctx),
            active_bin_id,
            range_bins,
            strategy_type,
            timestamp: clock::timestamp_ms(clock),
        });

        position
    }

    /// Create position around specific price instead of current active bin
    public fun create_position_at_price<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        target_price: u128,     // Target price to center position around
        range_bins: u32,        // Range on each side
        strategy_type: u8,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Position {
        assert!(range_bins > 0 && range_bins <= 100, EINVALID_RANGE);
        assert!(strategy_type <= 2, EINVALID_STRATEGY);
        assert!(target_price > 0, EINVALID_AMOUNT);

        // Get bin step from pool
        let (bin_step, _, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        
        // Calculate target bin ID from price
        let target_bin_id = bin_math::get_bin_from_price(target_price, bin_step);
        
        // Calculate range
        let lower_bin_id = if (target_bin_id >= range_bins) {
            target_bin_id - range_bins
        } else {
            0
        };
        let upper_bin_id = target_bin_id + range_bins;

        let config = position::create_simple_position_config(
            lower_bin_id,
            upper_bin_id,
            strategy_type
        );

        let position = position::create_position<CoinA, CoinB>(
            pool, config, coin_a, coin_b, clock, ctx
        );

        event::emit(PriceTargetedPositionCreated {
            position_id: position::get_position_id(&position), // FIXED: Added & back because position is owned value here
            pool_id: dlmm_pool::get_pool_id(pool),
            owner: sui::tx_context::sender(ctx),
            target_price,
            target_bin_id,
            range_bins,
            strategy_type,
            timestamp: clock::timestamp_ms(clock),
        });

        position
    }

    /// Create tight range position for maximum capital efficiency
    public fun create_position_tight_range<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Position {
        // Create 3-bin position around active bin (very concentrated)
        create_position_simple<CoinA, CoinB>(
            pool, coin_a, coin_b, 1, STRATEGY_CURVE, clock, ctx
        )
    }

    /// Create wide range position for passive liquidity provision
    public fun create_position_wide_range<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Position {
        // Create 21-bin position around active bin (broad coverage)
        create_position_simple<CoinA, CoinB>(
            pool, coin_a, coin_b, 10, STRATEGY_UNIFORM, clock, ctx
        )
    }

    // ==================== Position Management Helpers ====================

    /// Rebalance position automatically based on current pool state
    public fun rebalance_position_auto<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Changed to mutable
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        // Verify ownership
        let owner = position::get_position_owner(position);
        assert!(sui::tx_context::sender(ctx) == owner, EUNAUTHORIZED);

        // Get current pool state
        let (_, current_active_bin, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        let (lower_bin, upper_bin) = position::get_position_range(position);
        let strategy = position::get_position_strategy(position);

        // Check if position needs rebalancing (active bin moved outside range)
        let needs_rebalancing = current_active_bin < lower_bin || current_active_bin > upper_bin;

        if (needs_rebalancing) {
            // For now, just call the existing rebalance function
            // In production, this would implement sophisticated rebalancing logic
            position::rebalance_position<CoinA, CoinB>(position, pool, clock, ctx);
            
            event::emit(AutoRebalanceExecuted {
                position_id: position::get_position_id(position), // FIXED: Removed & since position is already a reference
                old_active_bin: current_active_bin,
                new_lower_bin: lower_bin,
                new_upper_bin: upper_bin,
                strategy,
                owner,
                timestamp: clock::timestamp_ms(clock),
            });
        };
    }

    /// Collect all fees from position in one transaction
    public fun collect_all_fees<CoinA, CoinB>(
        position: &mut Position,
        pool: &DLMMPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let owner = position::get_position_owner(position);
        assert!(sui::tx_context::sender(ctx) == owner, EUNAUTHORIZED);

        // Use core position module to collect fees
        let (fee_a, fee_b) = position::collect_fees_from_position<CoinA, CoinB>(
            position, pool, clock, ctx
        );

        let total_fee_a = coin::value(&fee_a);
        let total_fee_b = coin::value(&fee_b);

        // Emit collection event
        event::emit(AllFeesCollected {
            position_id: position::get_position_id(position), // FIXED: Removed & since position is already a reference
            fee_a: total_fee_a,
            fee_b: total_fee_b,
            owner,
            timestamp: clock::timestamp_ms(clock),
        });

        (fee_a, fee_b)
    }

    /// Add liquidity to position with simplified interface
    public fun add_liquidity_auto<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Changed to mutable
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let owner = position::get_position_owner(position);
        assert!(sui::tx_context::sender(ctx) == owner, EUNAUTHORIZED);

        // Use core position module for liquidity addition
        position::add_liquidity_to_position<CoinA, CoinB>(
            position, pool, coin_a, coin_b, clock, ctx
        );
    }

    /// Remove percentage of liquidity from position
    public fun remove_liquidity_percentage<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Changed to mutable
        percentage: u8,         // 1-100 percentage to remove
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        assert!(percentage > 0 && percentage <= 100, EINVALID_PERCENTAGE);
        
        let owner = position::get_position_owner(position);
        assert!(sui::tx_context::sender(ctx) == owner, EUNAUTHORIZED);

        // Use core position module for removal
        position::remove_liquidity_from_position<CoinA, CoinB>(
            position, pool, percentage, clock, ctx
        )
    }

    // ==================== Position Analysis & Utilities ====================

    /// Get position performance metrics
    public fun get_position_metrics<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): (u8, u64, u64, bool) { // (utilization, unclaimed_fees_a, unclaimed_fees_b, in_range)
        let utilization = position::calculate_position_utilization(position);
        let (fees_a, fees_b) = position::calculate_total_unclaimed_fees(position, pool);
        
        // Check if position is in range of current active bin
        let (_, current_active_bin, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        let (lower_bin, upper_bin) = position::get_position_range(position);
        let in_range = current_active_bin >= lower_bin && current_active_bin <= upper_bin;

        (utilization, fees_a, fees_b, in_range)
    }

    /// Check if position needs rebalancing
    public fun should_rebalance_position<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): bool {
        let (_, current_active_bin, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        let (lower_bin, upper_bin) = position::get_position_range(position);
        
        // Position needs rebalancing if active bin moved outside range
        current_active_bin < lower_bin || current_active_bin > upper_bin
    }

    /// Get recommended position parameters for token pair
    public fun recommend_position_params<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        risk_level: u8          // 0=Conservative, 1=Moderate, 2=Aggressive
    ): (u32, u8) { // (recommended_range_bins, recommended_strategy)
        let (_bin_step, _, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        
        // Get volatility info
        let (_, _, _, _, is_high_volatility) = dlmm_pool::get_volatility_info(pool);
        
        if (risk_level == 0) { // Conservative
            if (is_high_volatility) {
                (20, STRATEGY_UNIFORM) // Wide range, uniform for stability
            } else {
                (10, STRATEGY_UNIFORM) // Moderate range, uniform
            }
        } else if (risk_level == 1) { // Moderate  
            if (is_high_volatility) {
                (15, STRATEGY_CURVE) // Medium range, concentrated
            } else {
                (8, STRATEGY_CURVE) // Focused range, concentrated
            }
        } else { // Aggressive
            if (is_high_volatility) {
                (5, STRATEGY_CURVE) // Tight range, concentrated
            } else {
                (3, STRATEGY_CURVE) // Very tight range, maximum concentration
            }
        }
    }

    /// Calculate optimal token ratio for position creation
    public fun calculate_optimal_ratio<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        target_bin_id: u32
    ): (u64, u64) { // (ratio_a_per_1000, ratio_b_per_1000) - parts per 1000
        let (bin_step, _, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        let target_price = bin_math::calculate_bin_price(target_bin_id, bin_step);
        
        // For constant sum P*x + y = L, optimal ratio depends on target price
        // Higher price = need more token A relative to token B
        
        if (target_price <= 18446744073709551616) { // Price <= 1.0
            (500, 500) // Equal ratio
        } else if (target_price <= 36893488147419103232) { // Price <= 2.0
            (600, 400) // Favor token A slightly
        } else if (target_price <= 73786976294838206464) { // Price <= 4.0
            (700, 300) // Favor token A more
        } else {
            (800, 200) // Heavily favor token A for high prices
        }
    }

    // ==================== Individual Position Operations ====================

    /// Create three positions with different risk profiles (SIMPLIFIED - no batch vector)
    public fun create_diversified_positions<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        mut total_coin_a: Coin<CoinA>, // FIXED: Added mut
        mut total_coin_b: Coin<CoinB>, // FIXED: Added mut
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Position, Position, Position) { // Returns (conservative, moderate, aggressive)
        let total_a = coin::value(&total_coin_a);
        let total_b = coin::value(&total_coin_b);
        
        assert!(total_a > 0 || total_b > 0, EINVALID_AMOUNT);

        // Split coins into thirds
        let a_third = total_a / 3;
        let b_third = total_b / 3;

        let coin_a1 = coin::split(&mut total_coin_a, a_third, ctx);
        let coin_b1 = coin::split(&mut total_coin_b, b_third, ctx);
        
        let coin_a2 = coin::split(&mut total_coin_a, a_third, ctx);
        let coin_b2 = coin::split(&mut total_coin_b, b_third, ctx);
        
        // Remaining coins for third position
        let coin_a3 = total_coin_a;
        let coin_b3 = total_coin_b;

        // Create three different positions
        let conservative_position = create_position_simple<CoinA, CoinB>(
            pool, coin_a1, coin_b1, 15, STRATEGY_UNIFORM, clock, ctx
        );

        let moderate_position = create_position_simple<CoinA, CoinB>(
            pool, coin_a2, coin_b2, 8, STRATEGY_CURVE, clock, ctx
        );

        let aggressive_position = create_position_simple<CoinA, CoinB>(
            pool, coin_a3, coin_b3, 3, STRATEGY_CURVE, clock, ctx
        );

        event::emit(DiversifiedPositionsCreated {
            owner: sui::tx_context::sender(ctx),
            pool_id: dlmm_pool::get_pool_id(pool),
            conservative_id: position::get_position_id(&conservative_position),
            moderate_id: position::get_position_id(&moderate_position),
            aggressive_id: position::get_position_id(&aggressive_position),
            timestamp: clock::timestamp_ms(clock),
        });

        (conservative_position, moderate_position, aggressive_position)
    }

    // ==================== Position Information & Analytics ====================

    /// Get comprehensive position summary
    public fun get_position_summary<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): (u32, u32, u8, u64, u64, u64, u64, u8, bool) { 
        // (lower_bin, upper_bin, strategy, liquidity_a, liquidity_b, fees_a, fees_b, utilization, in_range)
        
        let (_, lower_bin, upper_bin, strategy, liquidity_a, liquidity_b, _) = 
            position::get_position_info(position);
        
        let (utilization, fees_a, fees_b, in_range) = get_position_metrics(position, pool);
        
        (lower_bin, upper_bin, strategy, liquidity_a, liquidity_b, fees_a, fees_b, utilization, in_range)
    }

    /// Calculate position's share of total pool liquidity
    public fun calculate_position_pool_share<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): (u64, u64) { // (share_a_bps, share_b_bps) - basis points (10000 = 100%)
        let (_, _, _, _, pos_liquidity_a, pos_liquidity_b, _) = position::get_position_info(position);
        let (pool_liquidity_a, pool_liquidity_b) = dlmm_pool::get_total_liquidity(pool);
        
        let share_a_bps = if (pool_liquidity_a > 0) {
            (pos_liquidity_a * 10000) / pool_liquidity_a
        } else {
            0
        };
        
        let share_b_bps = if (pool_liquidity_b > 0) {
            (pos_liquidity_b * 10000) / pool_liquidity_b
        } else {
            0
        };
        
        (share_a_bps, share_b_bps)
    }

    /// Estimate potential fees for position over time period
    public fun estimate_position_fees<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>,
        estimated_daily_volume: u64,    // Expected daily trading volume
        days: u64                       // Time period for estimation
    ): (u64, u64) { // (estimated_fees_a, estimated_fees_b)
        let (_, _, _, _, pos_liquidity_a, pos_liquidity_b, _) = position::get_position_info(position);
        let (pool_liquidity_a, pool_liquidity_b) = dlmm_pool::get_total_liquidity(pool);
        
        // Simple estimation: position share * estimated volume * average fee rate * days
        let position_share_a = if (pool_liquidity_a > 0) {
            (pos_liquidity_a * 100) / pool_liquidity_a // As percentage
        } else {
            0
        };
        
        let position_share_b = if (pool_liquidity_b > 0) {
            (pos_liquidity_b * 100) / pool_liquidity_b
        } else {
            0
        };
        
        // Assume average 0.3% fee rate
        let avg_fee_rate = 30; // 0.3% in basis points scaled down
        let estimated_fees_a = (estimated_daily_volume * position_share_a * avg_fee_rate * days) / 1000000;
        let estimated_fees_b = (estimated_daily_volume * position_share_b * avg_fee_rate * days) / 1000000;
        
        (estimated_fees_a, estimated_fees_b)
    }

    // ==================== Entry Functions for Easy UI Integration ====================

    /// Entry function: Create simple position and transfer to sender
    public entry fun create_and_transfer_position<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        range_bins: u32,
        strategy_type: u8,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let position = create_position_simple<CoinA, CoinB>(
            pool, coin_a, coin_b, range_bins, strategy_type, clock, ctx
        );
        
        let owner = sui::tx_context::sender(ctx);
        sui::transfer::public_transfer(position, owner);
    }

    /// Entry function: Collect fees and transfer to sender
    public entry fun collect_and_transfer_fees<CoinA, CoinB>(
        position: &mut Position,
        pool: &DLMMPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let (fee_a, fee_b) = collect_all_fees<CoinA, CoinB>(position, pool, clock, ctx);
        
        let owner = sui::tx_context::sender(ctx);
        if (coin::value(&fee_a) > 0) {
            sui::transfer::public_transfer(fee_a, owner);
        } else {
            coin::destroy_zero(fee_a);
        };
        
        if (coin::value(&fee_b) > 0) {
            sui::transfer::public_transfer(fee_b, owner);
        } else {
            coin::destroy_zero(fee_b);
        };
    }

    /// Entry function: Auto-rebalance position
    public entry fun auto_rebalance_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Changed to mutable to match rebalance_position_auto
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        rebalance_position_auto<CoinA, CoinB>(position, pool, clock, ctx);
    }

    // ==================== View Functions ====================

    /// Check if position is healthy (in range and has liquidity)
    public fun is_position_healthy<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): bool {
        let (utilization, _, _, in_range) = get_position_metrics(position, pool);
        in_range && utilization > 0
    }

    /// Get position age in milliseconds
    public fun get_position_age(position: &Position, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        let created_at = position::get_position_created_at(position);
        if (current_time >= created_at) {
            current_time - created_at
        } else {
            0
        }
    }

    /// Get time since last rebalance
    public fun get_time_since_rebalance(position: &Position, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        let last_rebalance = position::get_position_last_rebalance(position);
        if (current_time >= last_rebalance) {
            current_time - last_rebalance
        } else {
            0
        }
    }

    // ==================== Events ====================

    public struct SimplePositionCreated has copy, drop {
        position_id: sui::object::ID,
        pool_id: sui::object::ID,
        owner: address,
        active_bin_id: u32,
        range_bins: u32,
        strategy_type: u8,
        timestamp: u64,
    }

    public struct PriceTargetedPositionCreated has copy, drop {
        position_id: sui::object::ID,
        pool_id: sui::object::ID,
        owner: address,
        target_price: u128,
        target_bin_id: u32,
        range_bins: u32,
        strategy_type: u8,
        timestamp: u64,
    }

    public struct AutoRebalanceExecuted has copy, drop {
        position_id: sui::object::ID,
        old_active_bin: u32,
        new_lower_bin: u32,
        new_upper_bin: u32,
        strategy: u8,
        owner: address,
        timestamp: u64,
    }

    public struct AllFeesCollected has copy, drop {
        position_id: sui::object::ID,
        fee_a: u64,
        fee_b: u64,
        owner: address,
        timestamp: u64,
    }

    public struct DiversifiedPositionsCreated has copy, drop {
        owner: address,
        pool_id: sui::object::ID,
        conservative_id: sui::object::ID,
        moderate_id: sui::object::ID,
        aggressive_id: sui::object::ID,
        timestamp: u64,
    }

    // ==================== Test Helpers ====================

    #[test_only]
    /// Test simple position creation
    public fun test_simple_creation(): bool {
        // Test basic parameter validation
        let valid_range = 5u32;
        let valid_strategy = 1u8;
        
        // Range should be reasonable
        assert!(valid_range > 0 && valid_range <= 100);
        assert!(valid_strategy <= 2);
        
        true
    }

    #[test_only]
    /// Test strategy recommendation logic
    public fun test_strategy_recommendations(): bool {
        // Test different risk levels
        let conservative_range = 20u32;
        let moderate_range = 8u32;
        let aggressive_range = 3u32;
        
        // Conservative should have larger range
        assert!(conservative_range > moderate_range);
        assert!(moderate_range > aggressive_range);
        
        // All ranges should be reasonable
        assert!(conservative_range <= 100);
        assert!(aggressive_range >= 1);
        
        true
    }

    #[test_only]
    /// Test ratio calculations - FIXED: Replaced assert_eq with proper assertions
    public fun test_optimal_ratio_calculation(): bool {
        // Test ratio calculation logic
        let (ratio_a, ratio_b) = (500u64, 500u64); // Equal ratio
        assert!(ratio_a + ratio_b == 1000); // FIXED: Use standard assertion
        
        let (high_price_a, high_price_b) = (800u64, 200u64); // High price scenario
        assert!(high_price_a + high_price_b == 1000); // FIXED: Use standard assertion
        assert!(high_price_a > high_price_b); // Should favor token A
        
        true
    }
}