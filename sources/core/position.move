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
    public struct BinPosition has store {
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
        pool: &mut DLMMPool<CoinA, CoinB>,
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

                bin_position.fee_growth_inside_last_a = current_fee_growth_a;
                bin_position.fee_growth_inside_last_b = current_fee_growth_b;

                total_fees_a = total_fees_a + fees_a;
                total_fees_b = total_fees_b + fees_b;
            };
            current_bin = current_bin + 1;
        };

        total_fees_a = total_fees_a + position.unclaimed_fees_a;
        total_fees_b = total_fees_b + position.unclaimed_fees_b;

        position.unclaimed_fees_a = 0;
        position.unclaimed_fees_b = 0;

        let fee_coin_a = coin::zero<CoinA>(ctx);
        let fee_coin_b = coin::zero<CoinB>(ctx);

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

    // ==================== Position Creation ====================

    /// Create new multi-bin liquidity position
    public fun create_position<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
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

        // Create position structure
        let position = Position {
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

        // For now, return coins to owner (simplified implementation)
        sui::transfer::public_transfer(coin_a, owner);
        sui::transfer::public_transfer(coin_b, owner);

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
        _current_price: u128,
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
            weights = calculate_curve_distribution(lower_bin, upper_bin, total_weight);
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

    /// Calculate curve distribution
    fun calculate_curve_distribution(
        lower_bin: u32,
        upper_bin: u32,
        total_weight: u64
    ): vector<u64> {
        let mut weights = std::vector::empty<u64>();
        let center_bin = (lower_bin + upper_bin) / 2;

        let mut total_raw_weight = 0u64;
        let mut raw_weights = std::vector::empty<u64>();

        let mut i = lower_bin;
        while (i <= upper_bin) {
            let distance = if (i >= center_bin) { i - center_bin } else { center_bin - i };
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

    // ==================== Position Management ====================

    /// Add liquidity to existing position
    public fun add_liquidity_to_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
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

        // For now, just return the coins to owner (simplified)
        sui::transfer::public_transfer(coin_a, position.owner);
        sui::transfer::public_transfer(coin_b, position.owner);

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

    /// Remove liquidity from position (partial or full)
    public fun remove_liquidity_from_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>,
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

        // For now, return zero coins (simplified)
        let total_coin_a = coin::zero<CoinA>(ctx);
        let total_coin_b = coin::zero<CoinB>(ctx);

        // Update position totals
        let removed_a = coin::value(&total_coin_a);
        let removed_b = coin::value(&total_coin_b);
        position.total_liquidity_a = position.total_liquidity_a - removed_a;
        position.total_liquidity_b = position.total_liquidity_b - removed_b;

        // Emit removal event
        event::emit(LiquidityRemovedFromPosition {
            position_id: sui::object::uid_to_inner(&position.id),
            pool_id: position.pool_id,
            percentage,
            amount_a: removed_a,
            amount_b: removed_b,
            owner: position.owner,
            timestamp: clock::timestamp_ms(clock),
        });

        (total_coin_a, total_coin_b)
    }

    /// Collect accumulated fees from position
    public fun collect_fees_from_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        assert!(sui::tx_context::sender(ctx) == position.owner, EUNAUTHORIZED);
        collect_fees_internal(position, pool, clock, ctx)
    }

    // ==================== Position Rebalancing ====================

    /// Rebalance position to maintain target distribution
    public fun rebalance_position<CoinA, CoinB>(
        position: &mut Position,
        pool: &mut DLMMPool<CoinA, CoinB>,
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

        // Update timestamp
        position.last_rebalance = clock::timestamp_ms(clock);

        event::emit(PositionRebalanced {
            position_id: sui::object::uid_to_inner(&position.id),
            pool_id: position.pool_id,
            owner: position.owner,
            timestamp: position.last_rebalance,
        });
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
    /// Get position ID for testing
    public fun get_position_id(position: &Position): sui::object::ID {
        sui::object::uid_to_inner(&position.id)
    }

    #[test_only]
    /// Get position owner for testing
    public fun get_position_owner(position: &Position): address {
        position.owner
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
}