module sui_dlmm::dlmm_pool {
    use sui::object;
    use sui::tx_context;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::transfer;
    
    // Import our math modules
    use sui_dlmm::bin_math;
    use sui_dlmm::constant_sum;
    use sui_dlmm::fee_math;
    use sui_dlmm::volatility::{Self, VolatilityAccumulator};

    // Error codes (CLEANED UP)
    const EINVALID_BIN_STEP: u64 = 1;
    const EINVALID_PRICE: u64 = 2;
    const EINSUFFICIENT_LIQUIDITY: u64 = 3;
    const EMIN_AMOUNT_OUT: u64 = 7;
    const EINVALID_AMOUNT: u64 = 8;
    const EPOOL_INACTIVE: u64 = 9;

    /// Main DLMM pool struct
    public struct DLMMPool<phantom CoinA, phantom CoinB> has key {
        id: object::UID,
        bin_step: u16,                          // Basis points between bins
        active_bin_id: u32,                     // Current active bin ID where trades happen
        reserves_a: Balance<CoinA>,             // Total reserves of token A
        reserves_b: Balance<CoinB>,             // Total reserves of token B
        bins: Table<u32, LiquidityBin>,         // bin_id -> LiquidityBin mapping
        volatility_accumulator: VolatilityAccumulator, // Tracks market volatility for dynamic fees
        protocol_fee_rate: u16,                 // Protocol fee rate in basis points
        base_factor: u16,                       // Base factor for fee calculation
        created_at: u64,                        // Pool creation timestamp
        total_swaps: u64,                       // Total number of swaps executed
        total_volume_a: u64,                    // Cumulative volume in token A
        total_volume_b: u64,                    // Cumulative volume in token B
        is_active: bool,                        // Pool active status (circuit breaker)
    }

    /// Individual liquidity bin implementing constant sum formula: P*x + y = L
    public struct LiquidityBin has store {
        bin_id: u32,                    // Unique bin identifier
        liquidity_a: u64,               // Token A reserves in this bin
        liquidity_b: u64,               // Token B reserves in this bin
        total_shares: u64,              // Total LP shares for this bin
        fee_growth_a: u128,             // Accumulated fees per share for token A
        fee_growth_b: u128,             // Accumulated fees per share for token B
        is_active: bool,                // Whether this is the current active bin
        price: u128,                    // Cached bin price (scaled by 2^64)
        last_update_time: u64,          // Last time bin was updated
    }

    /// Result of swap operation with detailed metrics
    public struct SwapResult has drop {
        amount_out: u64,                // Total output amount
        fee_amount: u64,                // Total fees paid
        protocol_fee: u64,              // Protocol fee portion
        bins_crossed: u32,              // Number of bins traversed
        final_bin_id: u32,              // Final active bin after swap
        price_impact: u128,             // Price impact of the swap
    }

    // ==================== Pool Creation ====================

    /// Create new DLMM pool with initial liquidity
    public fun create_pool<CoinA, CoinB>(
        bin_step: u16,
        initial_bin_id: u32,
        initial_price: u128,
        protocol_fee_rate: u16,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut TxContext
    ): DLMMPool<CoinA, CoinB> {
        assert!(bin_step > 0 && bin_step <= 10000, EINVALID_BIN_STEP);
        assert!(initial_price > 0, EINVALID_PRICE);

        let current_time = clock::timestamp_ms(clock);
        
        // Create volatility accumulator
        let volatility_accumulator = volatility::new_volatility_accumulator(
            initial_bin_id,
            current_time
        );

        // Validate initial price matches initial_bin_id
        let calculated_price = bin_math::calculate_bin_price(initial_bin_id, bin_step);
        assert!(abs_diff_u128(initial_price, calculated_price) < calculated_price / 100, EINVALID_PRICE); // 1% tolerance

        // Create the pool
        let mut pool = DLMMPool {
            id: object::new(ctx),
            bin_step,
            active_bin_id: initial_bin_id,
            reserves_a: coin::into_balance(coin_a),
            reserves_b: coin::into_balance(coin_b),
            bins: table::new(ctx),
            volatility_accumulator,
            protocol_fee_rate,
            base_factor: 100, // Default 1% base factor
            created_at: current_time,
            total_swaps: 0,
            total_volume_a: 0,
            total_volume_b: 0,
            is_active: true,
        };

        // Initialize active bin with provided liquidity
        if (balance::value(&pool.reserves_a) > 0 || balance::value(&pool.reserves_b) > 0) {
            initialize_active_bin(&mut pool, initial_price, current_time);
        };

        // Emit pool creation event
        event::emit(PoolCreated {
            pool_id: object::uid_to_inner(&pool.id),
            bin_step,
            initial_bin_id,
            initial_price,
            creator: tx_context::sender(ctx),
            timestamp: current_time,
        });

        pool
    }

    /// Initialize the active bin with initial liquidity
    fun initialize_active_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        price: u128,
        current_time: u64
    ) {
        let reserve_a = balance::value(&pool.reserves_a);
        let reserve_b = balance::value(&pool.reserves_b);

        // Calculate initial shares using constant sum formula
        let initial_shares = if (reserve_a == 0 && reserve_b == 0) {
            0
        } else {
            // Use liquidity formula: L = P*x + y
            constant_sum::calculate_liquidity_from_amounts(reserve_a, reserve_b, price)
        };

        let bin = LiquidityBin {
            bin_id: pool.active_bin_id,
            liquidity_a: reserve_a,
            liquidity_b: reserve_b,
            total_shares: initial_shares,
            fee_growth_a: 0,
            fee_growth_b: 0,
            is_active: true,
            price,
            last_update_time: current_time,
        };

        table::add(&mut pool.bins, pool.active_bin_id, bin);
    }

    /// Share the pool object (entry function for deployment)
    public entry fun share_pool<CoinA, CoinB>(pool: DLMMPool<CoinA, CoinB>) {
        transfer::share_object(pool);
    }

    // ==================== Core Swap Implementation ====================

    /// Execute swap with zero slippage within bins and dynamic fees across bins
    public fun swap<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_in: Coin<CoinA>,
        min_amount_out: u64,
        zero_for_one: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<CoinB> {
        assert!(pool.is_active, EPOOL_INACTIVE);
        
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EINVALID_AMOUNT);

        // Execute the multi-bin swap
        let swap_result = execute_multi_bin_swap(
            pool,
            amount_in,
            zero_for_one,
            clock
        );

        // Verify minimum amount out requirement
        assert!(swap_result.amount_out >= min_amount_out, EMIN_AMOUNT_OUT);

        // Update pool reserves with input
        balance::join(&mut pool.reserves_a, coin::into_balance(coin_in));
        
        // Extract output from reserves
        let output_balance = balance::split(&mut pool.reserves_b, swap_result.amount_out);

        // Update pool statistics
        pool.total_swaps = pool.total_swaps + 1;
        if (zero_for_one) {
            pool.total_volume_a = pool.total_volume_a + amount_in;
        } else {
            pool.total_volume_b = pool.total_volume_b + amount_in;
        };

        // Emit comprehensive swap event
        event::emit(SwapExecuted {
            pool_id: object::uid_to_inner(&pool.id),
            user: tx_context::sender(ctx),
            amount_in,
            amount_out: swap_result.amount_out,
            zero_for_one,
            bins_crossed: swap_result.bins_crossed,
            fee_amount: swap_result.fee_amount,
            protocol_fee: swap_result.protocol_fee,
            start_bin_id: pool.active_bin_id,
            final_bin_id: swap_result.final_bin_id,
            price_impact: swap_result.price_impact,
        });

        coin::from_balance(output_balance, ctx)
    }

    /// Execute multi-bin swap with dynamic fee calculation
    fun execute_multi_bin_swap<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        amount_in: u64,
        zero_for_one: bool,
        clock: &Clock
    ): SwapResult {
        let mut remaining_amount_in = amount_in;
        let mut total_amount_out = 0u64;
        let mut total_fee = 0u64;
        let mut bins_crossed = 0u32;
        let mut current_bin_id = pool.active_bin_id;
        let start_price = get_current_price(pool);

        let current_time = clock::timestamp_ms(clock);

        // Traverse bins until swap is complete or we hit limits
        while (remaining_amount_in > 0 && bins_crossed < 100) { // Safety limit
            
            // Get or create current bin
            if (!table::contains(&pool.bins, current_bin_id)) {
                create_empty_bin(pool, current_bin_id, current_time);
            };

            let bin = table::borrow_mut(&mut pool.bins, current_bin_id);
            
            // Skip empty bins
            if (bin.liquidity_a == 0 && bin.liquidity_b == 0) {
                current_bin_id = bin_math::get_next_bin_id(current_bin_id, zero_for_one);
                bins_crossed = bins_crossed + 1;
                continue
            };

            // Calculate maximum amount we can swap in this bin
            let max_swap_amount = constant_sum::calculate_max_swap_amount(
                bin.liquidity_a,
                bin.liquidity_b,
                zero_for_one,
                bin.price
            );

            if (max_swap_amount == 0) {
                // No capacity in this direction, move to next bin
                current_bin_id = bin_math::get_next_bin_id(current_bin_id, zero_for_one);
                bins_crossed = bins_crossed + 1;
                continue
            };

            // Determine actual amount to swap in this bin
            let amount_to_swap = if (remaining_amount_in <= max_swap_amount) {
                remaining_amount_in
            } else {
                max_swap_amount
            };

            // Execute zero-slippage swap within this bin
            let (amount_out, bin_exhausted) = constant_sum::swap_within_bin(
                bin.liquidity_a,
                bin.liquidity_b,
                amount_to_swap,
                zero_for_one,
                bin.price
            );

            // Calculate dynamic fee for this portion
            let current_fee_rate = fee_math::calculate_dynamic_fee(
                pool.base_factor,
                pool.bin_step,
                bins_crossed
            );
            let fee_amount = fee_math::calculate_fee_amount(amount_to_swap, current_fee_rate);

            // Update bin reserves after swap
            let (new_liquidity_a, new_liquidity_b) = constant_sum::update_reserves_after_swap(
                bin.liquidity_a,
                bin.liquidity_b,
                amount_to_swap,
                amount_out,
                zero_for_one
            );

            // Update bin state
            bin.liquidity_a = new_liquidity_a;
            bin.liquidity_b = new_liquidity_b;
            bin.last_update_time = current_time;

            // Accumulate fees in bin (for LP fee distribution)
            update_bin_fees(bin, fee_amount, zero_for_one);

            // Update running totals
            remaining_amount_in = remaining_amount_in - amount_to_swap;
            total_amount_out = total_amount_out + amount_out;
            total_fee = total_fee + fee_amount;

            // Check if we need to move to next bin
            if (bin_exhausted) {
                current_bin_id = bin_math::get_next_bin_id(current_bin_id, zero_for_one);
                bins_crossed = bins_crossed + 1;
            } else {
                // Swap completed within this bin
                break
            };
        };

        // Update pool's active bin
        update_active_bin(pool, current_bin_id);

        // Update volatility accumulator
        pool.volatility_accumulator = volatility::update_volatility_accumulator(
            pool.volatility_accumulator,
            current_bin_id,
            bins_crossed,
            current_time
        );

        // Calculate protocol fee
        let protocol_fee = fee_math::calculate_protocol_fee(total_fee, pool.protocol_fee_rate);

        // Calculate price impact
        let end_price = get_current_price(pool);
        let price_impact = calculate_price_impact(start_price, end_price);

        SwapResult {
            amount_out: total_amount_out,
            fee_amount: total_fee,
            protocol_fee,
            bins_crossed,
            final_bin_id: current_bin_id,
            price_impact,
        }
    }

    /// Create an empty bin at specified bin_id
    fun create_empty_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        current_time: u64
    ) {
        let price = bin_math::calculate_bin_price(bin_id, pool.bin_step);
        
        let bin = LiquidityBin {
            bin_id,
            liquidity_a: 0,
            liquidity_b: 0,
            total_shares: 0,
            fee_growth_a: 0,
            fee_growth_b: 0,
            is_active: false,
            price,
            last_update_time: current_time,
        };

        table::add(&mut pool.bins, bin_id, bin);
    }

    /// Update bin fee accumulation for LP rewards
    fun update_bin_fees(bin: &mut LiquidityBin, fee_amount: u64, zero_for_one: bool) {
        if (bin.total_shares > 0) {
            let fee_per_share = (fee_amount as u128) * 1000000000000000000u128 / (bin.total_shares as u128); // Scale by 10^18
            
            if (zero_for_one) {
                bin.fee_growth_a = bin.fee_growth_a + fee_per_share;
            } else {
                bin.fee_growth_b = bin.fee_growth_b + fee_per_share;
            };
        };
    }

    /// Update which bin is currently active
    fun update_active_bin<CoinA, CoinB>(pool: &mut DLMMPool<CoinA, CoinB>, new_active_bin_id: u32) {
        // Deactivate old active bin
        if (table::contains(&pool.bins, pool.active_bin_id)) {
            let old_bin = table::borrow_mut(&mut pool.bins, pool.active_bin_id);
            old_bin.is_active = false;
        };

        pool.active_bin_id = new_active_bin_id;

        // Activate new bin
        if (table::contains(&pool.bins, new_active_bin_id)) {
            let new_bin = table::borrow_mut(&mut pool.bins, new_active_bin_id);
            new_bin.is_active = true;
        };
    }

    /// Calculate price impact from start to end price
    fun calculate_price_impact(start_price: u128, end_price: u128): u128 {
        if (start_price == 0) return 0;
        
        let diff = if (end_price >= start_price) {
            end_price - start_price
        } else {
            start_price - end_price
        };
        
        // Return impact as percentage (scaled by 10000 for basis points)
        (diff * 10000) / start_price
    }

    // ==================== Liquidity Management ====================

    /// Add liquidity to a specific bin
    public fun add_liquidity_to_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut TxContext
    ): u64 { // Returns LP shares minted
        assert!(pool.is_active, EPOOL_INACTIVE);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        let current_time = clock::timestamp_ms(clock);
        
        // Validate at least one token is provided
        assert!(amount_a > 0 || amount_b > 0, EINVALID_AMOUNT);

        // Get or create bin
        if (!table::contains(&pool.bins, bin_id)) {
            create_empty_bin(pool, bin_id, current_time);
        };

        let bin = table::borrow_mut(&mut pool.bins, bin_id);
        
        // Calculate shares to mint based on constant sum formula
        let liquidity_to_add = constant_sum::calculate_liquidity_from_amounts(
            amount_a,
            amount_b,
            bin.price
        );

        let shares_to_mint = if (bin.total_shares == 0) {
            // First liquidity provider - mint shares equal to liquidity
            liquidity_to_add
        } else {
            // Calculate proportional shares
            let current_bin_liquidity = constant_sum::calculate_liquidity_from_amounts(
                bin.liquidity_a,
                bin.liquidity_b,
                bin.price
            );
            
            if (current_bin_liquidity == 0) {
                liquidity_to_add // Treat as first LP if current liquidity is zero
            } else {
                (liquidity_to_add * bin.total_shares) / current_bin_liquidity
            }
        };

        // Update bin state
        bin.liquidity_a = bin.liquidity_a + amount_a;
        bin.liquidity_b = bin.liquidity_b + amount_b;
        bin.total_shares = bin.total_shares + shares_to_mint;
        bin.last_update_time = current_time;

        // Update pool reserves
        balance::join(&mut pool.reserves_a, coin::into_balance(coin_a));
        balance::join(&mut pool.reserves_b, coin::into_balance(coin_b));

        // Emit liquidity added event
        event::emit(LiquidityAdded {
            pool_id: object::uid_to_inner(&pool.id),
            bin_id,
            user: tx_context::sender(ctx),
            amount_a,
            amount_b,
            shares_minted: shares_to_mint,
            timestamp: current_time,
        });

        shares_to_mint
    }

    /// Remove liquidity from a specific bin
    public fun remove_liquidity_from_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        shares_to_burn: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>, u64, u64) { // Returns (coin_a, coin_b, fee_a, fee_b)
        assert!(table::contains(&pool.bins, bin_id), EINSUFFICIENT_LIQUIDITY);
        assert!(shares_to_burn > 0, EINVALID_AMOUNT);
        
        let bin = table::borrow_mut(&mut pool.bins, bin_id);
        assert!(shares_to_burn <= bin.total_shares, EINSUFFICIENT_LIQUIDITY);

        let current_time = clock::timestamp_ms(clock);

        // Calculate proportional amounts to return
        let amount_a = if (bin.total_shares > 0) {
            (bin.liquidity_a * shares_to_burn) / bin.total_shares
        } else {
            0
        };
        
        let amount_b = if (bin.total_shares > 0) {
            (bin.liquidity_b * shares_to_burn) / bin.total_shares
        } else {
            0
        };

        // Calculate accumulated fees for this position
        let (fee_a, fee_b) = calculate_accumulated_fees(bin, shares_to_burn);

        // Update bin state
        bin.liquidity_a = bin.liquidity_a - amount_a;
        bin.liquidity_b = bin.liquidity_b - amount_b;
        bin.total_shares = bin.total_shares - shares_to_burn;
        bin.last_update_time = current_time;

        // Extract coins from pool reserves
        let balance_a = balance::split(&mut pool.reserves_a, amount_a + fee_a);
        let balance_b = balance::split(&mut pool.reserves_b, amount_b + fee_b);

        // Emit liquidity removal event
        event::emit(LiquidityRemoved {
            pool_id: object::uid_to_inner(&pool.id),
            bin_id,
            user: tx_context::sender(ctx),
            amount_a,
            amount_b,
            shares_burned: shares_to_burn,
            fee_a,
            fee_b,
            timestamp: current_time,
        });

        (
            coin::from_balance(balance_a, ctx),
            coin::from_balance(balance_b, ctx),
            fee_a,
            fee_b
        )
    }

    /// Calculate accumulated fees for LP position
    fun calculate_accumulated_fees(bin: &LiquidityBin, shares: u64): (u64, u64) {
        if (shares == 0 || bin.total_shares == 0) return (0, 0);

        let fee_a = ((bin.fee_growth_a * (shares as u128)) / 1000000000000000000u128) as u64; // Unscale
        let fee_b = ((bin.fee_growth_b * (shares as u128)) / 1000000000000000000u128) as u64; // Unscale

        (fee_a, fee_b)
    }

    // ==================== View Functions ====================

    /// Get comprehensive pool information
    public fun get_pool_info<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>
    ): (u16, u32, u64, u64, u64, u64, u64, bool) {
        (
            pool.bin_step,
            pool.active_bin_id,
            balance::value(&pool.reserves_a),
            balance::value(&pool.reserves_b),
            pool.total_swaps,
            pool.total_volume_a,
            pool.total_volume_b,
            pool.is_active
        )
    }

    /// Get detailed bin information (FIXED - simpler return type)
    public fun get_bin_info<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        bin_id: u32
    ): (bool, u64, u64, u64, u128, u128, u128) { // (exists, liquidity_a, liquidity_b, shares, price, fee_growth_a, fee_growth_b)
        if (table::contains(&pool.bins, bin_id)) {
            let bin = table::borrow(&pool.bins, bin_id);
            (
                true,                   // exists
                bin.liquidity_a,
                bin.liquidity_b,
                bin.total_shares,
                bin.price,
                bin.fee_growth_a,
                bin.fee_growth_b
            )
        } else {
            (false, 0, 0, 0, 0, 0, 0)
        }
    }

    /// Get current pool price (active bin price)
    public fun get_current_price<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): u128 {
        bin_math::calculate_bin_price(pool.active_bin_id, pool.bin_step)
    }

    /// Get volatility information
    public fun get_volatility_info<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>
    ): (u64, u64, u32, u64, bool) {
        volatility::get_volatility_stats(&pool.volatility_accumulator)
    }

    /// Quote swap without executing (simulation) (FIXED - simpler return)
    public fun quote_swap<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        amount_in: u64,
        zero_for_one: bool
    ): (u64, u64, u32, u128) { // (amount_out, total_fee, bins_crossed, price_impact)
        simulate_swap(pool, amount_in, zero_for_one)
    }

    /// Simulate swap for quotation (read-only, no state changes)
    fun simulate_swap<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        amount_in: u64,
        zero_for_one: bool
    ): (u64, u64, u32, u128) {
        let mut remaining_amount_in = amount_in;
        let mut total_amount_out = 0u64;
        let mut total_fee = 0u64;
        let mut bins_crossed = 0u32;
        let mut current_bin_id = pool.active_bin_id;
        let start_price = get_current_price(pool);

        // Simulate bin traversal without modifying state
        while (remaining_amount_in > 0 && bins_crossed < 100) {
            
            if (table::contains(&pool.bins, current_bin_id)) {
                let bin = table::borrow(&pool.bins, current_bin_id);
                
                if (bin.liquidity_a > 0 || bin.liquidity_b > 0) {
                    let max_swap_amount = constant_sum::calculate_max_swap_amount(
                        bin.liquidity_a,
                        bin.liquidity_b,
                        zero_for_one,
                        bin.price
                    );

                    if (max_swap_amount > 0) {
                        let amount_to_swap = if (remaining_amount_in <= max_swap_amount) {
                            remaining_amount_in
                        } else {
                            max_swap_amount
                        };

                        let (amount_out, bin_exhausted) = constant_sum::swap_within_bin(
                            bin.liquidity_a,
                            bin.liquidity_b,
                            amount_to_swap,
                            zero_for_one,
                            bin.price
                        );

                        // Calculate fees
                        let fee_rate = fee_math::calculate_dynamic_fee(
                            pool.base_factor,
                            pool.bin_step,
                            bins_crossed
                        );
                        let fee_amount = fee_math::calculate_fee_amount(amount_to_swap, fee_rate);

                        remaining_amount_in = remaining_amount_in - amount_to_swap;
                        total_amount_out = total_amount_out + amount_out;
                        total_fee = total_fee + fee_amount;

                        if (!bin_exhausted) {
                            break
                        };
                    };
                };
            };

            current_bin_id = bin_math::get_next_bin_id(current_bin_id, zero_for_one);
            bins_crossed = bins_crossed + 1;
        };

        let end_price = bin_math::calculate_bin_price(current_bin_id, pool.bin_step);
        let price_impact = calculate_price_impact(start_price, end_price);

        (total_amount_out, total_fee, bins_crossed, price_impact)
    }

    // ==================== Admin Functions ====================

    /// Update base factor for dynamic fee calculation
    public fun update_base_factor<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        new_base_factor: u16,
        ctx: &TxContext
    ) {
        let old_factor = pool.base_factor;
        pool.base_factor = new_base_factor;
        
        event::emit(BaseFeeFactorUpdated {
            pool_id: object::uid_to_inner(&pool.id),
            old_factor,
            new_factor: new_base_factor,
            admin: tx_context::sender(ctx),
        });
    }

    /// Emergency pause/unpause pool (circuit breaker)
    public fun set_pool_active_status<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        active: bool,
        ctx: &TxContext
    ) {
        pool.is_active = active;
        
        event::emit(PoolStatusChanged {
            pool_id: object::uid_to_inner(&pool.id),
            is_active: active,
            admin: tx_context::sender(ctx),
        });
    }

    /// Force update volatility accumulator (governance function)
    public fun reset_volatility<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        pool.volatility_accumulator = volatility::reset_volatility_accumulator(
            pool.volatility_accumulator,
            current_time
        );
        
        event::emit(VolatilityReset {
            pool_id: object::uid_to_inner(&pool.id),
            admin: tx_context::sender(ctx),
            timestamp: current_time,
        });
    }

    // ==================== Utility Functions ====================

    /// Get total liquidity in the pool across all bins
    public fun get_total_liquidity<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.reserves_a), balance::value(&pool.reserves_b))
    }

    /// Get bins around active bin (FIXED - simpler structure)
    public fun get_bins_around_active<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        range: u32 // Number of bins on each side
    ): (vector<u32>, vector<u64>, vector<u64>, vector<u128>) { // (bin_ids, liquidity_a_vec, liquidity_b_vec, prices)
        let mut bin_ids = vector::empty<u32>();
        let mut liquidity_a_vec = vector::empty<u64>();
        let mut liquidity_b_vec = vector::empty<u64>();
        let mut prices = vector::empty<u128>();
        
        let start_bin = if (pool.active_bin_id >= range) {
            pool.active_bin_id - range
        } else {
            0
        };
        let end_bin = pool.active_bin_id + range;

        let mut current_bin = start_bin;
        while (current_bin <= end_bin) {
            vector::push_back(&mut bin_ids, current_bin);
            
            if (table::contains(&pool.bins, current_bin)) {
                let bin = table::borrow(&pool.bins, current_bin);
                vector::push_back(&mut liquidity_a_vec, bin.liquidity_a);
                vector::push_back(&mut liquidity_b_vec, bin.liquidity_b);
                vector::push_back(&mut prices, bin.price);
            } else {
                let price = bin_math::calculate_bin_price(current_bin, pool.bin_step);
                vector::push_back(&mut liquidity_a_vec, 0);
                vector::push_back(&mut liquidity_b_vec, 0);
                vector::push_back(&mut prices, price);
            };
            current_bin = current_bin + 1;
        };

        (bin_ids, liquidity_a_vec, liquidity_b_vec, prices)
    }

    /// Check if bin exists and has liquidity
    public fun bin_has_liquidity<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        bin_id: u32
    ): bool {
        if (!table::contains(&pool.bins, bin_id)) return false;
        
        let bin = table::borrow(&pool.bins, bin_id);
        bin.liquidity_a > 0 || bin.liquidity_b > 0
    }

    /// Get pool statistics for analytics
    public fun get_pool_stats<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>
    ): (u64, u64, u64, u64, u32) {
        let active_bins = count_active_bins(pool);
        (
            pool.total_swaps,
            pool.total_volume_a,
            pool.total_volume_b,
            pool.created_at,
            active_bins
        )
    }

    /// Count bins with liquidity
    fun count_active_bins<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): u32 {
        // Note: In a real implementation, you'd want to track this more efficiently
        // For now, this is a placeholder that returns 1 if active bin has liquidity
        if (table::contains(&pool.bins, pool.active_bin_id)) {
            let bin = table::borrow(&pool.bins, pool.active_bin_id);
            if (bin.liquidity_a > 0 || bin.liquidity_b > 0) 1 else 0
        } else {
            0
        }
    }

    // ==================== Helper Functions ====================

    /// Calculate absolute difference between two u128 values
    fun abs_diff_u128(a: u128, b: u128): u128 {
        if (a >= b) a - b else b - a
    }

    /// Update bin fees after collecting protocol fee
    public fun update_bin_fees_after_protocol_collection<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        protocol_fee_a: u64,
        protocol_fee_b: u64
    ) {
        if (table::contains(&pool.bins, bin_id)) {
            let bin = table::borrow_mut(&mut pool.bins, bin_id);
            
            // Adjust fee growth to account for protocol fee collection
            if (bin.total_shares > 0) {
                let fee_reduction_a = (protocol_fee_a as u128) * 1000000000000000000u128 / (bin.total_shares as u128);
                let fee_reduction_b = (protocol_fee_b as u128) * 1000000000000000000u128 / (bin.total_shares as u128);
                
                bin.fee_growth_a = if (bin.fee_growth_a >= fee_reduction_a) {
                    bin.fee_growth_a - fee_reduction_a
                } else {
                    0
                };
                
                bin.fee_growth_b = if (bin.fee_growth_b >= fee_reduction_b) {
                    bin.fee_growth_b - fee_reduction_b
                } else {
                    0
                };
            };
        };
    }

    // ==================== Events ====================

    public struct PoolCreated has copy, drop {
        pool_id: ID,
        bin_step: u16,
        initial_bin_id: u32,
        initial_price: u128,
        creator: address,
        timestamp: u64,
    }

    public struct SwapExecuted has copy, drop {
        pool_id: ID,
        user: address,
        amount_in: u64,
        amount_out: u64,
        zero_for_one: bool,
        bins_crossed: u32,
        fee_amount: u64,
        protocol_fee: u64,
        start_bin_id: u32,
        final_bin_id: u32,
        price_impact: u128,
    }

    public struct LiquidityAdded has copy, drop {
        pool_id: ID,
        bin_id: u32,
        user: address,
        amount_a: u64,
        amount_b: u64,
        shares_minted: u64,
        timestamp: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: ID,
        bin_id: u32,
        user: address,
        amount_a: u64,
        amount_b: u64,
        shares_burned: u64,
        fee_a: u64,
        fee_b: u64,
        timestamp: u64,
    }

    public struct BaseFeeFactorUpdated has copy, drop {
        pool_id: ID,
        old_factor: u16,
        new_factor: u16,
        admin: address,
    }

    public struct PoolStatusChanged has copy, drop {
        pool_id: ID,
        is_active: bool,
        admin: address,
    }

    public struct VolatilityReset has copy, drop {
        pool_id: ID,
        admin: address,
        timestamp: u64,
    }

    // ==================== Test Helpers ====================

    #[test_only]
    /// Create test pool for unit testing
    public fun create_test_pool<CoinA, CoinB>(
        bin_step: u16,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        ctx: &mut TxContext
    ): DLMMPool<CoinA, CoinB> {
        let volatility_accumulator = volatility::new_volatility_accumulator(initial_bin_id, 0);
        
        DLMMPool {
            id: object::new(ctx),
            bin_step,
            active_bin_id: initial_bin_id,
            reserves_a: coin::into_balance(coin_a),
            reserves_b: coin::into_balance(coin_b),
            bins: table::new(ctx),
            volatility_accumulator,
            protocol_fee_rate: 300, // 3%
            base_factor: 100,       // 1%
            created_at: 0,
            total_swaps: 0,
            total_volume_a: 0,
            total_volume_b: 0,
            is_active: true,
        }
    }

    #[test_only]
    /// Get pool ID for testing
    public fun get_pool_id<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): object::ID {
        object::uid_to_inner(&pool.id)
    }

    #[test_only]
    /// Test simulation function (FIXED - simpler return)
    public fun test_simulate_swap<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        amount_in: u64,
        zero_for_one: bool
    ): (u64, u64, u32, u128) {
        simulate_swap(pool, amount_in, zero_for_one)
    }

    #[test_only]
    /// Initialize test bin with liquidity
    public fun initialize_test_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        liquidity_a: u64,
        liquidity_b: u64
    ) {
        let price = bin_math::calculate_bin_price(bin_id, pool.bin_step);
        let shares = constant_sum::calculate_liquidity_from_amounts(liquidity_a, liquidity_b, price);
        
        let bin = LiquidityBin {
            bin_id,
            liquidity_a,
            liquidity_b,
            total_shares: shares,
            fee_growth_a: 0,
            fee_growth_b: 0,
            is_active: bin_id == pool.active_bin_id,
            price,
            last_update_time: 0,
        };

        table::add(&mut pool.bins, bin_id, bin);
    }
}