module sui_dlmm::dlmm_pool {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    
    // Import our modules
    use sui_dlmm::bin_math;
    use sui_dlmm::constant_sum;
    use sui_dlmm::fee_math;
    use sui_dlmm::volatility::{Self, VolatilityAccumulator};
    use sui_dlmm::liquidity_bin::{Self, LiquidityBin}; // Import the LiquidityBin from bin module

    // Error codes
    const EINVALID_BIN_STEP: u64 = 1;
    const EINVALID_PRICE: u64 = 2;
    const EINSUFFICIENT_LIQUIDITY: u64 = 3;
    const EMIN_AMOUNT_OUT: u64 = 7;
    const EINVALID_AMOUNT: u64 = 8;
    const EPOOL_INACTIVE: u64 = 9;

    /// Main DLMM pool struct - Uses LiquidityBin from bin module
    public struct DLMMPool<phantom CoinA, phantom CoinB> has key {
        id: sui::object::UID,
        bin_step: u16,                          // Basis points between bins
        active_bin_id: u32,                     // Current active bin ID where trades happen
        reserves_a: Balance<CoinA>,             // Total reserves of token A
        reserves_b: Balance<CoinB>,             // Total reserves of token B
        bins: Table<u32, LiquidityBin>,         // bin_id -> LiquidityBin mapping (from bin module)
        volatility_accumulator: VolatilityAccumulator, // Tracks market volatility for dynamic fees
        protocol_fee_rate: u16,                 // Protocol fee rate in basis points
        base_factor: u16,                       // Base factor for fee calculation
        created_at: u64,                        // Pool creation timestamp
        total_swaps: u64,                       // Total number of swaps executed
        total_volume_a: u64,                    // Cumulative volume in token A
        total_volume_b: u64,                    // Cumulative volume in token B
        is_active: bool,                        // Pool active status (circuit breaker)
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
        ctx: &mut sui::tx_context::TxContext
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
            id: sui::object::new(ctx),
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

        // Initialize active bin with provided liquidity using bin module
        if (balance::value(&pool.reserves_a) > 0 || balance::value(&pool.reserves_b) > 0) {
            initialize_active_bin(&mut pool, current_time);
        };

        // Emit pool creation event
        event::emit(PoolCreated {
            pool_id: sui::object::uid_to_inner(&pool.id),
            bin_step,
            initial_bin_id,
            initial_price,
            creator: sui::tx_context::sender(ctx),
            timestamp: current_time,
        });

        pool
    }

    /// Initialize the active bin with initial liquidity using bin module
    fun initialize_active_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        current_time: u64
    ) {
        let reserve_a = balance::value(&pool.reserves_a);
        let reserve_b = balance::value(&pool.reserves_b);

        // Use bin module to create initialized bin
        let mut bin = liquidity_bin::initialize_bin_with_liquidity(
            pool.active_bin_id,
            pool.bin_step,
            reserve_a,
            reserve_b,
            current_time
        );

        // Set as active bin
        liquidity_bin::set_bin_active(&mut bin, true);
        table::add(&mut pool.bins, pool.active_bin_id, bin);
    }

    /// Share the pool object (entry function for deployment)
    public entry fun share_pool<CoinA, CoinB>(pool: DLMMPool<CoinA, CoinB>) {
        sui::transfer::share_object(pool);
    }

    // ==================== Core Swap Implementation ====================

    /// Execute swap with zero slippage within bins and dynamic fees across bins
    public fun swap<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        coin_in: Coin<CoinA>,
        min_amount_out: u64,
        zero_for_one: bool,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
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
            pool_id: sui::object::uid_to_inner(&pool.id),
            user: sui::tx_context::sender(ctx),
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

    /// Execute multi-bin swap with dynamic fee calculation - Using bin module
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
            
            // Get or create current bin using bin module
            if (!table::contains(&pool.bins, current_bin_id)) {
                let empty_bin = liquidity_bin::create_bin(current_bin_id, pool.bin_step, current_time);
                table::add(&mut pool.bins, current_bin_id, empty_bin);
            };

            let bin = table::borrow_mut(&mut pool.bins, current_bin_id);
            
            // Skip empty bins using bin module functions
            if (liquidity_bin::is_bin_empty(bin)) {
                current_bin_id = bin_math::get_next_bin_id(current_bin_id, zero_for_one);
                bins_crossed = bins_crossed + 1;
                continue
            };

            // Check if bin has liquidity for this swap direction
            if (!liquidity_bin::has_liquidity_for_swap(bin, zero_for_one)) {
                current_bin_id = bin_math::get_next_bin_id(current_bin_id, zero_for_one);
                bins_crossed = bins_crossed + 1;
                continue
            };

            // Calculate dynamic fee for this portion
            let current_fee_rate = fee_math::calculate_dynamic_fee(
                pool.base_factor,
                pool.bin_step,
                bins_crossed
            );

            // Execute swap within this bin using bin module
            let bin_swap_result = liquidity_bin::swap_within_bin(
                bin,
                remaining_amount_in,
                zero_for_one,
                current_fee_rate,
                current_time
            );

            // Extract results using getter functions
            let amount_out = liquidity_bin::get_amount_out(&bin_swap_result);
            let amount_consumed = liquidity_bin::get_amount_consumed(&bin_swap_result);
            let fee_amount = liquidity_bin::get_fee_amount(&bin_swap_result);
            let bin_exhausted = liquidity_bin::is_bin_exhausted(&bin_swap_result);

            // Update running totals
            remaining_amount_in = remaining_amount_in - amount_consumed;
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

    /// Update which bin is currently active
    fun update_active_bin<CoinA, CoinB>(pool: &mut DLMMPool<CoinA, CoinB>, new_active_bin_id: u32) {
        // Deactivate old active bin
        if (table::contains(&pool.bins, pool.active_bin_id)) {
            let old_bin = table::borrow_mut(&mut pool.bins, pool.active_bin_id);
            liquidity_bin::set_bin_active(old_bin, false);
        };

        pool.active_bin_id = new_active_bin_id;

        // Activate new bin
        if (table::contains(&pool.bins, new_active_bin_id)) {
            let new_bin = table::borrow_mut(&mut pool.bins, new_active_bin_id);
            liquidity_bin::set_bin_active(new_bin, true);
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

    /// Add liquidity to a specific bin using bin module
    public fun add_liquidity_to_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): u64 { // Returns LP shares minted
        assert!(pool.is_active, EPOOL_INACTIVE);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        let current_time = clock::timestamp_ms(clock);
        
        // Validate at least one token is provided
        assert!(amount_a > 0 || amount_b > 0, EINVALID_AMOUNT);

        // Get or create bin using bin module
        if (!table::contains(&pool.bins, bin_id)) {
            let new_bin = liquidity_bin::create_bin(bin_id, pool.bin_step, current_time);
            table::add(&mut pool.bins, bin_id, new_bin);
        };

        let bin = table::borrow_mut(&mut pool.bins, bin_id);
        
        // Add liquidity using bin module
        let liquidity_result = liquidity_bin::add_liquidity_to_bin(
            bin,
            amount_a,
            amount_b,
            current_time
        );

        // Extract shares minted using getter function
        let shares_minted = liquidity_bin::extract_shares_delta(&liquidity_result);

        // Update pool reserves
        balance::join(&mut pool.reserves_a, coin::into_balance(coin_a));
        balance::join(&mut pool.reserves_b, coin::into_balance(coin_b));

        // Emit pool-level liquidity added event
        event::emit(LiquidityAdded {
            pool_id: sui::object::uid_to_inner(&pool.id),
            bin_id,
            user: sui::tx_context::sender(ctx),
            amount_a,
            amount_b,
            shares_minted,
            timestamp: current_time,
        });

        shares_minted
    }

    /// Remove liquidity from a specific bin using bin module
    public fun remove_liquidity_from_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        shares_to_burn: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<CoinA>, Coin<CoinB>, u64, u64) { // Returns (coin_a, coin_b, fee_a, fee_b)
        assert!(table::contains(&pool.bins, bin_id), EINSUFFICIENT_LIQUIDITY);
        assert!(shares_to_burn > 0, EINVALID_AMOUNT);
        
        let bin = table::borrow_mut(&mut pool.bins, bin_id);
        let current_time = clock::timestamp_ms(clock);

        // Remove liquidity using bin module
        let liquidity_result = liquidity_bin::remove_liquidity_from_bin(
            bin,
            shares_to_burn,
            current_time
        );

        // Extract amounts using getter functions
        let (amount_a, amount_b) = liquidity_bin::extract_amount_deltas(&liquidity_result);
        let shares_burned = liquidity_bin::extract_shares_delta(&liquidity_result);

        // Calculate accumulated fees using bin module
        let (fee_a, fee_b) = liquidity_bin::extract_fees(&liquidity_result);

        // Extract coins from pool reserves
        let balance_a = balance::split(&mut pool.reserves_a, amount_a + fee_a);
        let balance_b = balance::split(&mut pool.reserves_b, amount_b + fee_b);

        // Emit pool-level liquidity removal event
        event::emit(LiquidityRemoved {
            pool_id: sui::object::uid_to_inner(&pool.id),
            bin_id,
            user: sui::tx_context::sender(ctx),
            amount_a,
            amount_b,
            shares_burned,
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

    // ==================== View Functions ====================

    /// Get pool ID (needed by position module)
    public fun get_pool_id<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): sui::object::ID {
        sui::object::uid_to_inner(&pool.id)
    }

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

    /// Get detailed bin information using bin module
    public fun get_bin_info<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        bin_id: u32
    ): (bool, u64, u64, u64, u128, u128, u128) { // (exists, liquidity_a, liquidity_b, shares, price, fee_growth_a, fee_growth_b)
        if (table::contains(&pool.bins, bin_id)) {
            let bin = table::borrow(&pool.bins, bin_id);
            let (_, liquidity_a, liquidity_b, total_shares, price, _) = liquidity_bin::get_bin_info(bin);
            let (fee_growth_a, fee_growth_b) = liquidity_bin::get_bin_fee_growth(bin);
            (
                true,                   // exists
                liquidity_a,
                liquidity_b,
                total_shares,
                price,
                fee_growth_a,
                fee_growth_b
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

    /// Quote swap without executing (simulation) using bin module
    public fun quote_swap<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        amount_in: u64,
        zero_for_one: bool
    ): (u64, u64, u32, u128) { // (amount_out, total_fee, bins_crossed, price_impact)
        simulate_swap(pool, amount_in, zero_for_one)
    }

    /// Simulate swap for quotation using bin module (read-only, no state changes)
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
                
                // Use bin module to check liquidity
                if (!liquidity_bin::is_bin_empty(bin) && 
                    liquidity_bin::has_liquidity_for_swap(bin, zero_for_one)) {
                    
                    let (_, liquidity_a, liquidity_b, _, price, _) = liquidity_bin::get_bin_info(bin);
                    
                    let max_swap_amount = constant_sum::calculate_max_swap_amount(
                        liquidity_a,
                        liquidity_b,
                        zero_for_one,
                        price
                    );

                    if (max_swap_amount > 0) {
                        let amount_to_swap = if (remaining_amount_in <= max_swap_amount) {
                            remaining_amount_in
                        } else {
                            max_swap_amount
                        };

                        let (amount_out, bin_exhausted) = constant_sum::swap_within_bin(
                            liquidity_a,
                            liquidity_b,
                            amount_to_swap,
                            zero_for_one,
                            price
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
        ctx: &sui::tx_context::TxContext
    ) {
        let old_factor = pool.base_factor;
        pool.base_factor = new_base_factor;
        
        event::emit(BaseFeeFactorUpdated {
            pool_id: sui::object::uid_to_inner(&pool.id),
            old_factor,
            new_factor: new_base_factor,
            admin: sui::tx_context::sender(ctx),
        });
    }

    /// Emergency pause/unpause pool (circuit breaker)
    public fun set_pool_active_status<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        active: bool,
        ctx: &sui::tx_context::TxContext
    ) {
        pool.is_active = active;
        
        event::emit(PoolStatusChanged {
            pool_id: sui::object::uid_to_inner(&pool.id),
            is_active: active,
            admin: sui::tx_context::sender(ctx),
        });
    }

    /// Force update volatility accumulator (governance function)
    public fun reset_volatility<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &sui::tx_context::TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        pool.volatility_accumulator = volatility::reset_volatility_accumulator(
            pool.volatility_accumulator,
            current_time
        );
        
        event::emit(VolatilityReset {
            pool_id: sui::object::uid_to_inner(&pool.id),
            admin: sui::tx_context::sender(ctx),
            timestamp: current_time,
        });
    }

    // ==================== Utility Functions ====================

    /// Get total liquidity in the pool across all bins
    public fun get_total_liquidity<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.reserves_a), balance::value(&pool.reserves_b))
    }

    /// Get bins around active bin using bin module
    public fun get_bins_around_active<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        range: u32 // Number of bins on each side
    ): (vector<u32>, vector<u64>, vector<u64>, vector<u128>) { // (bin_ids, liquidity_a_vec, liquidity_b_vec, prices)
        let mut bin_ids = std::vector::empty<u32>();
        let mut liquidity_a_vec = std::vector::empty<u64>();
        let mut liquidity_b_vec = std::vector::empty<u64>();
        let mut prices = std::vector::empty<u128>();
        
        let start_bin = if (pool.active_bin_id >= range) {
            pool.active_bin_id - range
        } else {
            0
        };
        let end_bin = pool.active_bin_id + range;

        let mut current_bin = start_bin;
        while (current_bin <= end_bin) {
            std::vector::push_back(&mut bin_ids, current_bin);
            
            if (table::contains(&pool.bins, current_bin)) {
                let bin = table::borrow(&pool.bins, current_bin);
                let (_, liquidity_a, liquidity_b, _, price, _) = liquidity_bin::get_bin_info(bin);
                std::vector::push_back(&mut liquidity_a_vec, liquidity_a);
                std::vector::push_back(&mut liquidity_b_vec, liquidity_b);
                std::vector::push_back(&mut prices, price);
            } else {
                let price = bin_math::calculate_bin_price(current_bin, pool.bin_step);
                std::vector::push_back(&mut liquidity_a_vec, 0);
                std::vector::push_back(&mut liquidity_b_vec, 0);
                std::vector::push_back(&mut prices, price);
            };
            current_bin = current_bin + 1;
        };

        (bin_ids, liquidity_a_vec, liquidity_b_vec, prices)
    }

    /// Check if bin exists and has liquidity using bin module
    public fun bin_has_liquidity<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        bin_id: u32
    ): bool {
        if (!table::contains(&pool.bins, bin_id)) return false;
        
        let bin = table::borrow(&pool.bins, bin_id);
        !liquidity_bin::is_bin_empty(bin)
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

    /// Count bins with liquidity using bin module
    fun count_active_bins<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): u32 {
        // For now, simple implementation checking just active bin
        if (table::contains(&pool.bins, pool.active_bin_id)) {
            let bin = table::borrow(&pool.bins, pool.active_bin_id);
            if (!liquidity_bin::is_bin_empty(bin)) 1 else 0
        } else {
            0
        }
    }

    // ==================== Helper Functions ====================

    /// Calculate absolute difference between two u128 values
    fun abs_diff_u128(a: u128, b: u128): u128 {
        if (a >= b) a - b else b - a
    }

    // ==================== Events ====================

    public struct PoolCreated has copy, drop {
        pool_id: sui::object::ID,
        bin_step: u16,
        initial_bin_id: u32,
        initial_price: u128,
        creator: address,
        timestamp: u64,
    }

    public struct SwapExecuted has copy, drop {
        pool_id: sui::object::ID,
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
        pool_id: sui::object::ID,
        bin_id: u32,
        user: address,
        amount_a: u64,
        amount_b: u64,
        shares_minted: u64,
        timestamp: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: sui::object::ID,
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
        pool_id: sui::object::ID,
        old_factor: u16,
        new_factor: u16,
        admin: address,
    }

    public struct PoolStatusChanged has copy, drop {
        pool_id: sui::object::ID,
        is_active: bool,
        admin: address,
    }

    public struct VolatilityReset has copy, drop {
        pool_id: sui::object::ID,
        admin: address,
        timestamp: u64,
    }

    // ==================== Test Helpers ====================

    #[test_only]
    /// Create test pool for unit testing using bin module
    public fun create_test_pool<CoinA, CoinB>(
        bin_step: u16,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        ctx: &mut sui::tx_context::TxContext
    ): DLMMPool<CoinA, CoinB> {
        let volatility_accumulator = volatility::new_volatility_accumulator(initial_bin_id, 0);
        
        DLMMPool {
            id: sui::object::new(ctx),
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
    /// Get pool ID for testing (renamed to avoid duplicate)
    public fun get_test_pool_id<CoinA, CoinB>(pool: &DLMMPool<CoinA, CoinB>): sui::object::ID {
        get_pool_id(pool)
    }

    #[test_only]
    /// Test simulation function
    public fun test_simulate_swap<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        amount_in: u64,
        zero_for_one: bool
    ): (u64, u64, u32, u128) {
        simulate_swap(pool, amount_in, zero_for_one)
    }

    #[test_only]
    /// Initialize test bin with liquidity using bin module
    public fun initialize_test_bin<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32,
        liquidity_a: u64,
        liquidity_b: u64
    ) {
        let test_bin = liquidity_bin::initialize_bin_with_liquidity(
            bin_id,
            pool.bin_step,
            liquidity_a,
            liquidity_b,
            0 // current_time for test
        );
        
        table::add(&mut pool.bins, bin_id, test_bin);
    }

    #[test_only]
    /// Get bin from pool for testing
    public fun get_test_bin<CoinA, CoinB>(
        pool: &DLMMPool<CoinA, CoinB>,
        bin_id: u32
    ): &LiquidityBin {
        table::borrow(&pool.bins, bin_id)
    }

    #[test_only]
    /// Get mutable bin from pool for testing
    public fun get_test_bin_mut<CoinA, CoinB>(
        pool: &mut DLMMPool<CoinA, CoinB>,
        bin_id: u32
    ): &mut LiquidityBin {
        table::borrow_mut(&mut pool.bins, bin_id)
    }
}