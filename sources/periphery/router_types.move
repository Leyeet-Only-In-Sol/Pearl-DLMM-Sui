#[allow(duplicate_alias)]
module sui_dlmm::router_types {
    use std::type_name::TypeName;
    use sui::object;

    // Error codes for router operations
    const EINVALID_PATH: u64 = 1;
    const EEMPTY_PATH: u64 = 2;
    #[allow(unused_const)]
    const EINVALID_AMOUNT: u64 = 3;
    #[allow(unused_const)]
    const ESLIPPAGE_EXCEEDED: u64 = 4;
    #[allow(unused_const)]
    const EINSUFFICIENT_LIQUIDITY: u64 = 5;

    // Constants for calculations
    const BASIS_POINTS_SCALE: u64 = 10000; // 100% in basis points
    const MAX_HOPS: u8 = 3; // Maximum hops in a swap path
    const MAX_PRICE_IMPACT: u128 = 1000; // 10% max price impact (in basis points)

    /// Represents a single hop in a swap path
    /// This is the building block of all routing operations
    public struct PathNode has copy, drop, store {
        pool_id: object::ID,            // Sui object ID of the DLMM pool
        token_in: TypeName,             // Input token type
        token_out: TypeName,            // Output token type
        bin_step: u16,                  // Bin step of the pool (25 = 0.25%)
        expected_fee: u64,              // Expected fee in basis points
        pool_reserves_in: u64,          // Input token reserves in pool
        pool_reserves_out: u64,         // Output token reserves in pool
        is_zero_for_one: bool,          // Swap direction (A->B = true, B->A = false)
    }

    /// Complete swap path with multiple hops
    /// Can represent 1-hop (direct) or multi-hop routes
    public struct SwapPath has copy, drop, store {
        nodes: vector<PathNode>,        // Ordered list of hops
        total_expected_fee: u64,        // Sum of all fees (basis points)
        estimated_gas_cost: u64,        // Estimated gas for entire path
        total_price_impact: u128,       // Cumulative price impact (basis points)
        path_type: u8,                  // 0=Direct, 1=Via-Stable, 2=Multi-hop
        created_at: u64,                // Timestamp for cache invalidation
    }

    /// Quotation result for a potential swap
    /// Used by quoter.move to return price estimates
    public struct QuoteResult has copy, drop {
        amount_out: u64,                // Expected output amount
        amount_in_required: u64,        // Required input amount (for exact output)
        price_impact: u128,             // Price impact in basis points
        fee_amount: u64,                // Total fees to be paid
        gas_estimate: u64,              // Estimated gas cost
        path_used: SwapPath,            // The path that would be executed
        is_valid: bool,                 // Whether the quote is executable
        slippage_tolerance: u16,        // Recommended slippage (basis points)
    }

    /// Result of an executed route
    /// Returned after successful swap execution
    #[allow(unused_field)]
    public struct RouteResult has copy, drop {
        amount_out: u64,                // Actual output amount received
        amount_in_consumed: u64,        // Actual input amount consumed
        gas_used: u64,                  // Actual gas consumed
        price_impact: u128,             // Actual price impact
        fees_paid: u64,                 // Total fees paid
        path_executed: SwapPath,        // The path that was executed
        execution_time: u64,            // Block timestamp of execution
        slippage_experienced: u16,      // Actual slippage (basis points)
    }

    /// Pool information for routing calculations
    /// Used by factory.move to provide pool data to router
    public struct PoolInfo has copy, drop, store {
        pool_id: object::ID,            // Pool object ID
        token_a: TypeName,              // First token type
        token_b: TypeName,              // Second token type
        bin_step: u16,                  // Bin step (fee tier)
        reserves_a: u64,                // Current reserves of token A
        reserves_b: u64,                // Current reserves of token B
        active_bin_id: u32,             // Current active bin
        total_liquidity: u64,           // Total liquidity in pool
        is_active: bool,                // Whether pool accepts swaps
        fee_rate: u64,                  // Current dynamic fee rate
        last_update: u64,               // Last update timestamp
    }

    /// Swap parameters for route execution
    /// Used by router.move to execute swaps with proper validation
    public struct SwapParams has copy, drop {
        amount_in: u64,                 // Input amount for exact input swaps
        amount_out: u64,                // Output amount for exact output swaps
        amount_out_minimum: u64,        // Minimum output (slippage protection)
        amount_in_maximum: u64,         // Maximum input (slippage protection)
        path: SwapPath,                 // Route to execute
        deadline: u64,                  // Transaction deadline
        recipient: address,             // Recipient of output tokens
        is_exact_input: bool,           // true = exact input, false = exact output
    }

    // ==================== PathNode Functions ====================

    /// Create a new path node
    public fun create_path_node(
        pool_id: object::ID,
        token_in: TypeName,
        token_out: TypeName,
        bin_step: u16,
        expected_fee: u64,
        pool_reserves_in: u64,
        pool_reserves_out: u64,
        is_zero_for_one: bool
    ): PathNode {
        PathNode {
            pool_id,
            token_in,
            token_out,
            bin_step,
            expected_fee,
            pool_reserves_in,
            pool_reserves_out,
            is_zero_for_one,
        }
    }

    /// Get path node information
    public fun get_path_node_info(node: &PathNode): (object::ID, TypeName, TypeName, u16, u64, bool) {
        (
            node.pool_id,
            node.token_in,
            node.token_out,
            node.bin_step,
            node.expected_fee,
            node.is_zero_for_one
        )
    }

    /// Get path node reserves
    public fun get_path_node_reserves(node: &PathNode): (u64, u64) {
        (node.pool_reserves_in, node.pool_reserves_out)
    }

    /// Check if path node has sufficient liquidity
    public fun node_has_sufficient_liquidity(node: &PathNode, amount_in: u64): bool {
        // Simple check: ensure pool has more output tokens than we need
        let estimated_out = (amount_in * node.pool_reserves_out) / 
                           (node.pool_reserves_in + amount_in);
        estimated_out > 0 && node.pool_reserves_out > estimated_out
    }

    // ==================== SwapPath Functions ====================

    /// Create a new swap path
    public fun create_swap_path(
        nodes: vector<PathNode>,
        path_type: u8,
        current_time: u64
    ): SwapPath {
        assert!(!vector::is_empty(&nodes), EEMPTY_PATH);
        assert!(vector::length(&nodes) <= (MAX_HOPS as u64), EINVALID_PATH);

        // Calculate total expected fee
        let mut total_fee = 0u64;
        let mut i = 0;
        while (i < vector::length(&nodes)) {
            let node = vector::borrow(&nodes, i);
            total_fee = total_fee + node.expected_fee;
            i = i + 1;
        };

        SwapPath {
            nodes,
            total_expected_fee: total_fee,
            estimated_gas_cost: estimate_gas_for_path_length(vector::length(&nodes)),
            total_price_impact: 0, // Will be calculated by quoter
            path_type,
            created_at: current_time,
        }
    }

    /// Create single-hop (direct) path
    public fun create_direct_path(
        pool_id: object::ID,
        token_in: TypeName,
        token_out: TypeName,
        bin_step: u16,
        expected_fee: u64,
        reserves_in: u64,
        reserves_out: u64,
        is_zero_for_one: bool,
        current_time: u64
    ): SwapPath {
        let node = create_path_node(
            pool_id, token_in, token_out, bin_step, expected_fee,
            reserves_in, reserves_out, is_zero_for_one
        );
        
        let mut nodes = vector::empty<PathNode>();
        vector::push_back(&mut nodes, node);
        
        create_swap_path(nodes, 0, current_time) // path_type = 0 (Direct)
    }

    /// Get swap path information
    public fun get_swap_path_info(path: &SwapPath): (u8, u64, u64, u128, u8) {
        (
            (vector::length(&path.nodes) as u8), // hop_count
            path.total_expected_fee,
            path.estimated_gas_cost,
            path.total_price_impact,
            path.path_type
        )
    }

    /// Get path nodes (read-only)
    public fun get_path_nodes(path: &SwapPath): &vector<PathNode> {
        &path.nodes
    }

    /// Get first and last tokens in path
    public fun get_path_tokens(path: &SwapPath): (TypeName, TypeName) {
        assert!(!vector::is_empty(&path.nodes), EEMPTY_PATH);
        
        let first_node = vector::borrow(&path.nodes, 0);
        let last_node = vector::borrow(&path.nodes, vector::length(&path.nodes) - 1);
        
        (first_node.token_in, last_node.token_out)
    }

    /// Check if path is still valid (not too old)
    public fun is_path_valid(path: &SwapPath, current_time: u64, max_age_ms: u64): bool {
        current_time <= path.created_at + max_age_ms
    }

    /// Update path price impact (called by quoter)
    public fun update_path_price_impact(path: &mut SwapPath, price_impact: u128) {
        path.total_price_impact = price_impact;
    }

    /// Update path gas estimate (called by quoter)
    public fun update_path_gas_estimate(path: &mut SwapPath, gas_estimate: u64) {
        path.estimated_gas_cost = gas_estimate;
    }

    // ==================== QuoteResult Functions ====================

    /// Create quote result
    public fun create_quote_result(
        amount_out: u64,
        amount_in_required: u64,
        price_impact: u128,
        fee_amount: u64,
        gas_estimate: u64,
        path: SwapPath,
        is_valid: bool
    ): QuoteResult {
        // Calculate recommended slippage based on price impact
        let slippage_tolerance = calculate_recommended_slippage(price_impact);
        
        QuoteResult {
            amount_out,
            amount_in_required,
            price_impact,
            fee_amount,
            gas_estimate,
            path_used: path,
            is_valid,
            slippage_tolerance,
        }
    }

    /// Get quote result details
    public fun get_quote_result_info(quote: &QuoteResult): (u64, u64, u128, u64, bool) {
        (
            quote.amount_out,
            quote.amount_in_required,
            quote.price_impact,
            quote.fee_amount,
            quote.is_valid
        )
    }

    /// Extract path from quote result
    public fun get_quote_path(quote: &QuoteResult): &SwapPath {
        &quote.path_used
    }

    /// Check if quote meets slippage requirements
    public fun quote_meets_slippage(
        quote: &QuoteResult,
        user_slippage_tolerance: u16
    ): bool {
        quote.slippage_tolerance <= user_slippage_tolerance
    }

    // ==================== PoolInfo Functions ====================

    /// Create pool info
    public fun create_pool_info(
        pool_id: object::ID,
        token_a: TypeName,
        token_b: TypeName,
        bin_step: u16,
        reserves_a: u64,
        reserves_b: u64,
        active_bin_id: u32,
        total_liquidity: u64,
        is_active: bool,
        fee_rate: u64,
        last_update: u64
    ): PoolInfo {
        PoolInfo {
            pool_id,
            token_a,
            token_b,
            bin_step,
            reserves_a,
            reserves_b,
            active_bin_id,
            total_liquidity,
            is_active,
            fee_rate,
            last_update,
        }
    }

    /// Get pool basic info
    public fun get_pool_basic_info(info: &PoolInfo): (object::ID, TypeName, TypeName, u16, bool) {
        (info.pool_id, info.token_a, info.token_b, info.bin_step, info.is_active)
    }

    /// Get pool liquidity info
    public fun get_pool_liquidity_info(info: &PoolInfo): (u64, u64, u64, u64) {
        (info.reserves_a, info.reserves_b, info.total_liquidity, info.fee_rate)
    }

    /// Check if pool can handle swap amount
    public fun pool_can_handle_swap(
        info: &PoolInfo,
        token_in: TypeName,
        amount_in: u64
    ): bool {
        if (!info.is_active) return false;
        
        // Determine which reserve to check based on input token
        let available_output = if (token_in == info.token_a) {
            info.reserves_b
        } else if (token_in == info.token_b) {
            info.reserves_a
        } else {
            return false // Token not in this pool
        };
        
        // Simple check: ensure we have sufficient output liquidity
        // More sophisticated checks will be done by quoter
        available_output > amount_in / 10 // At least 10% of input as output reserve
    }

    // ==================== SwapParams Functions ====================

    /// Create swap parameters for exact input
    public fun create_exact_input_params(
        amount_in: u64,
        amount_out_minimum: u64,
        path: SwapPath,
        deadline: u64,
        recipient: address
    ): SwapParams {
        SwapParams {
            amount_in,
            amount_out: 0, // Not used for exact input
            amount_out_minimum,
            amount_in_maximum: 0, // Not used for exact input
            path,
            deadline,
            recipient,
            is_exact_input: true,
        }
    }

    /// Create swap parameters for exact output
    public fun create_exact_output_params(
        amount_out: u64,
        amount_in_maximum: u64,
        path: SwapPath,
        deadline: u64,
        recipient: address
    ): SwapParams {
        SwapParams {
            amount_in: 0, // Not used for exact output
            amount_out,
            amount_out_minimum: 0, // Not used for exact output
            amount_in_maximum,
            path,
            deadline,
            recipient,
            is_exact_input: false,
        }
    }

    /// Get swap parameters info
    public fun get_swap_params_info(params: &SwapParams): (u64, u64, u64, u64, bool) {
        (
            params.amount_in,
            params.amount_out,
            params.amount_out_minimum,
            params.amount_in_maximum,
            params.is_exact_input
        )
    }

    /// Validate swap parameters
    public fun validate_swap_params(params: &SwapParams, current_time: u64): bool {
        // Check deadline
        if (current_time > params.deadline) return false;
        
        // Check amounts
        if (params.is_exact_input) {
            params.amount_in > 0 && params.amount_out_minimum >= 0
        } else {
            params.amount_out > 0 && params.amount_in_maximum > 0
        }
    }

    // ==================== Helper Functions ====================

    /// Estimate gas cost based on path length
    fun estimate_gas_for_path_length(hop_count: u64): u64 {
        // Base gas + gas per hop (rough estimates)
        let base_gas = 100000u64; // Base transaction gas
        let gas_per_hop = 150000u64; // Gas per swap operation
        
        base_gas + (hop_count * gas_per_hop)
    }

    /// Calculate recommended slippage based on price impact
    fun calculate_recommended_slippage(price_impact: u128): u16 {
        // Convert price impact to basis points and add buffer
        let impact_bps = (price_impact / 100) as u16; // Convert from scaled format
        
        if (impact_bps < 10) {
            50 // 0.5% for very low impact
        } else if (impact_bps < 50) {
            100 // 1% for low impact
        } else if (impact_bps < 100) {
            200 // 2% for medium impact
        } else if (impact_bps < 500) {
            500 // 5% for high impact
        } else {
            1000 // 10% for very high impact
        }
    }

    /// Compare two swap paths to find better one
    public fun compare_paths(path1: &SwapPath, path2: &SwapPath): u8 {
        // Simple comparison: lower total cost wins
        // More sophisticated logic can be added later
        let cost1 = path1.total_expected_fee + (path1.estimated_gas_cost / 1000);
        let cost2 = path2.total_expected_fee + (path2.estimated_gas_cost / 1000);
        
        if (cost1 < cost2) {
            1 // path1 is better
        } else if (cost2 < cost1) {
            2 // path2 is better
        } else {
            0 // paths are equivalent
        }
    }

    // ==================== Validation Functions ====================

    /// Validate that path tokens are properly connected
    public fun validate_path_connectivity(path: &SwapPath): bool {
        let nodes = &path.nodes;
        if (vector::length(nodes) < 2) return true; // Single hop is always valid
        
        let mut i = 0;
        while (i < vector::length(nodes) - 1) {
            let current_node = vector::borrow(nodes, i);
            let next_node = vector::borrow(nodes, i + 1);
            
            // Output of current hop must match input of next hop
            if (current_node.token_out != next_node.token_in) {
                return false
            };
            i = i + 1;
        };
        
        true
    }

    /// Check if path has reasonable price impact
    public fun has_reasonable_price_impact(path: &SwapPath): bool {
        path.total_price_impact <= MAX_PRICE_IMPACT
    }

    // ==================== Constants Access ====================

    /// Get maximum allowed hops
    public fun get_max_hops(): u8 {
        MAX_HOPS
    }

    /// Get basis points scale
    public fun get_basis_points_scale(): u64 {
        BASIS_POINTS_SCALE
    }

    /// Get maximum price impact threshold
    public fun get_max_price_impact(): u128 {
        MAX_PRICE_IMPACT
    }

    // ==================== RouteResult Access Functions ====================
    // Added these to make RouteResult fields accessible without warnings

    /// Get route result amounts
    public fun get_route_result_amounts(result: &RouteResult): (u64, u64) {
        (result.amount_out, result.amount_in_consumed)
    }

    /// Get route result gas info
    public fun get_route_result_gas_info(result: &RouteResult): (u64, u64) {
        (result.gas_used, result.execution_time)
    }

    /// Get route result trading info
    public fun get_route_result_trading_info(result: &RouteResult): (u128, u64, u16) {
        (result.price_impact, result.fees_paid, result.slippage_experienced)
    }

    /// Get route result path
    public fun get_route_result_path(result: &RouteResult): &SwapPath {
        &result.path_executed
    }

    /// Create route result
    public fun create_route_result(
        amount_out: u64,
        amount_in_consumed: u64,
        gas_used: u64,
        price_impact: u128,
        fees_paid: u64,
        path_executed: SwapPath,
        execution_time: u64,
        slippage_experienced: u16
    ): RouteResult {
        RouteResult {
            amount_out,
            amount_in_consumed,
            gas_used,
            price_impact,
            fees_paid,
            path_executed,
            execution_time,
            slippage_experienced,
        }
    }
    /// Get quote amount out - MISSING FUNCTION
    public fun get_quote_amount_out(quote: &QuoteResult): u64 {
        quote.amount_out
    }

    /// Get quote price impact - MISSING FUNCTION  
    public fun get_quote_price_impact(quote: &QuoteResult): u128 {
        quote.price_impact
    }

    /// Get quote fee amount - MISSING FUNCTION
    public fun get_quote_fee(quote: &QuoteResult): u64 {
        quote.fee_amount
    }

    /// Get quote validity - MISSING FUNCTION
    public fun get_quote_valid(quote: &QuoteResult): bool {
        quote.is_valid
    }

    /// Get quote slippage tolerance - ADDITIONAL HELPER
    public fun get_quote_slippage_tolerance(quote: &QuoteResult): u16 {
        quote.slippage_tolerance
    }

    /// Get quote gas estimate - ADDITIONAL HELPER  
    public fun get_quote_gas_estimate(quote: &QuoteResult): u64 {
        quote.gas_estimate
    }

    /// Get quote amount in required - ADDITIONAL HELPER
    public fun get_quote_amount_in_required(quote: &QuoteResult): u64 {
        quote.amount_in_required
    }
    
    // ==================== Test Helper Functions ====================

    #[test_only]
    /// Create test path node
    public fun create_test_path_node(
        pool_id: object::ID,
        token_in: TypeName,
        token_out: TypeName
    ): PathNode {
        create_path_node(
            pool_id, token_in, token_out, 25, 250, 1000000, 1000000, true
        )
    }

    #[test_only]
    /// Create test swap path
    public fun create_test_swap_path(): SwapPath {
        let mut nodes = vector::empty<PathNode>();
        let test_pool_id = object::id_from_address(@0x1);
        let test_token_a = std::type_name::get<u64>();
        let test_token_b = std::type_name::get<u128>();
        
        let node = create_test_path_node(test_pool_id, test_token_a, test_token_b);
        vector::push_back(&mut nodes, node);
        
        create_swap_path(nodes, 0, 0)
    }

    #[test_only]
    /// Test path validation
    public fun test_path_validation(): bool {
        let path = create_test_swap_path();
        validate_path_connectivity(&path) && has_reasonable_price_impact(&path)
    }
}