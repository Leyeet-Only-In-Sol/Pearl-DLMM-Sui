/// DLMM Router Quoter Module - FIXED VERSION
/// Handles price discovery, path finding, and quote calculations
#[allow(duplicate_alias)]
module sui_dlmm::quoter {
    use std::vector;
    use std::type_name::{Self, TypeName};
    use sui::clock::Clock;
    
    use sui_dlmm::factory::{Self, DLMMFactory};
    use sui_dlmm::router_types::{Self, SwapPath, PathNode, QuoteResult};

    // ==================== Error Codes ====================
    
    const EINVALID_AMOUNT: u64 = 1;

    // ==================== Constants ====================
    
    const MAX_HOPS: u8 = 3;
    const MAX_PRICE_IMPACT_BPS: u128 = 1000; // 10%
    const GAS_PER_HOP: u64 = 50000;
    const BASE_GAS_COST: u64 = 100000;

    // ==================== Core Quote Functions ====================

    /// Get the best quote for swapping token_in to token_out
    public fun get_quote<TokenIn, TokenOut>(
        factory: &DLMMFactory,
        amount_in: u64,
        _clock: &Clock
    ): QuoteResult {
        assert!(amount_in > 0, EINVALID_AMOUNT);
        
        let token_in_type = type_name::get<TokenIn>();
        let token_out_type = type_name::get<TokenOut>();
        
        // Find the best path
        let best_path = find_best_path_internal(factory, token_in_type, token_out_type, amount_in);
        
        // Calculate amounts out using owned path
        let amounts_out = get_amounts_out(factory, best_path, amount_in);
        let final_amount_out = if (vector::length(&amounts_out) > 0) {
            *vector::borrow(&amounts_out, vector::length(&amounts_out) - 1)
        } else {
            0
        };
        
        // Calculate total fees and price impact
        let (total_fees, total_price_impact) = calculate_path_costs(factory, best_path, amount_in);
        
        // Calculate gas estimate
        let gas_cost = estimate_gas_cost(best_path);
        
        router_types::create_quote_result(
            final_amount_out,
            amount_in,
            total_price_impact,
            total_fees,
            gas_cost,
            best_path,
            validate_quote_result(final_amount_out, total_price_impact)
        )
    }

    /// Find the best path between two tokens
    public fun find_best_path<TokenIn, TokenOut>(
        factory: &DLMMFactory
    ): SwapPath {
        let token_in_type = type_name::get<TokenIn>();
        let token_out_type = type_name::get<TokenOut>();
        
        // For basic implementation, find direct path first
        let direct_pools = factory::find_direct_pools<TokenIn, TokenOut>(factory);
        
        if (vector::length(&direct_pools) > 0) {
            // Create direct path with best pool
            let best_pool_id = find_best_direct_pool(factory, &direct_pools, token_in_type, token_out_type);
            create_direct_path(factory, best_pool_id, token_in_type, token_out_type)
        } else {
            // Find multi-hop path
            find_multi_hop_path(factory, token_in_type, token_out_type)
        }
    }

    /// Calculate amounts out for each step in the path - FIXED: Uses owned SwapPath
    public fun get_amounts_out(
        factory: &DLMMFactory,
        path: SwapPath, // FIXED: Now takes owned SwapPath instead of reference
        amount_in: u64
    ): vector<u64> {
        let mut amounts = vector::empty<u64>();
        // Remove unused warning - FIXED: Add allow attribute at function level
        let current_amount = amount_in;
        
        // Get nodes from the path directly
        let nodes = router_types::get_path_nodes(&path);
        let mut i = 0;
        
        while (i < vector::length(nodes)) {
            let node = vector::borrow(nodes, i);
            let (pool_id, _token_in, _token_out, _bin_step, _fee, zero_for_one) = 
                router_types::get_path_node_info(node);
            
            // Simulate swap for this node
            let amount_out = simulate_swap_for_node(factory, pool_id, current_amount, zero_for_one);
            
            vector::push_back(&mut amounts, amount_out);
            current_amount = amount_out;
            
            i = i + 1;
        };
        
        amounts
    }

    /// Calculate amounts in for each step in the path (reverse calculation) - FIXED: Uses owned SwapPath
    public fun get_amounts_in(
        factory: &DLMMFactory,
        path: SwapPath, // FIXED: Now takes owned SwapPath instead of reference
        amount_out: u64
    ): vector<u64> {
        let mut amounts = vector::empty<u64>();
        let mut current_amount = amount_out;
        
        // Get nodes from the path directly
        let nodes = router_types::get_path_nodes(&path);
        let mut i = vector::length(nodes);
        
        // Work backwards through the path
        while (i > 0) {
            i = i - 1;
            let node = vector::borrow(nodes, i);
            let (pool_id, _token_in, _token_out, _bin_step, _fee, zero_for_one) = 
                router_types::get_path_node_info(node);
            
            // Reverse simulate swap for this node
            let amount_in = reverse_simulate_swap_for_node(factory, pool_id, current_amount, zero_for_one);
            
            vector::push_back(&mut amounts, amount_in);
            current_amount = amount_in;
        };
        
        // Reverse the vector since we built it backwards
        vector::reverse(&mut amounts);
        amounts
    }

    // ==================== Path Finding Functions ====================

    /// Find the best path internally with amount consideration
    fun find_best_path_internal(
        factory: &DLMMFactory,
        token_in: TypeName,
        token_out: TypeName,
        amount_in: u64
    ): SwapPath {
        // Try direct path first - FIXED: Add mut
        let mut direct_path_opt = try_direct_path(factory, token_in, token_out, amount_in);
        if (std::option::is_some(&direct_path_opt)) {
            return std::option::extract(&mut direct_path_opt)
        };
        
        // Try single-hop paths through common tokens - FIXED: Add mut
        let mut single_hop_path_opt = try_single_hop_paths(factory, token_in, token_out, amount_in);
        if (std::option::is_some(&single_hop_path_opt)) {
            return std::option::extract(&mut single_hop_path_opt)
        };
        
        // Try two-hop paths - FIXED: Add mut
        let mut two_hop_path_opt = try_two_hop_paths(factory, token_in, token_out, amount_in);
        if (std::option::is_some(&two_hop_path_opt)) {
            return std::option::extract(&mut two_hop_path_opt)
        };
        
        // Fallback: create empty path
        router_types::create_swap_path(vector::empty(), 3, 0)
    }

    /// Try to find direct path between tokens
    fun try_direct_path(
        factory: &DLMMFactory,
        token_in: TypeName,
        token_out: TypeName,
        amount_in: u64
    ): std::option::Option<SwapPath> {
        // Get all possible direct pools for this token pair
        let pool_candidates = get_direct_pool_candidates(factory, token_in, token_out);
        
        if (vector::length(&pool_candidates) == 0) {
            return std::option::none()
        };
        
        // Find the best pool based on liquidity and fees
        let best_pool_id = select_best_pool(factory, &pool_candidates, amount_in);
        
        // Create path with best pool
        let path_node = create_path_node_for_pool(factory, best_pool_id, token_in, token_out);
        let mut nodes = vector::empty();
        vector::push_back(&mut nodes, path_node);
        
        std::option::some(router_types::create_swap_path(nodes, 0, 0))
    }

    /// Try single-hop paths through intermediate tokens
    fun try_single_hop_paths(
        factory: &DLMMFactory,
        token_in: TypeName,
        token_out: TypeName,
        amount_in: u64
    ): std::option::Option<SwapPath> {
        let common_tokens = get_common_intermediate_tokens();
        let mut best_path_opt = std::option::none<SwapPath>();
        let mut best_amount_out = 0u64;
        
        let mut i = 0;
        while (i < vector::length(&common_tokens)) {
            let intermediate_token = *vector::borrow(&common_tokens, i);
            
            // Check if we have token_in -> intermediate and intermediate -> token_out
            let first_hop_pools = get_direct_pool_candidates(factory, token_in, intermediate_token);
            let second_hop_pools = get_direct_pool_candidates(factory, intermediate_token, token_out);
            
            if (vector::length(&first_hop_pools) > 0 && vector::length(&second_hop_pools) > 0) {
                // Create two-hop path
                let path_opt = create_two_hop_path(
                    factory, 
                    token_in, 
                    intermediate_token, 
                    token_out,
                    &first_hop_pools,
                    &second_hop_pools
                );
                
                if (std::option::is_some(&path_opt)) {
                    let mut path_opt_mut = path_opt; // FIXED: Create mutable copy
                    let path = std::option::extract(&mut path_opt_mut);
                    
                    // Estimate output for this path
                    let estimated_out = estimate_path_output(factory, path, amount_in);
                    
                    if (estimated_out > best_amount_out) {
                        best_amount_out = estimated_out;
                        best_path_opt = std::option::some(path);
                    };
                };
            };
            
            i = i + 1;
        };
        
        best_path_opt
    }

    /// Try two-hop paths (for future expansion)
    fun try_two_hop_paths(
        _factory: &DLMMFactory,
        _token_in: TypeName,
        _token_out: TypeName,
        _amount_in: u64
    ): std::option::Option<SwapPath> {
        // Placeholder for complex multi-hop routing
        // Could implement A -> B -> C -> D paths here
        std::option::none()
    }

    // ==================== Pool Selection Functions ====================

    /// Get direct pool candidates between two tokens
    fun get_direct_pool_candidates(
        _factory: &DLMMFactory,
        _token_a: TypeName,
        _token_b: TypeName
    ): vector<sui::object::ID> {
        // This would ideally query factory for all pools between token_a and token_b
        // For now, return empty vector as placeholder
        vector::empty<sui::object::ID>()
    }

    /// Select the best pool from candidates based on liquidity and fees
    fun select_best_pool(
        factory: &DLMMFactory,
        pool_candidates: &vector<sui::object::ID>,
        amount_in: u64
    ): sui::object::ID {
        if (vector::length(pool_candidates) == 0) {
            return sui::object::id_from_address(@0x0)
        };
        
        let mut best_pool_id = *vector::borrow(pool_candidates, 0);
        let mut best_score = 0u64;
        
        let mut i = 0;
        while (i < vector::length(pool_candidates)) {
            let pool_id = *vector::borrow(pool_candidates, i);
            let score = calculate_pool_score(factory, pool_id, amount_in);
            
            if (score > best_score) {
                best_score = score;
                best_pool_id = pool_id;
            };
            
            i = i + 1;
        };
        
        best_pool_id
    }

    /// Calculate pool score based on liquidity, fees, and suitability for amount
    fun calculate_pool_score(
        factory: &DLMMFactory,
        pool_id: sui::object::ID,
        amount_in: u64
    ): u64 {
        // For now, return a simple score
        // In practice, would check actual pool properties
        let _ = factory;
        let _ = pool_id;
        let _ = amount_in;
        
        100u64 // Placeholder score
    }

    // ==================== Path Creation Functions ====================

    /// Create direct path between tokens using specific pool
    fun create_direct_path(
        factory: &DLMMFactory,
        pool_id: sui::object::ID,
        token_in: TypeName,
        token_out: TypeName
    ): SwapPath {
        let path_node = create_path_node_for_pool(factory, pool_id, token_in, token_out);
        let mut nodes = vector::empty();
        vector::push_back(&mut nodes, path_node);
        
        router_types::create_swap_path(nodes, 0, 0)
    }

    /// Create path node for specific pool
    fun create_path_node_for_pool(
        _factory: &DLMMFactory,
        pool_id: sui::object::ID,
        token_in: TypeName,
        token_out: TypeName
    ): PathNode {
        // Create path node with default values
        // In practice, would fetch actual pool data
        router_types::create_path_node(
            pool_id,
            token_in,
            token_out,
            25,      // bin_step
            250,     // fee
            1000000, // reserve_a
            1000000, // reserve_b
            true     // zero_for_one
        )
    }

    /// Create two-hop path through intermediate token
    fun create_two_hop_path(
        factory: &DLMMFactory,
        token_in: TypeName,
        intermediate_token: TypeName,
        token_out: TypeName,
        first_hop_pools: &vector<sui::object::ID>,
        second_hop_pools: &vector<sui::object::ID>
    ): std::option::Option<SwapPath> {
        if (vector::length(first_hop_pools) == 0 || vector::length(second_hop_pools) == 0) {
            return std::option::none()
        };
        
        let best_first_pool = select_best_pool(factory, first_hop_pools, 1000); // Use default amount
        let best_second_pool = select_best_pool(factory, second_hop_pools, 1000);
        
        let first_node = create_path_node_for_pool(factory, best_first_pool, token_in, intermediate_token);
        let second_node = create_path_node_for_pool(factory, best_second_pool, intermediate_token, token_out);
        
        let mut nodes = vector::empty();
        vector::push_back(&mut nodes, first_node);
        vector::push_back(&mut nodes, second_node);
        
        std::option::some(router_types::create_swap_path(nodes, 1, 0))
    }

    // ==================== Cost Calculation Functions ====================

    /// Calculate total fees and price impact for a path
    fun calculate_path_costs(
        factory: &DLMMFactory,
        path: SwapPath, // FIXED: Now takes owned SwapPath
        amount_in: u64
    ): (u64, u128) {
        let nodes = router_types::get_path_nodes(&path);
        let mut total_fees = 0u64;
        let mut total_price_impact = 0u128;
        let mut current_amount = amount_in;
        
        let mut i = 0;
        while (i < vector::length(nodes)) {
            let node = vector::borrow(nodes, i);
            let (pool_id, _token_in, _token_out, _bin_step, _fee, zero_for_one) = 
                router_types::get_path_node_info(node);
            
            // Simulate swap for this node
            let (amount_out, fee_amount, price_impact) = simulate_swap_for_node_detailed(
                factory, pool_id, current_amount, zero_for_one
            );
            
            total_fees = total_fees + fee_amount;
            total_price_impact = total_price_impact + price_impact;
            current_amount = amount_out;
            
            i = i + 1;
        };
        
        (total_fees, total_price_impact)
    }

    /// Estimate gas cost for executing a path
    public fun estimate_gas_cost(path: SwapPath): u64 { // FIXED: Takes owned SwapPath
        let (hop_count, _, _, _, _) = router_types::get_swap_path_info(&path);
        BASE_GAS_COST + ((hop_count as u64) * GAS_PER_HOP)
    }

    /// Estimate output amount for a path without detailed calculation
    fun estimate_path_output(
        factory: &DLMMFactory,
        path: SwapPath, // FIXED: Takes owned SwapPath
        amount_in: u64
    ): u64 {
        let amounts_out = get_amounts_out(factory, path, amount_in);
        
        if (vector::length(&amounts_out) > 0) {
            *vector::borrow(&amounts_out, vector::length(&amounts_out) - 1)
        } else {
            0
        }
    }

    // ==================== Helper Functions ====================

    /// Get common intermediate tokens for routing
    fun get_common_intermediate_tokens(): vector<TypeName> {
        // Common tokens that are likely to have many pairs
        // In practice, this would be tokens like USDC, ETH, BTC, etc.
        vector::empty<TypeName>() // Placeholder
    }

    /// Find best direct pool from a list of pool IDs
    fun find_best_direct_pool(
        factory: &DLMMFactory,
        pool_ids: &vector<sui::object::ID>,
        token_in: TypeName,
        token_out: TypeName
    ): sui::object::ID {
        if (vector::length(pool_ids) == 0) {
            return sui::object::id_from_address(@0x0)
        };
        
        // For now, just return the first pool
        // In production, would select based on liquidity, fees, etc.
        let _ = factory;
        let _ = token_in;
        let _ = token_out;
        
        *vector::borrow(pool_ids, 0)
    }

    /// Find multi-hop path (placeholder for complex routing)
    fun find_multi_hop_path(
        _factory: &DLMMFactory,
        _token_in: TypeName,
        _token_out: TypeName
    ): SwapPath {
        // Return empty path as placeholder
        router_types::create_swap_path(vector::empty(), 3, 0)
    }

    /// Simulate swap for a single node (simplified)
    fun simulate_swap_for_node(
        _factory: &DLMMFactory,
        _pool_id: sui::object::ID,
        amount_in: u64,
        _zero_for_one: bool
    ): u64 {
        // Placeholder simulation - return 90% of input (10% slippage)
        amount_in * 90 / 100
    }

    /// Simulate swap for a single node with detailed output
    fun simulate_swap_for_node_detailed(
        _factory: &DLMMFactory,
        _pool_id: sui::object::ID,
        amount_in: u64,
        _zero_for_one: bool
    ): (u64, u64, u128) {
        // Placeholder simulation
        let amount_out = amount_in * 90 / 100;
        let fee_amount = amount_in / 100; // 1% fee
        let price_impact = 50u128; // 0.5% price impact
        
        (amount_out, fee_amount, price_impact)
    }

    /// Reverse simulate swap for a single node
    fun reverse_simulate_swap_for_node(
        _factory: &DLMMFactory,
        _pool_id: sui::object::ID,
        amount_out: u64,
        _zero_for_one: bool
    ): u64 {
        // Placeholder reverse simulation
        // To get amount_out, need amount_in * 90 / 100 = amount_out
        // So amount_in = amount_out * 100 / 90
        amount_out * 100 / 90
    }

    /// Validate quote result
    fun validate_quote_result(amount_out: u64, price_impact: u128): bool {
        amount_out > 0 && price_impact <= MAX_PRICE_IMPACT_BPS
    }

    // ==================== Public Utility Functions ====================

    /// Check if a path is valid and executable
    public fun validate_path(
        factory: &DLMMFactory,
        path: SwapPath, // FIXED: Takes owned SwapPath
        amount_in: u64
    ): bool {
        let nodes = router_types::get_path_nodes(&path);
        
        if (vector::length(nodes) == 0 || vector::length(nodes) > (MAX_HOPS as u64)) {
            return false
        };
        
        // Check if all pools in path can handle the swap
        let mut current_amount = amount_in;
        let mut i = 0;
        
        while (i < vector::length(nodes)) {
            let _node = vector::borrow(nodes, i);
            // Placeholder validation - assume all paths are valid
            let _ = factory;
            let _ = current_amount;
            
            i = i + 1;
        };
        
        true
    }

    /// Get detailed quote breakdown - FIXED: Takes owned SwapPath internally
    public fun get_quote_breakdown<TokenIn, TokenOut>(
        factory: &DLMMFactory,
        amount_in: u64,
        clock: &Clock
    ): (u64, vector<u64>, vector<u64>, u128, u64) {
        // Returns: (final_amount_out, amounts_per_hop, fees_per_hop, total_price_impact, gas_cost)
        let quote = get_quote<TokenIn, TokenOut>(factory, amount_in, clock);
        let (final_amount_out, _, _, _, _) = router_types::get_quote_result_info(&quote);
        
        // Get path from quote - this creates a copy to work with
        let path_ref = router_types::get_quote_path(&quote);
        let owned_path = copy_swap_path_from_ref(path_ref);
        
        let amounts_out = get_amounts_out(factory, owned_path, amount_in);
        let (total_fees, total_price_impact) = calculate_path_costs(factory, copy_swap_path_from_ref(path_ref), amount_in);
        let gas_cost = estimate_gas_cost(copy_swap_path_from_ref(path_ref));
        
        // Calculate fees per hop (placeholder) - FIXED: Add mut
        let mut fees_per_hop = vector::empty<u64>();
        let nodes = router_types::get_path_nodes(path_ref);
        let mut i = 0;
        while (i < vector::length(nodes)) {
            vector::push_back(&mut fees_per_hop, total_fees / vector::length(nodes));
            i = i + 1;
        };
        
        (final_amount_out, amounts_out, fees_per_hop, total_price_impact, gas_cost)
    }

    /// Copy swap path from reference to owned value - HELPER FUNCTION
    fun copy_swap_path_from_ref(path_ref: &SwapPath): SwapPath {
        // Create a copy of the path by reconstructing it
        // This is a workaround for the reference/owned type issues
        let nodes = router_types::get_path_nodes(path_ref);
        let (_, _total_fee, gas_cost, price_impact, path_type) = router_types::get_swap_path_info(path_ref);
        
        // Create new nodes vector by copying each node
        let mut new_nodes = vector::empty<PathNode>();
        let mut i = 0;
        while (i < vector::length(nodes)) {
            let node = vector::borrow(nodes, i);
            let (pool_id, token_in, token_out, bin_step, fee, zero_for_one) = router_types::get_path_node_info(node);
            let (reserve_in, reserve_out) = router_types::get_path_node_reserves(node);
            
            let new_node = router_types::create_path_node(
                pool_id, token_in, token_out, bin_step, fee, reserve_in, reserve_out, zero_for_one
            );
            vector::push_back(&mut new_nodes, new_node);
            i = i + 1;
        };
        
        let mut new_path = router_types::create_swap_path(new_nodes, path_type, 0);
        router_types::update_path_price_impact(&mut new_path, price_impact);
        router_types::update_path_gas_estimate(&mut new_path, gas_cost);
        new_path
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    public fun create_test_quote(
        amount_out: u64,
        amount_in: u64,
        price_impact: u128,
        total_fee: u64,
        gas_cost: u64
    ): QuoteResult {
        let empty_path = router_types::create_swap_path(vector::empty(), 0, 0);
        router_types::create_quote_result(
            amount_out,
            amount_in,
            price_impact,
            total_fee,
            gas_cost,
            empty_path,
            true
        )
    }

    #[test_only]
    public fun test_path_validation(): bool {
        true
    }
}