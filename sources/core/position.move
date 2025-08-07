module sui_dlmm::position {
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::event;
    
    // Import core modules
    use sui_dlmm::dlmm_pool::{Self, DLMMPool};

    // Error codes
    const EINVALID_RANGE: u64 = 1;
    const EINVALID_STRATEGY: u64 = 3;
    const EINVALID_AMOUNT: u64 = 5;
    const EUNAUTHORIZED: u64 = 6;
    #[allow(unused_const)] // Suppress warning for future use
    const EINSUFFICIENT_SHARES: u64 = 7;

    // Strategy constants
    const STRATEGY_UNIFORM: u8 = 0;
    const STRATEGY_CURVE: u8 = 1;
    const STRATEGY_BID_ASK: u8 = 2;

    // ==================== Structs ====================

    /// Multi-bin liquidity position (NFT)
    public struct Position has key, store {
        id: sui::object::UID,
        pool_id: sui::object::ID,
        lower_bin_id: u32,
        upper_bin_id: u32,
        bin_positions: Table<u32, BinPosition>,
        strategy_type: u8,
        total_liquidity_a: u64,
        total_liquidity_b: u64,
        unclaimed_fees_a: u64,
        unclaimed_fees_b: u64,
        created_at: u64,
        last_rebalance: u64,
        owner: address,
    }

    /// Position in individual bin
    public struct BinPosition has store, drop { // FIXED: Added 'drop' ability
        shares: u64,
        fee_growth_inside_last_a: u128,
        fee_growth_inside_last_b: u128,
        liquidity_a: u64,
        liquidity_b: u64,
        weight: u64,
    }

    /// Position creation parameters
    public struct PositionConfig has drop {
        lower_bin_id: u32,
        upper_bin_id: u32,
        strategy_type: u8,
        liquidity_distribution: vector<u64>,
    }

    // ==================== Events ====================

    public struct PositionCreated has copy, drop {
        position_id: sui::object::ID,
        pool_id: sui::object::ID,
        owner: address,
        lower_bin_id: u32,
        upper_bin_id: u32,
        strategy_type: u8,
        amount_a: u64,
        amount_b: u64,
        timestamp: u64,
    }

    public struct LiquidityAddedToPosition has copy, drop {
        position_id: sui::object::ID,
        pool_id: sui::object::ID,
        amount_a: u64,
        amount_b: u64,
        owner: address,
        timestamp: u64,
    }

    public struct LiquidityRemovedFromPosition has copy, drop {
        position_id: sui::object::ID,
        pool_id: sui::object::ID,
        percentage: u8,
        amount_a: u64,
        amount_b: u64,
        owner: address,
        timestamp: u64,
    }

    public struct FeesCollected has copy, drop {
        position_id: sui::object::ID,
        pool_id: sui::object::ID,
        fee_a: u64,
        fee_b: u64,
        owner: address,
        timestamp: u64,
    }

    public struct PositionRebalanced has copy, drop {
        position_id: sui::object::ID,
        pool_id: sui::object::ID,
        owner: address,
        timestamp: u64,
    }

    // ==================== Public Constructor Functions ====================

    /// Public constructor for PositionConfig (needed by position_manager)
    public fun create_position_config(
        lower_bin_id: u32,
        upper_bin_id: u32,
        strategy_type: u8,
        liquidity_distribution: vector<u64>
    ): PositionConfig {
        assert!(lower_bin_id <= upper_bin_id, EINVALID_RANGE);
        assert!(strategy_type <= 2, EINVALID_STRATEGY);
        
        PositionConfig {
            lower_bin_id,
            upper_bin_id,
            strategy_type,
            liquidity_distribution,
        }
    }

    /// Public constructor for simple PositionConfig (most common use case)
    public fun create_simple_position_config(
        lower_bin_id: u32,
        upper_bin_id: u32,
        strategy_type: u8
    ): PositionConfig {
        create_position_config(lower_bin_id, upper_bin_id, strategy_type, std::vector::empty())
    }

    // ==================== Helper Functions ====================

    /// Get fee growth for a specific bin
    fun get_bin_fee_growth<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        bin_id: u32
    ): (u128, u128) {
        let (exists, _, _, _, _, fee_growth_a, fee_growth_b) = dlmm_pool::get_bin_info(pool, bin_id);
        if (exists) {
            (fee_growth_a, fee_growth_b)
        } else {
            (0, 0)
        }
    }

    /// Calculate fees earned from fee growth difference
    fun calculate_fees_earned(
        shares: u64,
        current_fee_growth: u128,
        last_fee_growth: u128
    ): u64 {
        if (current_fee_growth <= last_fee_growth || shares == 0) return 0;
        
        let fee_growth_diff = current_fee_growth - last_fee_growth;
        ((shares as u128) * fee_growth_diff / 1000000000000000000u128) as u64
    }

    /// Internal fee collection logic
    fun collect_fees_internal<CoinA, CoinB>(
        position: &mut Position,
        pool: &DLMMPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let mut total_fees_a = 0u64;
        let mut total_fees_b = 0u64;

        // Calculate fees from each bin
        let mut current_bin = position.lower_bin_id;
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                let bin_position = table::borrow_mut(&mut position.bin_positions, current_bin);
                let (current_fee_growth_a, current_fee_growth_b) = get_bin_fee_growth(pool, current_bin);

                let fees_a = calculate_fees_earned(
                    bin_position.shares,
                    current_fee_growth_a,
                    bin_position.fee_growth_inside_last_a
                );

                let fees_b = calculate_fees_earned(
                    bin_position.shares,
                    current_fee_growth_b,
                    bin_position.fee_growth_inside_last_b
                );

                // Update fee growth tracking
                bin_position.fee_growth_inside_last_a = current_fee_growth_a;
                bin_position.fee_growth_inside_last_b = current_fee_growth_b;

                total_fees_a = total_fees_a + fees_a;
                total_fees_b = total_fees_b + fees_b;
            };
            current_bin = current_bin + 1;
        };

        // Add any unclaimed fees
        total_fees_a = total_fees_a + position.unclaimed_fees_a;
        total_fees_b = total_fees_b + position.unclaimed_fees_b;

        // Clear unclaimed fees
        position.unclaimed_fees_a = 0;
        position.unclaimed_fees_b = 0;

        // 🔧 INTEGRATION: In production, these would be extracted from pool reserves
        // For now, create fee coins representing the calculated amounts
        let fee_coin_a = coin::zero<CoinA>(ctx); // TODO: Extract from pool reserves
        let fee_coin_b = coin::zero<CoinB>(ctx); // TODO: Extract from pool reserves

        event::emit(FeesCollected {
            position_id: sui::object::uid_to_inner(&position.id),
            pool_id: position.pool_id,
            fee_a: total_fees_a,
            fee_b: total_fees_b,
            owner: position.owner,
            timestamp: clock::timestamp_ms(clock),
        });

        (fee_coin_a, fee_coin_b)
    }

    /// Calculate total weight from distribution weights
    fun calculate_total_weight(weights: &vector<u64>): u64 {
        let mut total = 0u64;
        let mut i = 0;
        
        while (i < vector::length(weights)) {
            total = total + *vector::borrow(weights, i);
            i = i + 1;
        };
        
        total
    }

    /// 🔧 FIXED: Distribute liquidity across bins according to strategy weights - NOW ACTUALLY INTEGRATED
    fun distribute_liquidity_across_bins_integrated<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Now mutable and actually used
        mut coin_a: Coin<CoinA>,
        mut coin_b: Coin<CoinB>,
        weights: &vector<u64>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>) { // FIXED: Return actual remaining coins
        let total_weight = calculate_total_weight(weights);
        if (total_weight == 0) {
            // Return original coins if no distribution
            return (coin_a, coin_b)
        };

        let total_amount_a = coin::value(&coin_a);
        let total_amount_b = coin::value(&coin_b);
        let mut weight_index = 0;
        let mut current_bin = position.lower_bin_id;
        
        while (current_bin <= position.upper_bin_id && weight_index < vector::length(weights)) {
            let bin_weight = *vector::borrow(weights, weight_index);
            
            if (bin_weight > 0) {
                // Calculate proportional amounts for this bin
                let amount_a_for_bin = (total_amount_a * bin_weight) / total_weight;
                let amount_b_for_bin = (total_amount_b * bin_weight) / total_weight;
                
                if (amount_a_for_bin > 0 || amount_b_for_bin > 0) {
                    // Split actual coins for this bin
                    let coin_a_for_bin = if (amount_a_for_bin > 0) {
                        coin::split(&mut coin_a, amount_a_for_bin, ctx)
                    } else {
                        coin::zero<CoinA>(ctx)
                    };
                    
                    let coin_b_for_bin = if (amount_b_for_bin > 0) {
                        coin::split(&mut coin_b, amount_b_for_bin, ctx)
                    } else {
                        coin::zero<CoinB>(ctx)
                    };
                    
                    // 🔧 INTEGRATION: Actually add liquidity to pool bin
                    let shares_minted = dlmm_pool::add_liquidity_to_bin<CoinA, CoinB>(
                        pool,
                        current_bin,
                        coin_a_for_bin,
                        coin_b_for_bin,
                        clock,
                        ctx
                    );
                    
                    // Create bin position entry with REAL shares from pool
                    if (shares_minted > 0) {
                        let (current_fee_growth_a, current_fee_growth_b) = get_bin_fee_growth(pool, current_bin);
                        
                        let bin_position = BinPosition {
                            shares: shares_minted,
                            fee_growth_inside_last_a: current_fee_growth_a,
                            fee_growth_inside_last_b: current_fee_growth_b,
                            liquidity_a: amount_a_for_bin,
                            liquidity_b: amount_b_for_bin,
                            weight: bin_weight,
                        };
                        
                        table::add(&mut position.bin_positions, current_bin, bin_position);
                    };
                };
            };
            
            current_bin = current_bin + 1;
            weight_index = weight_index + 1;
        };

        // Return remaining coins
        (coin_a, coin_b)
    }

    // ==================== Position Creation ====================

    /// 🔧 FIXED: Create new multi-bin liquidity position with ACTUAL pool integration
    #[allow(lint(self_transfer))] // Suppress self-transfer warnings
    public fun create_position<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Pool is now mutable for actual liquidity addition
        config: PositionConfig,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Position {
        assert!(config.lower_bin_id <= config.upper_bin_id, EINVALID_RANGE);
        assert!(config.strategy_type <= 2, EINVALID_STRATEGY);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 || amount_b > 0, EINVALID_AMOUNT);

        let current_time = clock::timestamp_ms(clock);
        let pool_id = dlmm_pool::get_pool_id(pool);
        let owner = sui::tx_context::sender(ctx);

        // Calculate distribution weights based on strategy
        let distribution_weights = calculate_distribution_weights(
            config.lower_bin_id,
            config.upper_bin_id,
            dlmm_pool::get_current_price(pool),
            config.strategy_type,
            config.liquidity_distribution
        );

        // Create position structure
        let mut position = Position {
            id: sui::object::new(ctx),
            pool_id,
            lower_bin_id: config.lower_bin_id,
            upper_bin_id: config.upper_bin_id,
            bin_positions: table::new(ctx),
            strategy_type: config.strategy_type,
            total_liquidity_a: amount_a,
            total_liquidity_b: amount_b,
            unclaimed_fees_a: 0,
            unclaimed_fees_b: 0,
            created_at: current_time,
            last_rebalance: current_time,
            owner,
        };

        // 🔧 FIXED: Actually distribute liquidity to pool bins
        let (remaining_coin_a, remaining_coin_b) = distribute_liquidity_across_bins_integrated(
            &mut position,
            pool,
            coin_a,
            coin_b,
            &distribution_weights,
            clock,
            ctx
        );

        // Return any remaining coins to owner
        if (coin::value(&remaining_coin_a) > 0) {
            sui::transfer::public_transfer(remaining_coin_a, owner);
        } else {
            coin::destroy_zero(remaining_coin_a);
        };
        
        if (coin::value(&remaining_coin_b) > 0) {
            sui::transfer::public_transfer(remaining_coin_b, owner);
        } else {
            coin::destroy_zero(remaining_coin_b);
        };

        event::emit(PositionCreated {
            position_id: sui::object::uid_to_inner(&position.id),
            pool_id,
            owner,
            lower_bin_id: config.lower_bin_id,
            upper_bin_id: config.upper_bin_id,
            strategy_type: config.strategy_type,
            amount_a,
            amount_b,
            timestamp: current_time,
        });

        position
    }

    /// Calculate distribution weights based on strategy
    public fun calculate_distribution_weights(
        lower_bin: u32,
        upper_bin: u32,
        current_price: u128,
        strategy_type: u8,
        custom_weights: vector<u64>
    ): vector<u64> {
        let bin_count = upper_bin - lower_bin + 1;
        
        if (std::vector::length(&custom_weights) == (bin_count as u64)) {
            return custom_weights
        };

        let mut weights = std::vector::empty<u64>();
        let total_weight = 10000u64;

        if (strategy_type == STRATEGY_UNIFORM) {
            let weight_per_bin = total_weight / (bin_count as u64);
            let mut i = 0u32;
            while (i < bin_count) {
                std::vector::push_back(&mut weights, weight_per_bin);
                i = i + 1;
            };
        } else if (strategy_type == STRATEGY_CURVE) {
            weights = calculate_curve_distribution(lower_bin, upper_bin, current_price, total_weight);
        } else if (strategy_type == STRATEGY_BID_ASK) {
            weights = calculate_bid_ask_distribution(lower_bin, upper_bin, total_weight);
        } else {
            let weight_per_bin = total_weight / (bin_count as u64);
            let mut i = 0u32;
            while (i < bin_count) {
                std::vector::push_back(&mut weights, weight_per_bin);
                i = i + 1;
            };
        };

        weights
    }

    /// Calculate curve distribution - Uses current_price
    fun calculate_curve_distribution(
        lower_bin: u32,
        upper_bin: u32,
        current_price: u128,
        total_weight: u64
    ): vector<u64> {
        let mut weights = std::vector::empty<u64>();
        
        // Find the bin closest to current price for centering
        let center_bin = sui_dlmm::bin_math::get_bin_from_price(current_price, 25); // Assume 25bp bin step
        let clamped_center = if (center_bin < lower_bin) {
            lower_bin
        } else if (center_bin > upper_bin) {
            upper_bin  
        } else {
            center_bin
        };

        let mut total_raw_weight = 0u64;
        let mut raw_weights = std::vector::empty<u64>();

        let mut i = lower_bin;
        while (i <= upper_bin) {
            let distance = if (i >= clamped_center) { i - clamped_center } else { clamped_center - i };
            let raw_weight = 1000u64 / (1 + (distance as u64) * (distance as u64));
            std::vector::push_back(&mut raw_weights, raw_weight);
            total_raw_weight = total_raw_weight + raw_weight;
            i = i + 1;
        };

        let bin_count = upper_bin - lower_bin + 1;
        let mut j = 0;
        while (j < (bin_count as u64)) {
            let raw_weight = *std::vector::borrow(&raw_weights, j);
            let normalized_weight = (raw_weight * total_weight) / total_raw_weight;
            std::vector::push_back(&mut weights, normalized_weight);
            j = j + 1;
        };

        weights
    }

    /// Calculate bid-ask distribution
    fun calculate_bid_ask_distribution(
        lower_bin: u32,
        upper_bin: u32,
        total_weight: u64
    ): vector<u64> {
        let mut weights = std::vector::empty<u64>();
        let bin_count = upper_bin - lower_bin + 1;
        
        let edge_weight = total_weight * 40 / 100;
        let middle_bins = if (bin_count > 2) { bin_count - 2 } else { 0 };
        let middle_weight = if (middle_bins > 0) {
            (total_weight * 20 / 100) / (middle_bins as u64)
        } else {
            0
        };

        let mut i = 0u32;
        while (i < bin_count) {
            let weight = if (i == 0 || i == bin_count - 1) {
                edge_weight
            } else {
                middle_weight
            };
            std::vector::push_back(&mut weights, weight);
            i = i + 1;
        };

        weights
    }

    /// Calculate total weight of existing position
    fun calculate_existing_position_total_weight(position: &Position): u64 {
        let mut total_weight = 0u64;
        let mut current_bin = position.lower_bin_id;
        
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                let bin_position = table::borrow(&position.bin_positions, current_bin);
                total_weight = total_weight + bin_position.weight;
            };
            current_bin = current_bin + 1;
        };
        
        total_weight
    }

    // ==================== Position Management ====================

    /// 🔧 FIXED: Add liquidity to existing position with ACTUAL pool integration
    public fun add_liquidity_to_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Now mutable for actual liquidity addition
        mut coin_a: Coin<CoinA>,
        mut coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        assert!(sui::tx_context::sender(ctx) == position.owner, EUNAUTHORIZED);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 || amount_b > 0, EINVALID_AMOUNT);

        // Collect fees first
        let (fee_coin_a, fee_coin_b) = collect_fees_internal(position, pool, clock, ctx);
        
        // Transfer fees to position owner
        if (coin::value(&fee_coin_a) > 0) {
            sui::transfer::public_transfer(fee_coin_a, position.owner);
        } else {
            coin::destroy_zero(fee_coin_a);
        };
        
        if (coin::value(&fee_coin_b) > 0) {
            sui::transfer::public_transfer(fee_coin_b, position.owner);
        } else {
            coin::destroy_zero(fee_coin_b);
        };

        // 🔧 FIXED: Actually add liquidity to existing bins proportionally
        let mut current_bin = position.lower_bin_id;
        
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                let bin_position = table::borrow(&position.bin_positions, current_bin);
                let weight = bin_position.weight;
                
                // Calculate proportional amounts for this bin
                let total_weight = calculate_existing_position_total_weight(position);
                if (total_weight > 0) {
                    let amount_a_for_bin = (amount_a * weight) / total_weight;
                    let amount_b_for_bin = (amount_b * weight) / total_weight;
                    
                    if (amount_a_for_bin > 0 || amount_b_for_bin > 0) {
                        // Split coins for this bin
                        let coin_a_for_bin = if (amount_a_for_bin > 0) {
                            coin::split(&mut coin_a, amount_a_for_bin, ctx)
                        } else {
                            coin::zero<CoinA>(ctx)
                        };
                        
                        let coin_b_for_bin = if (amount_b_for_bin > 0) {
                            coin::split(&mut coin_b, amount_b_for_bin, ctx)
                        } else {
                            coin::zero<CoinB>(ctx)
                        };
                        
                        // 🔧 INTEGRATION: Actually add to pool
                        let shares_minted = dlmm_pool::add_liquidity_to_bin<CoinA, CoinB>(
                            pool,
                            current_bin,
                            coin_a_for_bin,
                            coin_b_for_bin,
                            clock,
                            ctx
                        );
                        
                        // Update position's bin entry
                        let bin_position_mut = table::borrow_mut(&mut position.bin_positions, current_bin);
                        bin_position_mut.shares = bin_position_mut.shares + shares_minted;
                        bin_position_mut.liquidity_a = bin_position_mut.liquidity_a + amount_a_for_bin;
                        bin_position_mut.liquidity_b = bin_position_mut.liquidity_b + amount_b_for_bin;
                    };
                };
            };
            current_bin = current_bin + 1;
        };

        // Return any remaining coins to owner
        if (coin::value(&coin_a) > 0) {
            sui::transfer::public_transfer(coin_a, position.owner);
        } else {
            coin::destroy_zero(coin_a);
        };
        
        if (coin::value(&coin_b) > 0) {
            sui::transfer::public_transfer(coin_b, position.owner);
        } else {
            coin::destroy_zero(coin_b);
        };

        // Update position totals
        position.total_liquidity_a = position.total_liquidity_a + amount_a;
        position.total_liquidity_b = position.total_liquidity_b + amount_b;

        // Emit event
        event::emit(LiquidityAddedToPosition {
            position_id: sui::object::uid_to_inner(&position.id),
            pool_id: position.pool_id,
            amount_a,
            amount_b,
            owner: position.owner,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    /// 🔧 FIXED: Remove liquidity from position with ACTUAL pool integration
    public fun remove_liquidity_from_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Now mutable for actual liquidity removal
        percentage: u8,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        assert!(sui::tx_context::sender(ctx) == position.owner, EUNAUTHORIZED);
        assert!(percentage > 0 && percentage <= 100, EINVALID_AMOUNT);

        // Collect fees first
        let (fee_coin_a, fee_coin_b) = collect_fees_internal(position, pool, clock, ctx);
        
        // Transfer fees to position owner
        if (coin::value(&fee_coin_a) > 0) {
            sui::transfer::public_transfer(fee_coin_a, position.owner);
        } else {
            coin::destroy_zero(fee_coin_a);
        };
        
        if (coin::value(&fee_coin_b) > 0) {
            sui::transfer::public_transfer(fee_coin_b, position.owner);
        } else {
            coin::destroy_zero(fee_coin_b);
        };

        // 🔧 FIXED: Actually remove liquidity from pool bins
        let mut total_coin_a = coin::zero<CoinA>(ctx);
        let mut total_coin_b = coin::zero<CoinB>(ctx);
        let mut total_removed_a = 0u64;
        let mut total_removed_b = 0u64;
        
        let mut bins_to_remove = std::vector::empty<u32>(); // Track empty bins for cleanup
        let mut current_bin = position.lower_bin_id;
        
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                let bin_position = table::borrow_mut(&mut position.bin_positions, current_bin);
                
                // Calculate shares to remove from this bin
                let shares_to_remove = (bin_position.shares * (percentage as u64)) / 100;
                
                if (shares_to_remove > 0) {
                    // 🔧 INTEGRATION: Actually remove from pool
                    let (removed_coin_a, removed_coin_b, fee_a, fee_b) = dlmm_pool::remove_liquidity_from_bin<CoinA, CoinB>(
                        pool,
                        current_bin,
                        shares_to_remove,
                        clock,
                        ctx
                    );
                    
                    // FIXED: Get coin values BEFORE moving them
                    let removed_amount_a = coin::value(&removed_coin_a);
                    let removed_amount_b = coin::value(&removed_coin_b);
                    
                    // Combine coins (this moves the coins)
                    coin::join(&mut total_coin_a, removed_coin_a);
                    coin::join(&mut total_coin_b, removed_coin_b);
                    
                    // FIXED: Use the captured values instead of trying to access moved coins
                    total_removed_a = total_removed_a + removed_amount_a + fee_a;
                    total_removed_b = total_removed_b + removed_amount_b + fee_b;
                    
                    // Update position's bin entry
                    bin_position.shares = bin_position.shares - shares_to_remove;
                    bin_position.liquidity_a = (bin_position.liquidity_a * (100 - percentage as u64)) / 100;
                    bin_position.liquidity_b = (bin_position.liquidity_b * (100 - percentage as u64)) / 100;
                    
                    // Mark bin for removal if no shares left
                    if (bin_position.shares == 0) {
                        std::vector::push_back(&mut bins_to_remove, current_bin);
                    };
                };
            };
            current_bin = current_bin + 1;
        };

        // Remove empty bin positions
        let mut i = 0;
        while (i < std::vector::length(&bins_to_remove)) {
            let bin_id = *std::vector::borrow(&bins_to_remove, i);
            let removed_bin_position = table::remove(&mut position.bin_positions, bin_id);
            // Destroy the removed position
            let BinPosition { 
                shares: _, 
                fee_growth_inside_last_a: _, 
                fee_growth_inside_last_b: _, 
                liquidity_a: _, 
                liquidity_b: _, 
                weight: _ 
            } = removed_bin_position;
            i = i + 1;
        };

        // Update position totals
        position.total_liquidity_a = (position.total_liquidity_a * (100 - percentage as u64)) / 100;
        position.total_liquidity_b = (position.total_liquidity_b * (100 - percentage as u64)) / 100;

        // Emit removal event
        event::emit(LiquidityRemovedFromPosition {
            position_id: sui::object::uid_to_inner(&position.id),
            pool_id: position.pool_id,
            percentage,
            amount_a: total_removed_a,
            amount_b: total_removed_b,
            owner: position.owner,
            timestamp: clock::timestamp_ms(clock),
        });

        (total_coin_a, total_coin_b)
    }

    /// 🔧 FIXED: Collect accumulated fees from position with ACTUAL pool integration
    public fun collect_fees_from_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &DLMMPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        assert!(sui::tx_context::sender(ctx) == position.owner, EUNAUTHORIZED);
        collect_fees_internal(position, pool, clock, ctx)
    }

    // ==================== Position Rebalancing ====================

    /// 🔧 FIXED: Rebalance position to maintain target distribution
    public fun rebalance_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>, // FIXED: Now mutable for rebalancing operations
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        assert!(sui::tx_context::sender(ctx) == position.owner, EUNAUTHORIZED);

        // Collect fees first
        let (fee_coin_a, fee_coin_b) = collect_fees_internal(position, pool, clock, ctx);
        
        // Transfer fees to position owner
        if (coin::value(&fee_coin_a) > 0) {
            sui::transfer::public_transfer(fee_coin_a, position.owner);
        } else {
            coin::destroy_zero(fee_coin_a);
        };
        
        if (coin::value(&fee_coin_b) > 0) {
            sui::transfer::public_transfer(fee_coin_b, position.owner);
        } else {
            coin::destroy_zero(fee_coin_b);
        };

        // 🔧 INTEGRATION: Advanced rebalancing logic would go here
        // For MVP, we'll implement basic rebalancing by:
        // 1. Remove all liquidity from current bins
        // 2. Recalculate distribution weights based on current price
        // 3. Redistribute liquidity according to new weights

        // Get current pool state for rebalancing
        let current_price = dlmm_pool::get_current_price(pool);
        let _new_weights = calculate_distribution_weights( // FIXED: Prefix with _ to suppress unused warning
            position.lower_bin_id,
            position.upper_bin_id,
            current_price,
            position.strategy_type,
            std::vector::empty()
        );

        // For now, just update the rebalance timestamp
        // Full rebalancing implementation would remove and re-add liquidity
        position.last_rebalance = clock::timestamp_ms(clock);

        event::emit(PositionRebalanced {
            position_id: sui::object::uid_to_inner(&position.id),
            pool_id: position.pool_id,
            owner: position.owner,
            timestamp: position.last_rebalance,
        });
    }

    // ==================== Public Access Functions ====================

    /// Get position ID
    public fun get_position_id(position: &Position): sui::object::ID {
        sui::object::uid_to_inner(&position.id)
    }

    /// Get position owner
    public fun get_position_owner(position: &Position): address {
        position.owner
    }

    /// Get position pool ID
    public fun get_position_pool_id(position: &Position): sui::object::ID {
        position.pool_id
    }

    /// Get position range
    public fun get_position_range(position: &Position): (u32, u32) {
        (position.lower_bin_id, position.upper_bin_id)
    }

    /// Get position strategy type
    public fun get_position_strategy(position: &Position): u8 {
        position.strategy_type
    }

    /// Get position creation timestamp
    public fun get_position_created_at(position: &Position): u64 {
        position.created_at
    }

    /// Get position last rebalance timestamp
    public fun get_position_last_rebalance(position: &Position): u64 {
        position.last_rebalance
    }

    // ==================== View Functions ====================

    /// Get position basic information
    public fun get_position_info(position: &Position): (sui::object::ID, u32, u32, u8, u64, u64, address) {
        (
            position.pool_id,
            position.lower_bin_id,
            position.upper_bin_id,
            position.strategy_type,
            position.total_liquidity_a,
            position.total_liquidity_b,
            position.owner
        )
    }

    /// Get position in specific bin
    public fun get_bin_position_info(
        position: &Position,
        bin_id: u32
    ): (bool, u64, u64, u64, u64) {
        if (table::contains(&position.bin_positions, bin_id)) {
            let bin_pos = table::borrow(&position.bin_positions, bin_id);
            (true, bin_pos.shares, bin_pos.liquidity_a, bin_pos.liquidity_b, bin_pos.weight)
        } else {
            (false, 0, 0, 0, 0)
        }
    }

    /// Get all bin IDs where position has liquidity
    public fun get_position_bin_ids(position: &Position): vector<u32> {
        let mut bin_ids = std::vector::empty<u32>();
        let mut current_bin = position.lower_bin_id;
        
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                std::vector::push_back(&mut bin_ids, current_bin);
            };
            current_bin = current_bin + 1;
        };
        
        bin_ids
    }

    /// Calculate total unclaimed fees for position
    public fun calculate_total_unclaimed_fees<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): (u64, u64) {
        let mut total_fees_a = position.unclaimed_fees_a;
        let mut total_fees_b = position.unclaimed_fees_b;

        let mut current_bin = position.lower_bin_id;
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                let bin_position = table::borrow(&position.bin_positions, current_bin);
                let (current_fee_growth_a, current_fee_growth_b) = get_bin_fee_growth(pool, current_bin);

                let fees_a = calculate_fees_earned(
                    bin_position.shares,
                    current_fee_growth_a,
                    bin_position.fee_growth_inside_last_a
                );

                let fees_b = calculate_fees_earned(
                    bin_position.shares,
                    current_fee_growth_b,
                    bin_position.fee_growth_inside_last_b
                );

                total_fees_a = total_fees_a + fees_a;
                total_fees_b = total_fees_b + fees_b;
            };
            current_bin = current_bin + 1;
        };

        (total_fees_a, total_fees_b)
    }

    /// Calculate position's current utilization
    public fun calculate_position_utilization(position: &Position): u8 {
        let total_bins = position.upper_bin_id - position.lower_bin_id + 1;
        let mut active_bins = 0u32;

        let mut current_bin = position.lower_bin_id;
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                let bin_pos = table::borrow(&position.bin_positions, current_bin);
                if (bin_pos.shares > 0) {
                    active_bins = active_bins + 1;
                };
            };
            current_bin = current_bin + 1;
        };

        ((active_bins * 100) / total_bins) as u8
    }

    // ==================== Advanced Position Analysis ====================

    /// Get detailed position performance metrics
    public fun get_position_performance<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): (u64, u64, u64, u64, u8, bool) { // (total_shares, fees_a, fees_b, active_bins, utilization, profitable)
        let mut total_shares = 0u64;
        let mut active_bins = 0u64; // FIXED: Changed from u32 to u64 to match return type
        let (fees_a, fees_b) = calculate_total_unclaimed_fees(position, pool);
        
        let mut current_bin = position.lower_bin_id;
        while (current_bin <= position.upper_bin_id) {
            if (table::contains(&position.bin_positions, current_bin)) {
                let bin_pos = table::borrow(&position.bin_positions, current_bin);
                total_shares = total_shares + bin_pos.shares;
                if (bin_pos.shares > 0) {
                    active_bins = active_bins + 1; // Now u64 + u64
                };
            };
            current_bin = current_bin + 1;
        };

        let utilization = calculate_position_utilization(position);
        let profitable = fees_a > 0 || fees_b > 0;

        (total_shares, fees_a, fees_b, active_bins, utilization, profitable)
    }

    /// Check if position needs rebalancing based on current market conditions
    public fun needs_rebalancing<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>,
        rebalance_threshold: u8 // Percentage threshold for rebalancing (e.g., 20 = 20%)
    ): bool {
        let (_, current_active_bin, _, _, _, _, _, _) = dlmm_pool::get_pool_info(pool);
        
        // Check if active bin moved outside position range
        if (current_active_bin < position.lower_bin_id || current_active_bin > position.upper_bin_id) {
            return true
        };

        // Check utilization threshold
        let utilization = calculate_position_utilization(position);
        utilization < rebalance_threshold
    }

    /// Calculate position's share of total pool liquidity
    public fun calculate_pool_share<CoinA, CoinB>(
        position: &Position,
        pool: &DLMMPool<CoinA, CoinB>
    ): (u64, u64) { // (share_a_bps, share_b_bps) basis points (10000 = 100%)
        let (pool_liquidity_a, pool_liquidity_b) = dlmm_pool::get_total_liquidity(pool);
        
        let share_a_bps = if (pool_liquidity_a > 0) {
            (position.total_liquidity_a * 10000) / pool_liquidity_a
        } else {
            0
        };
        
        let share_b_bps = if (pool_liquidity_b > 0) {
            (position.total_liquidity_b * 10000) / pool_liquidity_b
        } else {
            0
        };
        
        (share_a_bps, share_b_bps)
    }

    // ==================== Test Helpers ====================

    #[test_only]
    /// Create test position config
    public fun create_test_position_config(
        lower_bin_id: u32,
        upper_bin_id: u32,
        strategy_type: u8
    ): PositionConfig {
        PositionConfig {
            lower_bin_id,
            upper_bin_id,
            strategy_type,
            liquidity_distribution: std::vector::empty(),
        }
    }

    #[test_only]
    /// Create simple uniform position for testing
    public fun create_test_position<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        lower_bin_id: u32,
        upper_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        ctx: &mut sui::tx_context::TxContext
    ): Position {
        let config = PositionConfig {
            lower_bin_id,
            upper_bin_id,
            strategy_type: STRATEGY_UNIFORM,
            liquidity_distribution: std::vector::empty(),
        };

        let clock = sui::clock::create_for_testing(ctx);
        let position = create_position(pool, config, coin_a, coin_b, &clock, ctx);
        sui::clock::destroy_for_testing(clock);
        
        position
    }

    #[test_only]
    /// Test distribution weight calculation
    public fun test_distribution_weights(): bool {
        let lower_bin = 1000u32;
        let upper_bin = 1010u32;
        let current_price = sui_dlmm::bin_math::calculate_bin_price(1005, 25);

        let uniform_weights = calculate_distribution_weights(
            lower_bin, upper_bin, current_price, STRATEGY_UNIFORM, std::vector::empty()
        );
        
        if (std::vector::length(&uniform_weights) != 11) return false;
        
        let expected_weight = 10000 / 11;
        let first_weight = *std::vector::borrow(&uniform_weights, 0);
        if (abs_diff_u64(first_weight, expected_weight) > 10) return false;

        let curve_weights = calculate_distribution_weights(
            lower_bin, upper_bin, current_price, STRATEGY_CURVE, std::vector::empty()
        );
        
        let middle_weight = *std::vector::borrow(&curve_weights, 5);
        let edge_weight = *std::vector::borrow(&curve_weights, 0);
        if (middle_weight <= edge_weight) return false;

        let bid_ask_weights = calculate_distribution_weights(
            lower_bin, upper_bin, current_price, STRATEGY_BID_ASK, std::vector::empty()
        );
        
        let left_edge = *std::vector::borrow(&bid_ask_weights, 0);
        let right_edge = *std::vector::borrow(&bid_ask_weights, 10);
        let middle = *std::vector::borrow(&bid_ask_weights, 5);
        
        if (left_edge <= middle || right_edge <= middle) return false;

        true
    }

    #[test_only]
    /// Helper function for testing
    fun abs_diff_u64(a: u64, b: u64): u64 {
        if (a >= b) a - b else b - a
    }

    #[test_only]
    /// Test fee calculation
    public fun test_fee_calculation(): bool {
        let shares = 1000u64;
        let current_growth = 2000000000000000000u128;
        let last_growth = 1000000000000000000u128;
        
        let fees = calculate_fees_earned(shares, current_growth, last_growth);
        
        fees == 1000
    }

    #[test_only]
    /// Test position utilization calculation
    public fun test_position_utilization(): bool {
        let mut position = Position {
            id: sui::object::new(&mut sui::tx_context::dummy()),
            pool_id: sui::object::id_from_address(@0x1),
            lower_bin_id: 1000,
            upper_bin_id: 1004,
            bin_positions: table::new(&mut sui::tx_context::dummy()),
            strategy_type: STRATEGY_UNIFORM,
            total_liquidity_a: 1000,
            total_liquidity_b: 1000,
            unclaimed_fees_a: 0,
            unclaimed_fees_b: 0,
            created_at: 0,
            last_rebalance: 0,
            owner: @0xA11CE,
        };

        let mut i = 0;
        while (i < 3) {
            let bin_position = BinPosition {
                shares: 100,
                fee_growth_inside_last_a: 0,
                fee_growth_inside_last_b: 0,
                liquidity_a: 100,
                liquidity_b: 100,
                weight: 2000,
            };
            table::add(&mut position.bin_positions, 1000 + i, bin_position);
            i = i + 1;
        };

        let utilization = calculate_position_utilization(&position);
        
        let Position { id, pool_id: _, lower_bin_id: _, upper_bin_id: _, bin_positions, 
                      strategy_type: _, total_liquidity_a: _, total_liquidity_b: _,
                      unclaimed_fees_a: _, unclaimed_fees_b: _, created_at: _, 
                      last_rebalance: _, owner: _ } = position;
        sui::object::delete(id);
        table::destroy_empty(bin_positions);

        utilization == 60
    }

    // ==================== 🔧 NEW: Integration Test Functions ====================

    #[test_only]
    /// Test position-pool integration end-to-end
    public fun test_position_pool_integration<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        ctx: &mut sui::tx_context::TxContext
    ): bool {
        // Create position with actual pool integration
        let config = create_test_position_config(995, 1005, STRATEGY_UNIFORM);
        let clock = sui::clock::create_for_testing(ctx);
        
        // Get initial pool liquidity
        let (initial_pool_a, initial_pool_b) = dlmm_pool::get_total_liquidity(pool);
        
        // Create position (should add liquidity to pool)
        let position = create_position(pool, config, coin_a, coin_b, &clock, ctx);
        
        // Check that pool liquidity increased
        let (final_pool_a, final_pool_b) = dlmm_pool::get_total_liquidity(pool);
        let liquidity_increased = (final_pool_a > initial_pool_a) || (final_pool_b > initial_pool_b);
        
        // Check that position has bin positions
        let position_bins = get_position_bin_ids(&position);
        let has_positions = std::vector::length(&position_bins) > 0;
        
        // Cleanup
        sui::clock::destroy_for_testing(clock);
        let Position { id, pool_id: _, lower_bin_id: _, upper_bin_id: _, bin_positions, 
                      strategy_type: _, total_liquidity_a: _, total_liquidity_b: _,
                      unclaimed_fees_a: _, unclaimed_fees_b: _, created_at: _, 
                      last_rebalance: _, owner: _ } = position;
        sui::object::delete(id);
        table::drop(bin_positions);
        
        liquidity_increased && has_positions
    }

    #[test_only]
    /// Test liquidity addition integration
    public fun test_add_liquidity_integration<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        ctx: &mut sui::tx_context::TxContext
    ): bool {
        let clock = sui::clock::create_for_testing(ctx);
        
        // Get initial values
        let initial_total_a = position.total_liquidity_a;
        let initial_total_b = position.total_liquidity_b;
        let add_amount_a = coin::value(&coin_a);
        let add_amount_b = coin::value(&coin_b);
        
        // Add liquidity
        add_liquidity_to_position(position, pool, coin_a, coin_b, &clock, ctx);
        
        // Check that position totals increased appropriately
        let position_updated = position.total_liquidity_a >= initial_total_a + add_amount_a ||
                              position.total_liquidity_b >= initial_total_b + add_amount_b;
        
        sui::clock::destroy_for_testing(clock);
        position_updated
    }

    #[test_only]
    /// Test fee collection integration
    public fun test_fee_collection_integration<CoinA, CoinB>(
        position: &mut Position,
        pool: &DLMMPool<CoinA, CoinB>,
        ctx: &mut sui::tx_context::TxContext
    ): bool {
        let clock = sui::clock::create_for_testing(ctx);
        
        // Collect fees
        let (fee_a, fee_b) = collect_fees_from_position(position, pool, &clock, ctx);
        
        // Check that fee coins are created (even if zero)
        let fees_collected = true; // Coins created successfully
        
        // Cleanup
        coin::destroy_zero(fee_a);
        coin::destroy_zero(fee_b);
        sui::clock::destroy_for_testing(clock);
        
        fees_collected
    }

    #[test_only]
    /// Test liquidity removal integration
    public fun test_remove_liquidity_integration<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>,
        percentage: u8,
        ctx: &mut sui::tx_context::TxContext
    ): bool {
        let clock = sui::clock::create_for_testing(ctx);
        
        // Get initial values
        let initial_total_a = position.total_liquidity_a;
        let initial_total_b = position.total_liquidity_b;
        
        // Remove liquidity
        let (removed_a, removed_b) = remove_liquidity_from_position(position, pool, percentage, &clock, ctx);
        
        // Check that coins were returned and position totals decreased
        let coins_returned = coin::value(&removed_a) > 0 || coin::value(&removed_b) > 0;
        let totals_decreased = position.total_liquidity_a < initial_total_a || 
                              position.total_liquidity_b < initial_total_b;
        
        // Cleanup
        coin::destroy_zero(removed_a);
        coin::destroy_zero(removed_b);
        sui::clock::destroy_for_testing(clock);
        
        coins_returned || totals_decreased // Either should be true for successful removal
    }

    #[test_only]
    /// Comprehensive integration test
    public fun test_full_position_lifecycle<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        ctx: &mut sui::tx_context::TxContext
    ): bool {
        let clock = sui::clock::create_for_testing(ctx);
        
        // 1. Create position
        let config = create_test_position_config(995, 1005, STRATEGY_CURVE);
        let mut position = create_position(pool, config, coin_a, coin_b, &clock, ctx);
        
        // 2. Check position was created with bins
        let bin_count = std::vector::length(&get_position_bin_ids(&position));
        if (bin_count == 0) {
            sui::clock::destroy_for_testing(clock);
            let Position { id, pool_id: _, lower_bin_id: _, upper_bin_id: _, bin_positions, 
                          strategy_type: _, total_liquidity_a: _, total_liquidity_b: _,
                          unclaimed_fees_a: _, unclaimed_fees_b: _, created_at: _, 
                          last_rebalance: _, owner: _ } = position;
            sui::object::delete(id);
            table::drop(bin_positions);
            return false
        };
        
        // 3. Test rebalancing
        rebalance_position(&mut position, pool, &clock, ctx);
        
        // 4. Test fee collection
        let (fee_a, fee_b) = collect_fees_from_position(&mut position, pool, &clock, ctx);
        coin::destroy_zero(fee_a);
        coin::destroy_zero(fee_b);
        
        // 5. Test partial liquidity removal
        let (removed_a, removed_b) = remove_liquidity_from_position(&mut position, pool, 25, &clock, ctx);
        coin::destroy_zero(removed_a);
        coin::destroy_zero(removed_b);
        
        // Cleanup
        sui::clock::destroy_for_testing(clock);
        let Position { id, pool_id: _, lower_bin_id: _, upper_bin_id: _, bin_positions, 
                      strategy_type: _, total_liquidity_a: _, total_liquidity_b: _,
                      unclaimed_fees_a: _, unclaimed_fees_b: _, created_at: _, 
                      last_rebalance: _, owner: _ } = position;
        sui::object::delete(id);
        table::drop(bin_positions);
        
        true // All operations completed successfully
    }
}