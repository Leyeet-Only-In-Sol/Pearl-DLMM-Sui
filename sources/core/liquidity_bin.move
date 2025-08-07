module sui_dlmm::liquidity_bin {
    use sui::event;
    
    // Import our math modules
    use sui_dlmm::bin_math;
    use sui_dlmm::constant_sum;
    use sui_dlmm::fee_math;

    // Error codes (cleaned up - removed unused ones)
    const EINSUFFICIENT_LIQUIDITY: u64 = 2;
    const EZERO_SHARES: u64 = 3;
    const EINVALID_COMPOSITION: u64 = 4;

    /// Individual liquidity bin implementing constant sum formula: P*x + y = L
    /// This is the MAIN LiquidityBin struct that replaces the one in dlmm_pool
    public struct LiquidityBin has store, copy, drop {
        bin_id: u32,                    // Unique bin identifier
        liquidity_a: u64,               // Token A reserves in this bin
        liquidity_b: u64,               // Token B reserves in this bin
        total_shares: u64,              // Total LP shares for this bin
        fee_growth_a: u128,             // Accumulated fees per share for token A (scaled by 1e18)
        fee_growth_b: u128,             // Accumulated fees per share for token B (scaled by 1e18)
        is_active: bool,                // Whether this is the current active bin
        price: u128,                    // Cached bin price (scaled by 2^64)
        last_update_time: u64,          // Last time bin was updated (milliseconds)
    }

    /// Bin position for individual liquidity provider
    public struct BinPosition has store {
        shares: u64,                         // LP shares in this bin
        fee_growth_inside_last_a: u128,      // Last recorded fee growth for token A
        fee_growth_inside_last_b: u128,      // Last recorded fee growth for token B
        liquidity_a: u64,                    // Cached liquidity A (for efficiency)
        liquidity_b: u64,                    // Cached liquidity B (for efficiency)
        weight: u64,                         // Weight in position distribution
        last_update_time: u64,               // Last time position was updated
    }

    /// Result of liquidity operations
    public struct LiquidityResult has drop {
        shares_delta: u64,              // Change in shares (+ for add, - for remove)
        amount_a_delta: u64,            // Change in token A amount
        amount_b_delta: u64,            // Change in token B amount
        fees_a: u64,                    // Accumulated fees in token A
        fees_b: u64,                    // Accumulated fees in token B
    }

    /// Swap result within a single bin
    public struct BinSwapResult has drop {
        amount_out: u64,                // Amount of output tokens
        amount_in_consumed: u64,        // Amount of input tokens actually consumed
        fee_amount: u64,                // Fee charged for this portion of swap
        bin_exhausted: bool,            // Whether bin is exhausted in swap direction
        new_liquidity_a: u64,           // New liquidity A after swap
        new_liquidity_b: u64,           // New liquidity B after swap
    }

    // ==================== Bin Creation & Initialization ====================

    /// Create a new empty liquidity bin
    public fun create_bin(
        bin_id: u32,
        bin_step: u16,
        current_time_ms: u64
    ): LiquidityBin {
        let price = bin_math::calculate_bin_price(bin_id, bin_step);
        
        LiquidityBin {
            bin_id,
            liquidity_a: 0,
            liquidity_b: 0,
            total_shares: 0,
            fee_growth_a: 0,
            fee_growth_b: 0,
            is_active: false,
            price,
            last_update_time: current_time_ms,
        }
    }

    /// Initialize bin with initial liquidity
    public fun initialize_bin_with_liquidity(
        bin_id: u32,
        bin_step: u16,
        initial_liquidity_a: u64,
        initial_liquidity_b: u64,
        current_time_ms: u64
    ): LiquidityBin {
        let price = bin_math::calculate_bin_price(bin_id, bin_step);
        
        // Calculate initial shares using constant sum formula
        let initial_shares = constant_sum::calculate_liquidity_from_amounts(
            initial_liquidity_a,
            initial_liquidity_b,
            price
        );

        LiquidityBin {
            bin_id,
            liquidity_a: initial_liquidity_a,
            liquidity_b: initial_liquidity_b,
            total_shares: initial_shares,
            fee_growth_a: 0,
            fee_growth_b: 0,
            is_active: false,
            price,
            last_update_time: current_time_ms,
        }
    }

    /// Clone bin for operations that need original state
    public fun copy_bin(bin: &LiquidityBin): LiquidityBin {
        *bin
    }

    // ==================== Liquidity Management ====================

    /// Add liquidity to bin and return shares minted
    public fun add_liquidity_to_bin(
        bin: &mut LiquidityBin,
        amount_a: u64,
        amount_b: u64,
        current_time_ms: u64
    ): LiquidityResult {
        // Update bin timestamp
        bin.last_update_time = current_time_ms;

        // Calculate shares to mint
        let shares_to_mint = if (bin.total_shares == 0) {
            // First liquidity provider - mint shares equal to liquidity value
            constant_sum::calculate_liquidity_from_amounts(amount_a, amount_b, bin.price)
        } else {
            // Calculate proportional shares based on existing liquidity
            calculate_proportional_shares(bin, amount_a, amount_b)
        };

        // Update bin state
        bin.liquidity_a = bin.liquidity_a + amount_a;
        bin.liquidity_b = bin.liquidity_b + amount_b;
        bin.total_shares = bin.total_shares + shares_to_mint;

        // Emit liquidity added event
        event::emit(LiquidityAddedToBin {
            bin_id: bin.bin_id,
            amount_a,
            amount_b,
            shares_minted: shares_to_mint,
            total_liquidity_a: bin.liquidity_a,
            total_liquidity_b: bin.liquidity_b,
            total_shares: bin.total_shares,
            timestamp: current_time_ms,
        });

        LiquidityResult {
            shares_delta: shares_to_mint,
            amount_a_delta: amount_a,
            amount_b_delta: amount_b,
            fees_a: 0,
            fees_b: 0,
        }
    }

    /// Remove liquidity from bin and return tokens
    public fun remove_liquidity_from_bin(
        bin: &mut LiquidityBin,
        shares_to_burn: u64,
        current_time_ms: u64
    ): LiquidityResult {
        assert!(shares_to_burn <= bin.total_shares, EINSUFFICIENT_LIQUIDITY);
        assert!(shares_to_burn > 0, EZERO_SHARES);

        // Update bin timestamp
        bin.last_update_time = current_time_ms;

        // Calculate proportional amounts to return
        let amount_a = calculate_proportional_amount(bin.liquidity_a, shares_to_burn, bin.total_shares);
        let amount_b = calculate_proportional_amount(bin.liquidity_b, shares_to_burn, bin.total_shares);

        // Update bin state
        bin.liquidity_a = bin.liquidity_a - amount_a;
        bin.liquidity_b = bin.liquidity_b - amount_b;
        bin.total_shares = bin.total_shares - shares_to_burn;

        // Emit liquidity removed event
        event::emit(LiquidityRemovedFromBin {
            bin_id: bin.bin_id,
            amount_a,
            amount_b,
            shares_burned: shares_to_burn,
            total_liquidity_a: bin.liquidity_a,
            total_liquidity_b: bin.liquidity_b,
            total_shares: bin.total_shares,
            timestamp: current_time_ms,
        });

        LiquidityResult {
            shares_delta: shares_to_burn,
            amount_a_delta: amount_a,
            amount_b_delta: amount_b,
            fees_a: 0,
            fees_b: 0,
        }
    }

    /// Calculate proportional shares for new liquidity
    fun calculate_proportional_shares(
        bin: &LiquidityBin,
        amount_a: u64,
        amount_b: u64
    ): u64 {
        // Calculate liquidity value of new amounts
        let new_liquidity = constant_sum::calculate_liquidity_from_amounts(
            amount_a, amount_b, bin.price
        );
        
        // Calculate existing liquidity value
        let existing_liquidity = constant_sum::calculate_liquidity_from_amounts(
            bin.liquidity_a, bin.liquidity_b, bin.price
        );

        if (existing_liquidity == 0) {
            new_liquidity
        } else {
            // Proportional shares: new_liquidity * total_shares / existing_liquidity
            ((new_liquidity as u128) * (bin.total_shares as u128) / (existing_liquidity as u128)) as u64
        }
    }

    /// Calculate proportional amount for share redemption
    fun calculate_proportional_amount(total_amount: u64, shares: u64, total_shares: u64): u64 {
        if (total_shares == 0) return 0;
        ((total_amount as u128) * (shares as u128) / (total_shares as u128)) as u64
    }

    // ==================== Swap Operations ====================

    /// Execute swap within this bin using zero-slippage constant sum
    public fun swap_within_bin(
        bin: &mut LiquidityBin,
        amount_in: u64,
        zero_for_one: bool,
        fee_rate: u64,
        current_time_ms: u64
    ): BinSwapResult {
        // Update bin timestamp
        bin.last_update_time = current_time_ms;

        // Calculate maximum swap amount possible in this bin
        let max_swap_amount = constant_sum::calculate_max_swap_amount(
            bin.liquidity_a, bin.liquidity_b, zero_for_one, bin.price
        );

        // Determine actual amount to swap (limited by bin capacity)
        let amount_to_swap = if (amount_in <= max_swap_amount) {
            amount_in
        } else {
            max_swap_amount
        };

        // Execute zero-slippage swap using constant sum
        let (amount_out, bin_exhausted) = constant_sum::swap_within_bin(
            bin.liquidity_a,
            bin.liquidity_b,
            amount_to_swap,
            zero_for_one,
            bin.price
        );

        // Calculate fee on input amount
        let fee_amount = fee_math::calculate_fee_amount(amount_to_swap, fee_rate);

        // Update bin reserves after swap
        let (new_liquidity_a, new_liquidity_b) = constant_sum::update_reserves_after_swap(
            bin.liquidity_a,
            bin.liquidity_b,
            amount_to_swap,
            amount_out,
            zero_for_one
        );

        bin.liquidity_a = new_liquidity_a;
        bin.liquidity_b = new_liquidity_b;

        // Distribute fees to liquidity providers
        add_fees_to_bin(bin, fee_amount, zero_for_one);

        // Emit swap event
        event::emit(SwapWithinBin {
            bin_id: bin.bin_id,
            amount_in: amount_to_swap,
            amount_out,
            fee_amount,
            zero_for_one,
            bin_exhausted,
            new_liquidity_a,
            new_liquidity_b,
            timestamp: current_time_ms,
        });

        BinSwapResult {
            amount_out,
            amount_in_consumed: amount_to_swap,
            fee_amount,
            bin_exhausted,
            new_liquidity_a,
            new_liquidity_b,
        }
    }

    /// Add trading fees to bin for LP distribution
    public fun add_fees_to_bin(bin: &mut LiquidityBin, fee_amount: u64, zero_for_one: bool) {
        if (bin.total_shares > 0 && fee_amount > 0) {
            // Convert fee to per-share growth (scaled by 1e18)
            let fee_per_share = ((fee_amount as u128) * 1000000000000000000u128) / (bin.total_shares as u128);
            
            if (zero_for_one) {
                bin.fee_growth_a = bin.fee_growth_a + fee_per_share;
            } else {
                bin.fee_growth_b = bin.fee_growth_b + fee_per_share;
            };
        };
    }

    // ==================== Position Management ====================

    /// Create new bin position
    public fun create_bin_position(
        shares: u64,
        fee_growth_a: u128,
        fee_growth_b: u128,
        liquidity_a: u64,
        liquidity_b: u64,
        weight: u64,
        current_time_ms: u64
    ): BinPosition {
        BinPosition {
            shares,
            fee_growth_inside_last_a: fee_growth_a,
            fee_growth_inside_last_b: fee_growth_b,
            liquidity_a,
            liquidity_b,
            weight,
            last_update_time: current_time_ms,
        }
    }

    /// Calculate accumulated fees for a position in this bin
    public fun calculate_position_fees(
        bin: &LiquidityBin,
        position: &BinPosition
    ): (u64, u64) {
        if (position.shares == 0) return (0, 0);

        // Calculate fee growth since last collection
        let fee_growth_diff_a = bin.fee_growth_a - position.fee_growth_inside_last_a;
        let fee_growth_diff_b = bin.fee_growth_b - position.fee_growth_inside_last_b;

        // Calculate accumulated fees
        let fees_a = ((position.shares as u128) * fee_growth_diff_a / 1000000000000000000u128) as u64;
        let fees_b = ((position.shares as u128) * fee_growth_diff_b / 1000000000000000000u128) as u64;

        (fees_a, fees_b)
    }

    /// Update position after fee collection
    public fun update_position_after_fee_collection(
        position: &mut BinPosition,
        bin: &LiquidityBin,
        current_time_ms: u64
    ) {
        position.fee_growth_inside_last_a = bin.fee_growth_a;
        position.fee_growth_inside_last_b = bin.fee_growth_b;
        position.last_update_time = current_time_ms;
    }

    /// Update position shares and liquidity
    public fun update_position_shares(
        position: &mut BinPosition,
        new_shares: u64,
        new_liquidity_a: u64,
        new_liquidity_b: u64,
        current_time_ms: u64
    ) {
        position.shares = new_shares;
        position.liquidity_a = new_liquidity_a;
        position.liquidity_b = new_liquidity_b;
        position.last_update_time = current_time_ms;
    }

    // ==================== Bin Active State Management ====================

    /// Set bin active status
    public fun set_bin_active(bin: &mut LiquidityBin, active: bool) {
        bin.is_active = active;
    }

    /// Check if bin is active
    public fun is_bin_active(bin: &LiquidityBin): bool {
        bin.is_active
    }

    // ==================== Bin State Queries ====================

    /// Check if bin is empty
    public fun is_bin_empty(bin: &LiquidityBin): bool {
        bin.liquidity_a == 0 && bin.liquidity_b == 0
    }

    /// Check if bin has liquidity in specific direction
    public fun has_liquidity_for_swap(bin: &LiquidityBin, zero_for_one: bool): bool {
        if (zero_for_one) {
            bin.liquidity_b > 0  // Need B tokens to give out
        } else {
            bin.liquidity_a > 0  // Need A tokens to give out
        }
    }

    /// Get bin composition (percentage of token B)
    public fun get_bin_composition(bin: &LiquidityBin): u8 {
        constant_sum::calculate_composition_percentage(
            bin.liquidity_a,
            bin.liquidity_b,
            bin.price
        )
    }

    /// Calculate current bin utilization rate
    public fun calculate_bin_utilization(bin: &LiquidityBin): u8 {
        let total_possible_liquidity = bin.liquidity_a + bin.liquidity_b;
        if (total_possible_liquidity == 0) return 0;

        let current_liquidity = constant_sum::calculate_liquidity_from_amounts(
            bin.liquidity_a, bin.liquidity_b, bin.price
        );
        
        ((current_liquidity * 100) / total_possible_liquidity) as u8
    }

    /// Check if bin price needs recalculation
    public fun should_update_price(bin: &LiquidityBin, bin_step: u16): bool {
        let expected_price = bin_math::calculate_bin_price(bin.bin_id, bin_step);
        // Allow 0.1% tolerance
        let diff = if (bin.price >= expected_price) {
            bin.price - expected_price
        } else {
            expected_price - bin.price
        };
        
        diff > expected_price / 1000
    }

    /// Update cached bin price
    public fun update_bin_price(bin: &mut LiquidityBin, bin_step: u16) {
        bin.price = bin_math::calculate_bin_price(bin.bin_id, bin_step);
    }

    // ==================== Bin Information Getters ====================

    /// Get basic bin information
    public fun get_bin_info(bin: &LiquidityBin): (u32, u64, u64, u64, u128, u64) {
        (
            bin.bin_id,
            bin.liquidity_a,
            bin.liquidity_b,
            bin.total_shares,
            bin.price,
            bin.last_update_time
        )
    }

    /// Get bin fee growth information
    public fun get_bin_fee_growth(bin: &LiquidityBin): (u128, u128) {
        (bin.fee_growth_a, bin.fee_growth_b)
    }

    /// Get position information
    public fun get_position_info(position: &BinPosition): (u64, u64, u64, u64) {
        (
            position.shares,
            position.liquidity_a,
            position.liquidity_b,
            position.last_update_time
        )
    }

    /// Get bin liquidity info for external queries
    public fun get_bin_liquidity_info(bin: &LiquidityBin): (u64, u64, u64, u8) {
        let composition = get_bin_composition(bin);
        (
            bin.liquidity_a,
            bin.liquidity_b,
            bin.total_shares,
            composition
        )
    }

    // ==================== Advanced Bin Operations ====================

    /// Rebalance bin to optimal composition
    public fun rebalance_bin_composition(
        bin: &mut LiquidityBin,
        target_composition: u8,
        current_time_ms: u64
    ): (u64, u64) {
        assert!(target_composition <= 100, EINVALID_COMPOSITION);
        
        let current_composition = get_bin_composition(bin);
        if (current_composition == target_composition) {
            return (0, 0) // No rebalancing needed
        };

        // Calculate total liquidity value
        let total_liquidity = constant_sum::calculate_liquidity_from_amounts(
            bin.liquidity_a, bin.liquidity_b, bin.price
        );

        // Calculate target amounts
        let (target_a, target_b) = constant_sum::calculate_amounts_from_liquidity(
            total_liquidity, bin.price, target_composition
        );

        // Calculate deltas
        let delta_a = if (target_a >= bin.liquidity_a) {
            target_a - bin.liquidity_a
        } else {
            0
        };
        
        let delta_b = if (target_b >= bin.liquidity_b) {
            target_b - bin.liquidity_b
        } else {
            0
        };

        // Update bin (this is a theoretical rebalancing)
        bin.last_update_time = current_time_ms;

        (delta_a, delta_b)
    }

    /// Get bin statistics for analytics
    public fun get_bin_statistics(bin: &LiquidityBin): (u8, u64, u64, u128, u128) {
        let _utilization = calculate_bin_utilization(bin); // Prefix with _ to avoid warning
        let composition = get_bin_composition(bin);
        
        (
            composition,                           // Token B percentage
            bin.total_shares,                     // Total LP shares
            bin.last_update_time,                 // Last activity
            bin.fee_growth_a + bin.fee_growth_b,  // Total fee growth
            bin.price                             // Current price
        )
    }

    // ==================== Events ====================

    public struct LiquidityAddedToBin has copy, drop {
        bin_id: u32,
        amount_a: u64,
        amount_b: u64,
        shares_minted: u64,
        total_liquidity_a: u64,
        total_liquidity_b: u64,
        total_shares: u64,
        timestamp: u64,
    }

    public struct LiquidityRemovedFromBin has copy, drop {
        bin_id: u32,
        amount_a: u64,
        amount_b: u64,
        shares_burned: u64,
        total_liquidity_a: u64,
        total_liquidity_b: u64,
        total_shares: u64,
        timestamp: u64,
    }

    public struct SwapWithinBin has copy, drop {
        bin_id: u32,
        amount_in: u64,
        amount_out: u64,
        fee_amount: u64,
        zero_for_one: bool,
        bin_exhausted: bool,
        new_liquidity_a: u64,
        new_liquidity_b: u64,
        timestamp: u64,
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    /// Create test bin with specific liquidity
    public fun create_test_bin(
        bin_id: u32,
        liquidity_a: u64,
        liquidity_b: u64,
        bin_step: u16
    ): LiquidityBin {
        initialize_bin_with_liquidity(bin_id, bin_step, liquidity_a, liquidity_b, 0)
    }

    #[test_only]
    /// Create test position
    public fun create_test_position(shares: u64): BinPosition {
        BinPosition {
            shares,
            fee_growth_inside_last_a: 0,
            fee_growth_inside_last_b: 0,
            liquidity_a: 0,
            liquidity_b: 0,
            weight: 1000,            // <- ADD THIS LINE: Default weight for testing
            last_update_time: 0,
        }
    }

    #[test_only]
    /// Verify bin invariants for testing
    public fun verify_bin_invariants(bin: &LiquidityBin): bool {
        // Check constant sum invariant
        let calculated_liquidity = constant_sum::calculate_liquidity_from_amounts(
            bin.liquidity_a, bin.liquidity_b, bin.price
        );
        
        // Allow 1% tolerance for rounding
        let tolerance = calculated_liquidity / 100 + 1;
        let diff = if (calculated_liquidity >= bin.total_shares) {
            calculated_liquidity - bin.total_shares
        } else {
            bin.total_shares - calculated_liquidity
        };
        
        diff <= tolerance
    }

    #[test_only]
    /// Get bin ID for testing
    public fun get_bin_id(bin: &LiquidityBin): u32 {
        bin.bin_id
    }

    #[test_only]
    /// Get position shares for testing
    public fun get_position_shares(position: &BinPosition): u64 {
        position.shares
    }

    // ==================== Result Getters (for cross-module access) ====================

    /// Get swap result details
    public fun get_swap_result_details(result: &BinSwapResult): (u64, u64, u64, bool) {
        (
            result.amount_out,
            result.amount_in_consumed,
            result.fee_amount,
            result.bin_exhausted
        )
    }

    /// Get liquidity result details
    public fun get_liquidity_result_details(result: &LiquidityResult): (u64, u64, u64, u64, u64) {
        (
            result.shares_delta,
            result.amount_a_delta,
            result.amount_b_delta,
            result.fees_a,
            result.fees_b
        )
    }

    /// Extract shares delta from liquidity result
    public fun extract_shares_delta(result: &LiquidityResult): u64 {
        result.shares_delta
    }

    /// Extract amount deltas from liquidity result
    public fun extract_amount_deltas(result: &LiquidityResult): (u64, u64) {
        (result.amount_a_delta, result.amount_b_delta)
    }

    /// Extract fee amounts from liquidity result
    public fun extract_fees(result: &LiquidityResult): (u64, u64) {
        (result.fees_a, result.fees_b)
    }

    /// Check if bin was exhausted in swap
    public fun is_bin_exhausted(result: &BinSwapResult): bool {
        result.bin_exhausted
    }

    /// Get amount out from swap result
    public fun get_amount_out(result: &BinSwapResult): u64 {
        result.amount_out
    }

    /// Get amount consumed from swap result
    public fun get_amount_consumed(result: &BinSwapResult): u64 {
        result.amount_in_consumed
    }

    /// Get fee amount from swap result
    public fun get_fee_amount(result: &BinSwapResult): u64 {
        result.fee_amount
    }
}