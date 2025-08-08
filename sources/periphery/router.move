module sui_dlmm::router {
    use std::type_name::{Self, TypeName};
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::event;

    use sui_dlmm::factory::{Self, DLMMFactory};
    use sui_dlmm::dlmm_pool;
    use sui_dlmm::router_types::{Self, QuoteResult};

    // ==================== Error Codes ====================
    
    const EINVALID_AMOUNT: u64 = 1;
    const EINSUFFICIENT_OUTPUT: u64 = 2;
    const EEXCESSIVE_INPUT: u64 = 3;
    const EEXPIRED_DEADLINE: u64 = 5;
    const EINSUFFICIENT_LIQUIDITY: u64 = 7;
    const ENO_ROUTE_FOUND: u64 = 8;
    const EINVALID_RECIPIENT: u64 = 9;

    // ==================== Constants ====================
    
    const MAX_PRICE_IMPACT_BPS: u128 = 1000; // 10%

    // ==================== Structs ====================

    /// Router configuration and state
    public struct Router has key {
        id: sui::object::UID,
        admin: address,
        is_paused: bool,
        total_swaps: u64,
        total_volume: u64,
        created_at: u64,
    }

    /// Route info struct to replace tuple return type
    public struct RouteInfo has copy, drop {
        pool_id: sui::object::ID,
        bin_step: u16,
        reserves_a: u64,
        reserves_b: u64,
    }

    // ==================== Events ====================

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

    public struct QuoteRequested has copy, drop {
        sender: address,
        token_in: TypeName,
        token_out: TypeName,
        amount_in: u64,
        estimated_out: u64,
        price_impact: u128,
    }

    // ==================== Initialization ====================

    public fun initialize_router(
        admin: address,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Router {
        Router {
            id: sui::object::new(ctx),
            admin,
            is_paused: false,
            total_swaps: 0,
            total_volume: 0,
            created_at: sui::clock::timestamp_ms(clock),
        }
    }

    // ==================== Real Swap Functions ====================

    /// Execute exact input swap with REAL pool operations
    public fun swap_exact_tokens_for_tokens<TokenIn, TokenOut>(
        router: &mut Router,
        factory: &mut DLMMFactory,
        token_in: Coin<TokenIn>,
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Coin<TokenOut> {
        assert!(!router.is_paused, EINSUFFICIENT_LIQUIDITY);
        assert!(sui::clock::timestamp_ms(clock) <= deadline, EEXPIRED_DEADLINE);
        assert!(recipient != @0x0, EINVALID_RECIPIENT);

        let amount_in = coin::value(&token_in);
        assert!(amount_in > 0, EINVALID_AMOUNT);

        // Find best pool for this token pair
        let mut best_pool_id_opt = factory::find_best_pool<TokenIn, TokenOut>(factory);
        assert!(std::option::is_some(&best_pool_id_opt), ENO_ROUTE_FOUND);
        let pool_id = std::option::extract(&mut best_pool_id_opt);

        // Verify pool can handle this swap
        assert!(factory::can_pool_handle_swap<TokenIn, TokenOut>(
            factory, pool_id, amount_in, true
        ), EINSUFFICIENT_LIQUIDITY);

        // Execute swap through actual pool
        let token_out = execute_real_swap<TokenIn, TokenOut>(
            factory,
            pool_id,
            token_in,
            amount_out_min,
            clock,
            ctx
        );

        let actual_amount_out = coin::value(&token_out);
        assert!(actual_amount_out >= amount_out_min, EINSUFFICIENT_OUTPUT);

        // Update router statistics
        router.total_swaps = router.total_swaps + 1;
        router.total_volume = router.total_volume + amount_in;

        // Emit swap event
        event::emit(SwapExecuted {
            sender: sui::tx_context::sender(ctx),
            recipient,
            token_in: type_name::get<TokenIn>(),
            token_out: type_name::get<TokenOut>(),
            amount_in,
            amount_out: actual_amount_out,
            path_length: 1, // Direct swap
            price_impact: 0, // Will be enhanced later
            fee_paid: 0, // Will be enhanced later
        });

        token_out
    }

    /// Execute swap through actual pool stored in factory
    fun execute_real_swap<TokenIn, TokenOut>(
        factory: &mut DLMMFactory,
        pool_id: sui::object::ID,
        token_in: Coin<TokenIn>,
        amount_out_min: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Coin<TokenOut> {
        // Get mutable reference to actual pool
        let pool = factory::borrow_pool_mut<TokenIn, TokenOut>(factory, pool_id);
        
        // Execute actual swap using pool's swap function
        let token_out = dlmm_pool::swap<TokenIn, TokenOut>(
            pool,
            token_in,
            amount_out_min,
            true, // zero_for_one - assume TokenIn->TokenOut
            clock,
            ctx
        );

        token_out
    }

    /// Execute exact output swap with REAL pool operations
    public fun swap_tokens_for_exact_tokens<TokenIn, TokenOut>(
        router: &mut Router,
        factory: &mut DLMMFactory,
        mut token_in: Coin<TokenIn>,
        amount_out: u64,
        amount_in_max: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): (Coin<TokenOut>, Coin<TokenIn>) {
        assert!(!router.is_paused, EINSUFFICIENT_LIQUIDITY);
        assert!(sui::clock::timestamp_ms(clock) <= deadline, EEXPIRED_DEADLINE);
        assert!(recipient != @0x0, EINVALID_RECIPIENT);
        assert!(amount_out > 0, EINVALID_AMOUNT);

        let available_amount_in = coin::value(&token_in);
        assert!(available_amount_in <= amount_in_max, EEXCESSIVE_INPUT);

        // Find best pool
        let mut best_pool_id_opt = factory::find_best_pool<TokenIn, TokenOut>(factory);
        assert!(std::option::is_some(&best_pool_id_opt), ENO_ROUTE_FOUND);
        let pool_id = std::option::extract(&mut best_pool_id_opt);

        // Get quote to calculate required input
        let quote = get_real_quote<TokenIn, TokenOut>(factory, pool_id, available_amount_in);
        let (estimated_out, _, _, _, _) = router_types::get_quote_result_info(&quote);
        
        // Estimate required input (simplified calculation)
        let required_amount_in = if (estimated_out > 0) {
            (available_amount_in * amount_out) / estimated_out
        } else {
            available_amount_in
        };

        assert!(required_amount_in <= amount_in_max, EEXCESSIVE_INPUT);
        assert!(required_amount_in <= available_amount_in, EINSUFFICIENT_LIQUIDITY);

        // Split input coin to use only required amount
        let coin_to_swap = coin::split(&mut token_in, required_amount_in, ctx);
        
        // Execute swap
        let token_out = execute_real_swap<TokenIn, TokenOut>(
            factory,
            pool_id,
            coin_to_swap,
            amount_out,
            clock,
            ctx
        );

        let actual_amount_out = coin::value(&token_out);
        assert!(actual_amount_out >= amount_out, EINSUFFICIENT_OUTPUT);

        // Update router statistics
        router.total_swaps = router.total_swaps + 1;
        router.total_volume = router.total_volume + required_amount_in;

        (token_out, token_in)
    }

    // ==================== Multi-Hop Implementation ====================

    /// Execute multi-hop swap with REAL pool operations
    public fun swap_exact_tokens_multi_hop<TokenIn, TokenMid, TokenOut>(
        router: &mut Router,
        factory: &mut DLMMFactory,
        token_in: Coin<TokenIn>,
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Coin<TokenOut> {
        assert!(!router.is_paused, EINSUFFICIENT_LIQUIDITY);
        assert!(sui::clock::timestamp_ms(clock) <= deadline, EEXPIRED_DEADLINE);

        let amount_in = coin::value(&token_in);
        assert!(amount_in > 0, EINVALID_AMOUNT);

        // First hop: TokenIn -> TokenMid
        let mut pool1_id_opt = factory::find_best_pool<TokenIn, TokenMid>(factory);
        assert!(std::option::is_some(&pool1_id_opt), ENO_ROUTE_FOUND);
        let pool1_id = std::option::extract(&mut pool1_id_opt);

        let token_mid = execute_real_swap<TokenIn, TokenMid>(
            factory,
            pool1_id,
            token_in,
            0, // No minimum for intermediate step
            clock,
            ctx
        );

        // Second hop: TokenMid -> TokenOut
        let mut pool2_id_opt = factory::find_best_pool<TokenMid, TokenOut>(factory);
        assert!(std::option::is_some(&pool2_id_opt), ENO_ROUTE_FOUND);
        let pool2_id = std::option::extract(&mut pool2_id_opt);

        let token_out = execute_real_swap<TokenMid, TokenOut>(
            factory,
            pool2_id,
            token_mid,
            amount_out_min,
            clock,
            ctx
        );

        let actual_amount_out = coin::value(&token_out);
        assert!(actual_amount_out >= amount_out_min, EINSUFFICIENT_OUTPUT);

        // Update router statistics
        router.total_swaps = router.total_swaps + 1;
        router.total_volume = router.total_volume + amount_in;

        // Emit multi-hop swap event
        event::emit(SwapExecuted {
            sender: sui::tx_context::sender(ctx),
            recipient,
            token_in: type_name::get<TokenIn>(),
            token_out: type_name::get<TokenOut>(),
            amount_in,
            amount_out: actual_amount_out,
            path_length: 2, // Two hops
            price_impact: 0,
            fee_paid: 0,
        });

        token_out
    }

    // ==================== Quote Functions ====================

    /// Get REAL quote using actual pool data
    public fun get_amounts_out<TokenIn, TokenOut>(
        _router: &Router,
        factory: &DLMMFactory,
        amount_in: u64,
        _clock: &Clock
    ): QuoteResult {
        assert!(amount_in > 0, EINVALID_AMOUNT);
        
        // Find best pool for quote
        let best_pool_id_opt = factory::find_best_pool<TokenIn, TokenOut>(factory);
        
        if (std::option::is_none(&best_pool_id_opt)) {
            // Return empty quote if no pool found
            return create_empty_quote()
        };
        
        let mut best_pool_id_opt_mut = best_pool_id_opt;
        let pool_id = std::option::extract(&mut best_pool_id_opt_mut);
        
        // Get quote from actual pool
        let quote = get_real_quote<TokenIn, TokenOut>(factory, pool_id, amount_in);
        
        // Emit quote event
        let (amount_out, _, price_impact, _, _) = router_types::get_quote_result_info(&quote);
        event::emit(QuoteRequested {
            sender: @0x0,
            token_in: type_name::get<TokenIn>(),
            token_out: type_name::get<TokenOut>(),
            amount_in,
            estimated_out: amount_out,
            price_impact,
        });
        
        quote
    }

    /// Get quote from actual pool data
    fun get_real_quote<TokenIn, TokenOut>(
        factory: &DLMMFactory,
        pool_id: sui::object::ID,
        amount_in: u64
    ): QuoteResult {
        // Get pool data using the PoolData struct
        let pool_data_opt = factory::get_pool_data<TokenIn, TokenOut>(factory, pool_id);
        
        if (std::option::is_none(&pool_data_opt)) {
            return create_empty_quote()
        };
        
        let mut pool_data_opt_mut = pool_data_opt;
        let pool_data = std::option::extract(&mut pool_data_opt_mut);
        
        // Extract data from PoolData struct
        let (bin_step, reserves_a, reserves_b, _current_price, is_active) = 
            factory::extract_pool_data(&pool_data);
            
        if (!is_active || reserves_a == 0 || reserves_b == 0) {
            return create_empty_quote()
        };

        // Calculate actual output using pool's simulation
        let pool = factory::borrow_pool<TokenIn, TokenOut>(factory, pool_id);
        let (amount_out, total_fee, price_impact) = dlmm_pool::simulate_swap_for_router(
            pool, amount_in, true
        );

        // Create path for this direct swap
        let path_node = router_types::create_path_node(
            pool_id,
            type_name::get<TokenIn>(),
            type_name::get<TokenOut>(),
            bin_step,
            total_fee,
            reserves_a,
            reserves_b,
            true
        );
        
        let mut nodes = std::vector::empty();
        std::vector::push_back(&mut nodes, path_node);
        let swap_path = router_types::create_swap_path(nodes, 0, 0);

        // Create quote result
        router_types::create_quote_result(
            amount_out,
            amount_in,
            price_impact,
            total_fee,
            150000, // Estimated gas cost
            swap_path,
            amount_out > 0 && price_impact <= MAX_PRICE_IMPACT_BPS
        )
    }

    /// Create empty quote for when no route is found
    fun create_empty_quote(): QuoteResult {
        let empty_path = router_types::create_swap_path(std::vector::empty(), 0, 0);
        router_types::create_quote_result(0, 0, 0, 0, 0, empty_path, false)
    }

    // ==================== Liquidity Functions ====================

    /// Add liquidity to pool through router
    public fun add_liquidity<CoinA, CoinB>(
        router: &mut Router,
        factory: &mut DLMMFactory,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        bin_step: u16,
        bin_id: u32,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): u64 {
        assert!(!router.is_paused, EINSUFFICIENT_LIQUIDITY);
        
        // Find or create pool
        let pool_id_opt = factory::get_pool_id<CoinA, CoinB>(factory, bin_step);
        
        let pool_id = if (std::option::is_some(&pool_id_opt)) {
            let mut pool_id_opt_mut = pool_id_opt;
            std::option::extract(&mut pool_id_opt_mut)
        } else {
            // Create new pool if doesn't exist
            let initial_price = sui_dlmm::bin_math::calculate_bin_price(bin_id, bin_step);
            factory::create_and_store_pool<CoinA, CoinB>(
                factory,
                bin_step,
                initial_price,
                bin_id,
                coin::zero<CoinA>(ctx), // Empty coins for pool creation
                coin::zero<CoinB>(ctx),
                clock,
                ctx
            )
        };

        // Add liquidity to specific bin
        let pool = factory::borrow_pool_mut<CoinA, CoinB>(factory, pool_id);
        let shares = dlmm_pool::add_liquidity_to_bin<CoinA, CoinB>(
            pool,
            bin_id,
            coin_a,
            coin_b,
            clock,
            ctx
        );

        shares
    }

    // ==================== Admin Functions ====================

    /// Pause/unpause router
    public fun set_pause_status(
        router: &mut Router,
        paused: bool,
        ctx: &sui::tx_context::TxContext
    ) {
        assert!(sui::tx_context::sender(ctx) == router.admin, EINVALID_RECIPIENT);
        router.is_paused = paused;
    }

    /// Update admin
    public fun update_admin(
        router: &mut Router,
        new_admin: address,
        ctx: &sui::tx_context::TxContext
    ) {
        assert!(sui::tx_context::sender(ctx) == router.admin, EINVALID_RECIPIENT);
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

    /// Get best route for token pair (FIXED: Returns struct instead of tuple)
    public fun get_best_route<TokenIn, TokenOut>(
        factory: &DLMMFactory
    ): std::option::Option<RouteInfo> {
        let best_pool_id_opt = factory::find_best_pool<TokenIn, TokenOut>(factory);
        
        if (std::option::is_none(&best_pool_id_opt)) {
            return std::option::none()
        };
        
        let mut best_pool_id_opt_mut = best_pool_id_opt;
        let pool_id = std::option::extract(&mut best_pool_id_opt_mut);
        
        let pool_data_opt = factory::get_pool_data<TokenIn, TokenOut>(factory, pool_id);
        if (std::option::is_none(&pool_data_opt)) {
            return std::option::none()
        };
        
        let mut pool_data_opt_mut = pool_data_opt;
        let pool_data = std::option::extract(&mut pool_data_opt_mut);
        let (bin_step, reserves_a, reserves_b, _, _) = factory::extract_pool_data(&pool_data);
        
        let route_info = RouteInfo {
            pool_id,
            bin_step,
            reserves_a,
            reserves_b,
        };
        
        std::option::some(route_info)
    }

    /// Extract route info data
    public fun extract_route_info(route: &RouteInfo): (sui::object::ID, u16, u64, u64) {
        (route.pool_id, route.bin_step, route.reserves_a, route.reserves_b)
    }

    // ==================== Entry Functions ====================

    /// Entry function for exact input swap
    public entry fun swap_exact_tokens_for_tokens_entry<TokenIn, TokenOut>(
        router: &mut Router,
        factory: &mut DLMMFactory,
        token_in: Coin<TokenIn>,
        amount_out_min: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let token_out = swap_exact_tokens_for_tokens<TokenIn, TokenOut>(
            router,
            factory,
            token_in,
            amount_out_min,
            recipient,
            deadline,
            clock,
            ctx
        );
        
        sui::transfer::public_transfer(token_out, recipient);
    }

    /// Entry function for exact output swap
    public entry fun swap_tokens_for_exact_tokens_entry<TokenIn, TokenOut>(
        router: &mut Router,
        factory: &mut DLMMFactory,
        token_in: Coin<TokenIn>,
        amount_out: u64,
        amount_in_max: u64,
        recipient: address,
        deadline: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let (token_out, remaining_token_in) = swap_tokens_for_exact_tokens<TokenIn, TokenOut>(
            router,
            factory,
            token_in,
            amount_out,
            amount_in_max,
            recipient,
            deadline,
            clock,
            ctx
        );
        
        sui::transfer::public_transfer(token_out, recipient);
        
        if (coin::value(&remaining_token_in) > 0) {
            sui::transfer::public_transfer(remaining_token_in, sui::tx_context::sender(ctx));
        } else {
            coin::destroy_zero(remaining_token_in);
        };
    }

    /// Entry function for adding liquidity
    public entry fun add_liquidity_entry<CoinA, CoinB>(
        router: &mut Router,
        factory: &mut DLMMFactory,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        bin_step: u16,
        bin_id: u32,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let _shares = add_liquidity<CoinA, CoinB>(
            router,
            factory,
            coin_a,
            coin_b,
            bin_step,
            bin_id,
            clock,
            ctx
        );
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    public fun create_test_router(
        admin: address,
        ctx: &mut sui::tx_context::TxContext
    ): Router {
        Router {
            id: sui::object::new(ctx),
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
            admin: _,
            is_paused: _,
            total_swaps: _,
            total_volume: _,
            created_at: _,
        } = router;
        sui::object::delete(id);
    }
}