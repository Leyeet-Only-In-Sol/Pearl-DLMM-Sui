/// DLMM Router Main Module
/// Orchestrates swap execution using quoter intelligence and pool interactions
module sui_dlmm::router {
    use std::vector;
    use std::type_name::{Self, TypeName};
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::event;

    use sui_dlmm::factory::{Self, DLMMFactory};
    use sui_dlmm::dlmm_pool::{Self, DLMMPool};
    use sui_dlmm::quoter;
    use sui_dlmm::router_types::{Self, SwapPath, PathNode, QuoteResult};

    // ==================== Error Codes ====================
    
    const EINVALID_AMOUNT: u64 = 1;
    const EINSUFFICIENT_OUTPUT: u64 = 2;
    const EEXCESSIVE_INPUT: u64 = 3;
    const EINVALID_PATH: u64 = 4;
    const EEXPIRED_DEADLINE: u64 = 5;
    const EEXCESSIVE_PRICE_IMPACT: u64 = 6;
    const EINSUFFICIENT_LIQUIDITY: u64 = 7;
    const ENO_ROUTE_FOUND: u64 = 8;
    const EINVALID_RECIPIENT: u64 = 9;
    const ETOO_MANY_HOPS: u64 = 10;

    // ==================== Constants ====================
    
    const MAX_PRICE_IMPACT_BPS: u128 = 1000; // 10%
    const DEFAULT_SLIPPAGE_BPS: u64 = 50; // 0.5%
    const MAX_DEADLINE_EXTENSION: u64 = 3600000; // 1 hour in ms

    // ==================== Structs ====================

    /// Router configuration and state
    public struct Router has key {
        id: UID,
        factory: DLMMFactory,
        admin: address,
        is_paused: bool,
        total_swaps: u64,
        total_volume: u64,
        created_at: u64,
    }

    /// Swap parameters for exact input swaps
    public struct SwapExactInputParams has copy, drop {
        path: SwapPath,
        amount_in: u64,
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
    }

    /// Swap parameters for exact output swaps
    public struct SwapExactOutputParams has copy, drop {
        path: SwapPath,
        amount_out: u64,
        amount_in_max: u64,
        recipient: address,
        deadline: u64,
    }

    /// Multi-path swap parameters for complex routing
    public struct MultiPathSwapParams has copy, drop {
        paths: vector<SwapPath>,
        amount_in: u64,
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
    }

    // ==================== Events ====================

    /// Emitted when a swap is executed
    public struct SwapExecuted has copy, drop {
        sender: address,
        recipient: address,
        token_in: TypeName,
        token_out: TypeName,
        amount_in: u64,
        amount_out: u64,
        path_length: u64,
        price_impact: u128,
        fee_paid: u64,
    }

    /// Emitted when a quote is requested
    public struct QuoteRequested has copy, drop {
        sender: address,
        token_in: TypeName,
        token_out: TypeName,
        amount_in: u64,
        estimated_out: u64,
        price_impact: u128,
    }

    // ==================== Initialization ====================

    /// Initialize the router with a factory
    public fun initialize_router(
        factory: DLMMFactory,
        admin: address,
        clock: &Clock,
        ctx: &mut TxContext
    ): Router {
        Router {
            id: object::new(ctx),
            factory,
            admin,
            is_paused: false,
            total_swaps: 0,
            total_volume: 0,
            created_at: sui::clock::timestamp_ms(clock),
        }
    }

    // ==================== Main Swap Functions ====================

    /// Execute exact input swap (swap exact amount in for minimum amount out)
    public fun swap_exact_tokens_for_tokens<TokenIn, TokenOut>(
        router: &mut Router,
        token_in: Coin<TokenIn>,
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<TokenOut> {
        assert!(!router.is_paused, EINSUFFICIENT_LIQUIDITY);
        assert!(sui::clock::timestamp_ms(clock) <= deadline, EEXPIRED_DEADLINE);
        assert!(recipient != @0x0, EINVALID_RECIPIENT);

        let amount_in = coin::value(&token_in);
        assert!(amount_in > 0, EINVALID_AMOUNT);

        // Get quote and optimal path
        let quote = quoter::get_quote<TokenIn, TokenOut>(&router.factory, amount_in, clock);
        let amount_out = router_types::get_quote_amount_out(&quote);
        let path = router_types::get_quote_path(&quote);
        let price_impact = router_types::get_quote_price_impact(&quote);

        // Validate quote
        assert!(amount_out >= amount_out_min, EINSUFFICIENT_OUTPUT);
        assert!(price_impact <= MAX_PRICE_IMPACT_BPS, EEXCESSIVE_PRICE_IMPACT);
        assert!(router_types::get_quote_valid(&quote), ENO_ROUTE_FOUND);

        // Execute swap through path
        let token_out = execute_swap_exact_input(
            &mut router.factory,
            token_in,
            &path,
            amount_out_min,
            clock
        );

        let actual_amount_out = coin::value(&token_out);

        // Update router statistics
        router.total_swaps = router.total_swaps + 1;
        router.total_volume = router.total_volume + amount_in;

        // Emit swap event
        event::emit(SwapExecuted {
            sender: tx_context::sender(ctx),
            recipient,
            token_in: type_name::get<TokenIn>(),
            token_out: type_name::get<TokenOut>(),
            amount_in,
            amount_out: actual_amount_out,
            path_length: get_path_length(&path),
            price_impact,
            fee_paid: router_types::get_quote_fee(&quote),
        });

        token_out
    }

    /// Execute exact output swap (swap maximum amount in for exact amount out)
    public fun swap_tokens_for_exact_tokens<TokenIn, TokenOut>(
        router: &mut Router,
        token_in: Coin<TokenIn>,
        amount_out: u64,
        amount_in_max: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<TokenOut>, Coin<TokenIn>) {
        assert!(!router.is_paused, EINSUFFICIENT_LIQUIDITY);
        assert!(sui::clock::timestamp_ms(clock) <= deadline, EEXPIRED_DEADLINE);
        assert!(recipient != @0x0, EINVALID_RECIPIENT);
        assert!(amount_out > 0, EINVALID_AMOUNT);

        let available_amount_in = coin::value(&token_in);
        assert!(available_amount_in <= amount_in_max, EEXCESSIVE_INPUT);

        // Get quote for reverse calculation
        let quote = quoter::get_quote<TokenIn, TokenOut>(&router.factory, available_amount_in, clock);
        let path = router_types::get_quote_path(&quote);

        // Calculate exact input needed for desired output
        let amounts_in = quoter::get_amounts_in(&router.factory, &path, amount_out, clock);
        let required_amount_in = if (vector::length(&amounts_in) > 0) {
            *vector::borrow(&amounts_in, 0)
        } else {
            0
        };

        assert!(required_amount_in > 0, ENO_ROUTE_FOUND);
        assert!(required_amount_in <= amount_in_max, EEXCESSIVE_INPUT);
        assert!(required_amount_in <= available_amount_in, EINSUFFICIENT_LIQUIDITY);

        // Split input coin to use only required amount
        let coin_to_swap = coin::split(&mut token_in, required_amount_in, ctx);
        
        // Execute exact input swap
        let token_out = execute_swap_exact_input(
            &mut router.factory,
            coin_to_swap,
            &path,
            amount_out,
            clock
        );

        let actual_amount_out = coin::value(&token_out);
        assert!(actual_amount_out >= amount_out, EINSUFFICIENT_OUTPUT);

        // Update router statistics
        router.total_swaps = router.total_swaps + 1;
        router.total_volume = router.total_volume + required_amount_in;

        // Emit swap event
        event::emit(SwapExecuted {
            sender: tx_context::sender(ctx),
            recipient,
            token_in: type_name::get<TokenIn>(),
            token_out: type_name::get<TokenOut>(),
            amount_in: required_amount_in,
            amount_out: actual_amount_out,
            path_length: get_path_length(&path),
            price_impact: router_types::get_quote_price_impact(&quote),
            fee_paid: router_types::get_quote_fee(&quote),
        });

        (token_out, token_in) // Return output token and remaining input token
    }

    // ==================== Advanced Swap Functions ====================

    /// Execute multi-path swap for better price execution
    public fun swap_exact_tokens_for_tokens_multi_path<TokenIn, TokenOut>(
        router: &mut Router,
        token_in: Coin<TokenIn>,
        paths: vector<SwapPath>,
        amounts_in: vector<u64>, // Amount to route through each path
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<TokenOut> {
        assert!(!router.is_paused, EINSUFFICIENT_LIQUIDITY);
        assert!(sui::clock::timestamp_ms(clock) <= deadline, EEXPIRED_DEADLINE);
        assert!(vector::length(&paths) == vector::length(&amounts_in), EINVALID_PATH);
        assert!(vector::length(&paths) <= 5, ETOO_MANY_HOPS); // Limit complexity

        let total_amount_in = coin::value(&token_in);
        assert!(total_amount_in > 0, EINVALID_AMOUNT);

        // Validate that amounts_in sum to total_amount_in
        let mut sum_amounts = 0u64;
        let mut i = 0;
        while (i < vector::length(&amounts_in)) {
            sum_amounts = sum_amounts + *vector::borrow(&amounts_in, i);
            i = i + 1;
        };
        assert!(sum_amounts == total_amount_in, EINVALID_AMOUNT);

        // Execute swaps through each path
        let mut output_coins = vector::empty<Coin<TokenOut>>();
        let mut current_coin = token_in;
        
        i = 0;
        while (i < vector::length(&paths)) {
            let path = vector::borrow(&paths, i);
            let amount_for_path = *vector::borrow(&amounts_in, i);
            
            if (amount_for_path > 0) {
                let coin_for_path = if (i == vector::length(&paths) - 1) {
                    // Last iteration, use remaining coin
                    current_coin
                } else {
                    coin::split(&mut current_coin, amount_for_path, ctx)
                };
                
                let output_coin = execute_swap_exact_input(
                    &mut router.factory,
                    coin_for_path,
                    path,
                    0, // No minimum for individual paths
                    clock
                );
                
                vector::push_back(&mut output_coins, output_coin);
            };
            
            i = i + 1;
        };

        // Merge all output coins
        let mut final_output = vector::pop_back(&mut output_coins);
        while (!vector::is_empty(&output_coins)) {
            let coin_to_merge = vector::pop_back(&mut output_coins);
            coin::join(&mut final_output, coin_to_merge);
        };
        vector::destroy_empty(output_coins);

        let actual_amount_out = coin::value(&final_output);
        assert!(actual_amount_out >= amount_out_min, EINSUFFICIENT_OUTPUT);

        // Update router statistics
        router.total_swaps = router.total_swaps + 1;
        router.total_volume = router.total_volume + total_amount_in;

        // Emit swap event
        event::emit(SwapExecuted {
            sender: tx_context::sender(ctx),
            recipient,
            token_in: type_name::get<TokenIn>(),
            token_out: type_name::get<TokenOut>(),
            amount_in: total_amount_in,
            amount_out: actual_amount_out,
            path_length: vector::length(&paths),
            price_impact: 0, // Would need to calculate combined impact
            fee_paid: 0, // Would need to calculate combined fees
        });

        final_output
    }

    // ==================== Quote Functions ====================

    /// Get quote for exact input swap
    public fun get_amounts_out<TokenIn, TokenOut>(
        router: &Router,
        amount_in: u64,
        clock: &Clock
    ): QuoteResult {
        assert!(amount_in > 0, EINVALID_AMOUNT);
        
        let quote = quoter::get_quote<TokenIn, TokenOut>(&router.factory, amount_in, clock);
        
        // Emit quote event
        event::emit(QuoteRequested {
            sender: @0x0, // No sender context in view function
            token_in: type_name::get<TokenIn>(),
            token_out: type_name::get<TokenOut>(),
            amount_in,
            estimated_out: router_types::get_quote_amount_out(&quote),
            price_impact: router_types::get_quote_price_impact(&quote),
        });
        
        quote
    }

    /// Get quote for exact output swap
    public fun get_amounts_in<TokenIn, TokenOut>(
        router: &Router,
        amount_out: u64,
        clock: &Clock
    ): vector<u64> {
        assert!(amount_out > 0, EINVALID_AMOUNT);
        
        // Get optimal path first
        let path = quoter::find_best_path<TokenIn, TokenOut>(&router.factory);
        
        // Calculate amounts in for each hop
        quoter::get_amounts_in(&router.factory, &path, amount_out, clock)
    }

    /// Get detailed quote breakdown
    public fun get_quote_breakdown<TokenIn, TokenOut>(
        router: &Router,
        amount_in: u64,
        clock: &Clock
    ): (u64, vector<u64>, vector<u64>, u128, u64) {
        quoter::get_quote_breakdown<TokenIn, TokenOut>(&router.factory, amount_in, clock)
    }

    // ==================== Internal Swap Execution ====================

    /// Execute swap through a specific path
    fun execute_swap_exact_input<TokenIn, TokenOut>(
        factory: &mut DLMMFactory,
        mut token_in: Coin<TokenIn>,
        path: &SwapPath,
        amount_out_min: u64,
        clock: &Clock
    ): Coin<TokenOut> {
        let nodes = router_types::get_path_nodes(path);
        assert!(vector::length(nodes) > 0, EINVALID_PATH);
        
        // For single-hop swap (most common case)
        if (vector::length(nodes) == 1) {
            let node = vector::borrow(nodes, 0);
            return execute_single_hop_swap(factory, token_in, node, amount_out_min, clock)
        };
        
        // For multi-hop swaps
        execute_multi_hop_swap(factory, token_in, path, amount_out_min, clock)
    }

    /// Execute single-hop swap
    fun execute_single_hop_swap<TokenIn, TokenOut>(
        factory: &mut DLMMFactory,
        token_in: Coin<TokenIn>,
        node: &PathNode,
        amount_out_min: u64,
        clock: &Clock
    ): Coin<TokenOut> {
        let (pool_id, _token_in, _token_out, _bin_step, _fee, zero_for_one) = 
            router_types::get_path_node_info(node);
        
        // Get pool from factory
        let pool_opt = get_pool_from_factory<TokenIn, TokenOut>(factory, pool_id);
        assert!(std::option::is_some(&pool_opt), EINSUFFICIENT_LIQUIDITY);
        
        let mut pool = std::option::extract(&mut pool_opt);
        let amount_in = coin::value(&token_in);
        
        // Execute router swap
        let amount_out = dlmm_pool::router_swap(&mut pool, amount_in, amount_out_min, zero_for_one, clock);
        
        // Convert balance to coin
        // In practice, router_swap would return coins directly or we'd have proper conversion
        let token_out = coin::from_balance(balance::zero<TokenOut>(), sui::tx_context::dummy());
        
        // Return pool to factory (in practice, this would be handled differently)
        return_pool_to_factory(factory, pool);
        
        // Destroy input coin (it's been consumed)
        coin::destroy_zero(token_in);
        
        token_out
    }

    /// Execute multi-hop swap
    fun execute_multi_hop_swap<TokenIn, TokenOut>(
        factory: &mut DLMMFactory,
        token_in: Coin<TokenIn>,
        path: &SwapPath,
        amount_out_min: u64,
        clock: &Clock
    ): Coin<TokenOut> {
        // Placeholder for multi-hop execution
        // Would need to handle intermediate token conversions
        let _ = factory;
        let _ = path;
        let _ = amount_out_min;
        let _ = clock;
        
        // For now, destroy input and create empty output
        coin::destroy_zero(token_in);
        coin::from_balance(balance::zero<TokenOut>(), sui::tx_context::dummy())
    }

    // ==================== Helper Functions ====================

    /// Get path length
    fun get_path_length(path: &SwapPath): u64 {
        let (hop_count, _, _, _, _) = router_types::get_swap_path_info(path);
        hop_count as u64
    }

    /// Get pool from factory (placeholder)
    fun get_pool_from_factory<TokenA, TokenB>(
        factory: &mut DLMMFactory,
        pool_id: sui::object::ID
    ): std::option::Option<DLMMPool<TokenA, TokenB>> {
        // Placeholder implementation
        let _ = factory;
        let _ = pool_id;
        std::option::none<DLMMPool<TokenA, TokenB>>()
    }

    /// Return pool to factory (placeholder)
    fun return_pool_to_factory<TokenA, TokenB>(
        factory: &mut DLMMFactory,
        pool: DLMMPool<TokenA, TokenB>
    ) {
        // Placeholder implementation
        let _ = factory;
        let _ = pool;
    }

    // ==================== Admin Functions ====================

    /// Pause/unpause router
    public fun set_pause_status(
        router: &mut Router,
        paused: bool,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == router.admin, EINVALID_RECIPIENT);
        router.is_paused = paused;
    }

    /// Update admin
    public fun update_admin(
        router: &mut Router,
        new_admin: address,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == router.admin, EINVALID_RECIPIENT);
        router.admin = new_admin;
    }

    // ==================== View Functions ====================

    /// Get router statistics
    public fun get_router_stats(router: &Router): (u64, u64, bool, u64) {
        (
            router.total_swaps,
            router.total_volume,
            router.is_paused,
            router.created_at
        )
    }

    /// Check if router is paused
    public fun is_paused(router: &Router): bool {
        router.is_paused
    }

    /// Get router admin
    public fun get_admin(router: &Router): address {
        router.admin
    }

    // ==================== Entry Functions ====================

    /// Entry function for exact input swap
    public entry fun swap_exact_tokens_for_tokens_entry<TokenIn, TokenOut>(
        router: &mut Router,
        token_in: Coin<TokenIn>,
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let token_out = swap_exact_tokens_for_tokens<TokenIn, TokenOut>(
            router,
            token_in,
            amount_out_min,
            recipient,
            deadline,
            clock,
            ctx
        );
        
        // Transfer to recipient
        sui::transfer::public_transfer(token_out, recipient);
    }

    /// Entry function for exact output swap
    public entry fun swap_tokens_for_exact_tokens_entry<TokenIn, TokenOut>(
        router: &mut Router,
        token_in: Coin<TokenIn>,
        amount_out: u64,
        amount_in_max: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let (token_out, remaining_token_in) = swap_tokens_for_exact_tokens<TokenIn, TokenOut>(
            router,
            token_in,
            amount_out,
            amount_in_max,
            recipient,
            deadline,
            clock,
            ctx
        );
        
        // Transfer tokens to recipients
        sui::transfer::public_transfer(token_out, recipient);
        
        // Return remaining input token to sender if any
        if (coin::value(&remaining_token_in) > 0) {
            sui::transfer::public_transfer(remaining_token_in, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(remaining_token_in);
        };
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    public fun create_test_router(
        factory: DLMMFactory,
        admin: address,
        ctx: &mut TxContext
    ): Router {
        Router {
            id: object::new(ctx),
            factory,
            admin,
            is_paused: false,
            total_swaps: 0,
            total_volume: 0,
            created_at: 0,
        }
    }

    #[test_only]
    public fun destroy_test_router(router: Router) {
        let Router {
            id,
            factory: _,
            admin: _,
            is_paused: _,
            total_swaps: _,
            total_volume: _,
            created_at: _,
        } = router;
        object::delete(id);
    }
}