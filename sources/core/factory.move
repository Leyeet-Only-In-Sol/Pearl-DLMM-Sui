module sui_dlmm::factory {
    use sui::tx_context::sender;
    use sui::table::{Self, Table};
    use sui::coin::Coin;
    use sui::clock::Clock;
    use sui::event;
    use sui::dynamic_object_field;
    use std::type_name::{Self, TypeName};
    use std::ascii;
    use std::bcs;
    
    use sui_dlmm::dlmm_pool::{Self, DLMMPool};

    // Error codes
    const EINVALID_BIN_STEP: u64 = 1;
    const EPOOL_ALREADY_EXISTS: u64 = 2;
    const EUNAUTHORIZED: u64 = 3;
    const EINVALID_PROTOCOL_FEE: u64 = 4; // Now used in set_protocol_fee_rate
    const EPOOL_NOT_FOUND: u64 = 5;

    /// Factory for creating and managing pools with real storage
    public struct DLMMFactory has key {
        id: sui::object::UID,
        pools: Table<vector<u8>, sui::object::ID>,
        pool_registry: Table<sui::object::ID, PoolRegistry>,
        allowed_bin_steps: vector<u16>,
        protocol_fee_rate: u16,
        pool_count: u64,
        admin: address,
        created_at: u64,
    }

    /// Pool registry entry
    public struct PoolRegistry has copy, drop, store {
        pool_id: sui::object::ID,
        coin_a: TypeName,
        coin_b: TypeName,
        bin_step: u16,
        creator: address,
        created_at: u64,
    }

    /// Pool data struct to replace tuple return type
    public struct PoolData has copy, drop {
        bin_step: u16,
        reserves_a: u64,
        reserves_b: u64,
        current_price: u128,
        is_active: bool,
    }

    /// Pool wrapper for dynamic object fields (FIXED: Added store ability)
    public struct PoolWrapper<phantom CoinA, phantom CoinB> has key, store {
        id: sui::object::UID,
        pool: DLMMPool<CoinA, CoinB>,
    }

    // ==================== Factory Creation ====================

    fun init(ctx: &mut sui::tx_context::TxContext) {
        let factory = DLMMFactory {
            id: sui::object::new(ctx),
            pools: table::new(ctx),
            pool_registry: table::new(ctx),
            allowed_bin_steps: vector[1, 5, 10, 25, 50, 100, 200, 500, 1000],
            protocol_fee_rate: 300, // 3% default
            pool_count: 0,
            admin: sender(ctx),
            created_at: 0,
        };
        sui::transfer::share_object(factory);
    }

    // ==================== Pool Creation & Storage ====================

    /// Create and store pool in factory
    public fun create_and_store_pool<CoinA, CoinB>(
        factory: &mut DLMMFactory,
        bin_step: u16,
        initial_price: u128,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): sui::object::ID {
        // Validate bin step is allowed
        assert!(vector::contains(&factory.allowed_bin_steps, &bin_step), EINVALID_BIN_STEP);
        
        // Generate pool key and check for duplicates
        let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
        assert!(!table::contains(&factory.pools, pool_key), EPOOL_ALREADY_EXISTS);

        // Create the actual pool
        let pool = dlmm_pool::create_pool<CoinA, CoinB>(
            bin_step,
            initial_bin_id,
            initial_price,
            factory.protocol_fee_rate,
            coin_a,
            coin_b,
            clock,
            ctx
        );

        let pool_id = sui::object::id(&pool);
        let current_time = sui::clock::timestamp_ms(clock);

        // Store pool using dynamic object fields
        let pool_wrapper = PoolWrapper {
            id: sui::object::new(ctx),
            pool,
        };
        
        dynamic_object_field::add(&mut factory.id, pool_id, pool_wrapper);
        
        // Register pool in mappings
        table::add(&mut factory.pools, pool_key, pool_id);
        
        let registry_entry = PoolRegistry {
            pool_id,
            coin_a: type_name::get<CoinA>(),
            coin_b: type_name::get<CoinB>(),
            bin_step,
            creator: sender(ctx),
            created_at: current_time,
        };
        table::add(&mut factory.pool_registry, pool_id, registry_entry);
        
        factory.pool_count = factory.pool_count + 1;

        // Emit pool creation event
        event::emit(PoolCreatedInFactory {
            factory_id: sui::object::uid_to_inner(&factory.id),
            pool_id,
            coin_a: type_name::get<CoinA>(),
            coin_b: type_name::get<CoinB>(),
            bin_step,
            initial_price,
            creator: sender(ctx),
            pool_count: factory.pool_count,
        });

        pool_id
    }

    // ==================== Pool Access Functions ====================

    /// Get mutable reference to pool for swaps
    public fun borrow_pool_mut<CoinA, CoinB>(
        factory: &mut DLMMFactory,
        pool_id: sui::object::ID
    ): &mut DLMMPool<CoinA, CoinB> {
        assert!(dynamic_object_field::exists_(&factory.id, pool_id), EPOOL_NOT_FOUND);
        
        let pool_wrapper: &mut PoolWrapper<CoinA, CoinB> = 
            dynamic_object_field::borrow_mut(&mut factory.id, pool_id);
        
        &mut pool_wrapper.pool
    }

    /// Get immutable reference to pool for queries
    public fun borrow_pool<CoinA, CoinB>(
        factory: &DLMMFactory,
        pool_id: sui::object::ID
    ): &DLMMPool<CoinA, CoinB> {
        assert!(dynamic_object_field::exists_(&factory.id, pool_id), EPOOL_NOT_FOUND);
        
        let pool_wrapper: &PoolWrapper<CoinA, CoinB> = 
            dynamic_object_field::borrow(&factory.id, pool_id);
        
        &pool_wrapper.pool
    }

    /// Check if pool exists and is accessible
    public fun pool_exists_in_factory(
        factory: &DLMMFactory,
        pool_id: sui::object::ID
    ): bool {
        dynamic_object_field::exists_(&factory.id, pool_id)
    }

    // ==================== Pool Discovery ====================

    /// Get pool ID for specific token pair and bin step
    public fun get_pool_id<CoinA, CoinB>(
        factory: &DLMMFactory,
        bin_step: u16
    ): std::option::Option<sui::object::ID> {
        let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
        if (table::contains(&factory.pools, pool_key)) {
            let pool_id = *table::borrow(&factory.pools, pool_key);
            // Verify pool actually exists in storage
            if (pool_exists_in_factory(factory, pool_id)) {
                std::option::some(pool_id)
            } else {
                std::option::none()
            }
        } else {
            std::option::none()
        }
    }

    /// Find the best pool for token pair
    public fun find_best_pool<CoinA, CoinB>(
        factory: &DLMMFactory
    ): std::option::Option<sui::object::ID> {
        let mut best_pool_id = std::option::none<sui::object::ID>();
        let mut best_score = 0u64;
        
        // Check all allowed bin steps for this token pair
        let mut i = 0;
        while (i < vector::length(&factory.allowed_bin_steps)) {
            let bin_step = *vector::borrow(&factory.allowed_bin_steps, i);
            
            if (pool_exists<CoinA, CoinB>(factory, bin_step)) {
                let mut pool_id_opt = get_pool_id<CoinA, CoinB>(factory, bin_step);
                if (std::option::is_some(&pool_id_opt)) {
                    let pool_id = std::option::extract(&mut pool_id_opt);
                    
                    // Calculate pool score based on liquidity and activity
                    let score = calculate_pool_score<CoinA, CoinB>(factory, pool_id);
                    
                    if (score > best_score) {
                        best_score = score;
                        best_pool_id = std::option::some(pool_id);
                    };
                };
            };
            i = i + 1;
        };
        
        best_pool_id
    }

    /// Calculate pool quality score for routing decisions
    fun calculate_pool_score<CoinA, CoinB>(
        factory: &DLMMFactory,
        pool_id: sui::object::ID
    ): u64 {
        if (!pool_exists_in_factory(factory, pool_id)) return 0;
        
        let pool = borrow_pool<CoinA, CoinB>(factory, pool_id);
        let (_, _, reserves_a, reserves_b, total_swaps, _, _, is_active) = dlmm_pool::get_pool_info(pool);
        
        if (!is_active) return 0;
        
        // Score based on liquidity and activity
        let liquidity_score = (reserves_a + reserves_b) / 1000; // Scale down
        let activity_score = total_swaps * 10;
        
        liquidity_score + activity_score
    }

    // ==================== Pool Information Functions ====================

    /// Get comprehensive pool data (FIXED: Returns struct instead of tuple)
    public fun get_pool_data<CoinA, CoinB>(
        factory: &DLMMFactory,
        pool_id: sui::object::ID
    ): std::option::Option<PoolData> {
        if (!pool_exists_in_factory(factory, pool_id)) {
            return std::option::none()
        };
        
        let pool = borrow_pool<CoinA, CoinB>(factory, pool_id);
        let (bin_step, _, reserves_a, reserves_b, _, _, _, is_active) = dlmm_pool::get_pool_info(pool);
        let current_price = dlmm_pool::get_current_price(pool);
        
        let pool_data = PoolData {
            bin_step,
            reserves_a,
            reserves_b,
            current_price,
            is_active,
        };
        
        std::option::some(pool_data)
    }

    /// Extract data from PoolData struct
    public fun extract_pool_data(data: &PoolData): (u16, u64, u64, u128, bool) {
        (data.bin_step, data.reserves_a, data.reserves_b, data.current_price, data.is_active)
    }

    /// Get pool reserves for specific pool
    public fun get_pool_reserves<CoinA, CoinB>(
        factory: &DLMMFactory,
        pool_id: sui::object::ID
    ): (u64, u64) {
        if (!pool_exists_in_factory(factory, pool_id)) {
            return (0, 0)
        };
        
        let pool = borrow_pool<CoinA, CoinB>(factory, pool_id);
        dlmm_pool::get_pool_reserves(pool)
    }

    /// Check if pool can handle swap amount
    public fun can_pool_handle_swap<CoinA, CoinB>(
        factory: &DLMMFactory,
        pool_id: sui::object::ID,
        amount_in: u64,
        zero_for_one: bool
    ): bool {
        if (!pool_exists_in_factory(factory, pool_id)) {
            return false
        };
        
        let pool = borrow_pool<CoinA, CoinB>(factory, pool_id);
        dlmm_pool::can_handle_swap_amount(pool, amount_in, zero_for_one)
    }

    // ==================== Utility Functions ====================

    /// Generate unique pool key from token types and bin_step
    fun generate_pool_key<CoinA, CoinB>(bin_step: u16): vector<u8> {
        let mut key = vector::empty<u8>();
        
        let type_a = type_name::get<CoinA>();
        let type_b = type_name::get<CoinB>();
        
        let type_a_bytes = ascii::as_bytes(type_name::borrow_string(&type_a));
        let type_b_bytes = ascii::as_bytes(type_name::borrow_string(&type_b));
        
        let (first_type_bytes, second_type_bytes) = if (compare_bytes(type_a_bytes, type_b_bytes)) {
            (type_a_bytes, type_b_bytes)
        } else {
            (type_b_bytes, type_a_bytes)
        };
        
        vector::append(&mut key, *first_type_bytes);
        vector::append(&mut key, b"::");
        vector::append(&mut key, *second_type_bytes);
        vector::append(&mut key, b"::");
        vector::append(&mut key, bcs::to_bytes(&bin_step));
        
        key
    }

    /// Compare two byte vectors lexicographically
    fun compare_bytes(a: &vector<u8>, b: &vector<u8>): bool {
        let len_a = vector::length(a);
        let len_b = vector::length(b);
        let min_len = if (len_a < len_b) len_a else len_b;
        
        let mut i = 0;
        while (i < min_len) {
            let byte_a = *vector::borrow(a, i);
            let byte_b = *vector::borrow(b, i);
            
            if (byte_a < byte_b) return true;
            if (byte_a > byte_b) return false;
            i = i + 1;
        };
        
        len_a < len_b
    }

    /// Check if pool exists for token pair and bin step
    public fun pool_exists<CoinA, CoinB>(
        factory: &DLMMFactory,
        bin_step: u16
    ): bool {
        let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
        table::contains(&factory.pools, pool_key)
    }

    /// Get all pools for specific token pair
    public fun get_pools_for_tokens<CoinA, CoinB>(
        factory: &DLMMFactory
    ): vector<sui::object::ID> {
        let mut matching_pools = vector::empty<sui::object::ID>();
        
        let mut i = 0;
        while (i < vector::length(&factory.allowed_bin_steps)) {
            let bin_step = *vector::borrow(&factory.allowed_bin_steps, i);
            
            if (pool_exists<CoinA, CoinB>(factory, bin_step)) {
                let mut pool_id_opt = get_pool_id<CoinA, CoinB>(factory, bin_step);
                if (std::option::is_some(&pool_id_opt)) {
                    vector::push_back(&mut matching_pools, std::option::extract(&mut pool_id_opt));
                };
            };
            i = i + 1;
        };
        
        matching_pools
    }

    // ==================== Admin Functions ====================

    /// Set protocol fee rate (admin only) - NOW USES THE CONSTANT
    public fun set_protocol_fee_rate(
        factory: &mut DLMMFactory,
        protocol_fee_rate: u16,
        ctx: &sui::tx_context::TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        assert!(protocol_fee_rate <= 5000, EINVALID_PROTOCOL_FEE); // Max 50%
        
        let old_rate = factory.protocol_fee_rate;
        factory.protocol_fee_rate = protocol_fee_rate;
        
        event::emit(ProtocolFeeRateChanged {
            factory_id: sui::object::uid_to_inner(&factory.id),
            old_rate,
            new_rate: protocol_fee_rate,
            admin: factory.admin,
        });
    }

    /// Add allowed bin step (admin only)
    public fun add_allowed_bin_step(
        factory: &mut DLMMFactory,
        bin_step: u16,
        ctx: &sui::tx_context::TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        assert!(!vector::contains(&factory.allowed_bin_steps, &bin_step), EINVALID_BIN_STEP);
        
        vector::push_back(&mut factory.allowed_bin_steps, bin_step);
        
        event::emit(BinStepAdded {
            factory_id: sui::object::uid_to_inner(&factory.id),
            bin_step,
            admin: factory.admin,
        });
    }

    /// Transfer admin rights
    public fun transfer_admin(
        factory: &mut DLMMFactory,
        new_admin: address,
        ctx: &sui::tx_context::TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        
        let old_admin = factory.admin;
        factory.admin = new_admin;
        
        event::emit(AdminTransferred {
            factory_id: sui::object::uid_to_inner(&factory.id),
            old_admin,
            new_admin,
        });
    }

    // ==================== Entry Functions ====================

    /// Create pool optimized for router usage
    public entry fun create_pool_for_router<CoinA, CoinB>(
        factory: &mut DLMMFactory,
        bin_step: u16,
        initial_price: u128,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let _pool_id = create_and_store_pool<CoinA, CoinB>(
            factory,
            bin_step,
            initial_price,
            initial_bin_id,
            coin_a,
            coin_b,
            clock,
            ctx
        );
        
        // Pool is automatically stored in factory, no need to share
    }

    // ==================== View Functions ====================

    /// Get factory information
    public fun get_factory_info(factory: &DLMMFactory): (u64, u16, address, vector<u16>) {
        (
            factory.pool_count,
            factory.protocol_fee_rate,
            factory.admin,
            factory.allowed_bin_steps
        )
    }

    /// Get pool count
    public fun get_pool_count(factory: &DLMMFactory): u64 {
        factory.pool_count
    }

    /// Get allowed bin steps
    public fun get_allowed_bin_steps(factory: &DLMMFactory): vector<u16> {
        factory.allowed_bin_steps
    }

    /// Get admin address
    public fun get_admin(factory: &DLMMFactory): address {
        factory.admin
    }

    /// Get protocol fee rate
    public fun get_protocol_fee_rate(factory: &DLMMFactory): u16 {
        factory.protocol_fee_rate
    }

    // ==================== Events ====================

    public struct PoolCreatedInFactory has copy, drop {
        factory_id: sui::object::ID,
        pool_id: sui::object::ID,
        coin_a: TypeName,
        coin_b: TypeName,
        bin_step: u16,
        initial_price: u128,
        creator: address,
        pool_count: u64,
    }

    public struct BinStepAdded has copy, drop {
        factory_id: sui::object::ID,
        bin_step: u16,
        admin: address,
    }

    public struct ProtocolFeeRateChanged has copy, drop {
        factory_id: sui::object::ID,
        old_rate: u16,
        new_rate: u16,
        admin: address,
    }

    public struct AdminTransferred has copy, drop {
        factory_id: sui::object::ID,
        old_admin: address,
        new_admin: address,
    }

    // ==================== Test Helpers ====================

    #[test_only]
    public fun create_test_factory_with_storage(admin: address, ctx: &mut sui::tx_context::TxContext): DLMMFactory {
        DLMMFactory {
            id: sui::object::new(ctx),
            pools: table::new(ctx),
            pool_registry: table::new(ctx),
            allowed_bin_steps: vector[1, 5, 10, 25, 50, 100, 200, 500, 1000],
            protocol_fee_rate: 300,
            pool_count: 0,
            admin,
            created_at: 0,
        }
    }

    #[test_only]
    public fun transfer_factory_for_testing(factory: DLMMFactory, recipient: address) {
        sui::transfer::transfer(factory, recipient);
    }
}