module sui_dlmm::factory {
    use sui::tx_context::sender;
    use sui::table::{Self, Table};
    use sui::coin::Coin;
    use sui::clock::Clock;
    use sui::event;
    use std::type_name::{Self, TypeName};
    use std::ascii;
    use std::bcs;
    
    use sui_dlmm::dlmm_pool::{Self, DLMMPool};

    // Error codes
    const EINVALID_BIN_STEP: u64 = 1;
    const EPOOL_ALREADY_EXISTS: u64 = 2;
    const EUNAUTHORIZED: u64 = 3;
    const EINVALID_PROTOCOL_FEE: u64 = 4;

    /// Factory for creating and managing pools
    public struct DLMMFactory has key {
        id: sui::object::UID,
        pools: Table<vector<u8>, sui::object::ID>,    // pool_key -> pool_id mapping
        pool_registry: Table<sui::object::ID, PoolRegistry>, // NEW: pool_id -> registry mapping
        allowed_bin_steps: vector<u16>,               // Allowed bin step values
        protocol_fee_rate: u16,                       // Global protocol fee rate
        pool_count: u64,                              // Total pools created
        admin: address,                               // Admin address for governance
        created_at: u64,                              // Factory creation timestamp
    }

    /// Pool registry entry - Now properly used for pool discovery and analytics
    #[allow(unused_field)] // Suppress warnings for future-use fields
    public struct PoolRegistry has copy, drop, store {
        pool_id: sui::object::ID,
        coin_a: TypeName,
        coin_b: TypeName,
        bin_step: u16,
        creator: address,
        created_at: u64,
    }

    // ==================== Factory Creation ====================

    /// Initialize factory - called once at deployment
    fun init(ctx: &mut sui::tx_context::TxContext) {
        let factory = DLMMFactory {
            id: sui::object::new(ctx),
            pools: table::new(ctx),
            pool_registry: table::new(ctx), // NEW: Initialize registry table
            allowed_bin_steps: vector[1, 5, 10, 25, 50, 100, 200, 500, 1000], // Common bin steps
            protocol_fee_rate: 300, // 3% default
            pool_count: 0,
            admin: sender(ctx),
            created_at: 0, // Will be set properly when we have clock
        };
        sui::transfer::share_object(factory);
    }

    // ==================== Pool Creation ====================

    /// Create a new DLMM pool (returns pool, doesn't share it)
    public fun create_pool<CoinA, CoinB>(
        factory: &mut DLMMFactory,
        bin_step: u16,
        initial_price: u128,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): DLMMPool<CoinA, CoinB> {
        // Validate bin step is allowed
        assert!(vector::contains(&factory.allowed_bin_steps, &bin_step), EINVALID_BIN_STEP);
        
        // Generate pool key and check for duplicates
        let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
        assert!(!table::contains(&factory.pools, pool_key), EPOOL_ALREADY_EXISTS);

        // Create the pool
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
        
        // Register pool in factory pools mapping
        table::add(&mut factory.pools, pool_key, pool_id);
        
        // NEW: Add to pool registry for discovery and analytics
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

        pool
    }

    /// Generate unique pool key from token types and bin_step
    fun generate_pool_key<CoinA, CoinB>(bin_step: u16): vector<u8> {
        let mut key = vector::empty<u8>();
        
        // Get type names and convert directly to bytes
        let type_a = type_name::get<CoinA>();
        let type_b = type_name::get<CoinB>();
        
        // Convert TypeName to bytes using into_string + as_bytes
        let type_a_bytes = ascii::as_bytes(type_name::borrow_string(&type_a));
        let type_b_bytes = ascii::as_bytes(type_name::borrow_string(&type_b));
        
        // Ensure consistent ordering (A < B lexicographically)
        let (first_type_bytes, second_type_bytes) = if (compare_bytes(type_a_bytes, type_b_bytes)) {
            (type_a_bytes, type_b_bytes)
        } else {
            (type_b_bytes, type_a_bytes)
        };
        
        // Construct key: type_a + "::" + type_b + "::" + bin_step
        vector::append(&mut key, *first_type_bytes);
        vector::append(&mut key, b"::");
        vector::append(&mut key, *second_type_bytes);
        vector::append(&mut key, b"::");
        vector::append(&mut key, bcs::to_bytes(&bin_step));
        
        key
    }

    /// Compare two byte vectors lexicographically (a < b)
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
        
        // If all bytes are equal, shorter vector comes first
        len_a < len_b
    }

    // ==================== Pool Registry & Discovery ====================

    /// Get pool ID for a specific token pair and bin step
    public fun get_pool_id<CoinA, CoinB>(
        factory: &DLMMFactory,
        bin_step: u16
    ): std::option::Option<sui::object::ID> {
        let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
        if (table::contains(&factory.pools, pool_key)) {
            std::option::some(*table::borrow(&factory.pools, pool_key))
        } else {
            std::option::none()
        }
    }

    /// Check if pool exists for token pair and bin step
    public fun pool_exists<CoinA, CoinB>(
        factory: &DLMMFactory,
        bin_step: u16
    ): bool {
        let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
        table::contains(&factory.pools, pool_key)
    }

    /// NEW: Get pool registry information by pool ID
    public fun get_pool_registry_info(
        factory: &DLMMFactory,
        pool_id: sui::object::ID
    ): std::option::Option<PoolRegistry> {
        if (table::contains(&factory.pool_registry, pool_id)) {
            std::option::some(*table::borrow(&factory.pool_registry, pool_id))
        } else {
            std::option::none()
        }
    }

    /// NEW: Get pool IDs for specific token pair (FIXED - no tuples)
    public fun get_pools_for_tokens<CoinA, CoinB>(
        factory: &DLMMFactory
    ): vector<sui::object::ID> {
        let mut matching_pools = vector::empty<sui::object::ID>();
        
        // Check common bin steps for this token pair
        let common_steps = vector[1, 5, 10, 25, 50, 100, 200, 500, 1000];
        let mut i = 0;
        
        while (i < vector::length(&common_steps)) {
            let bin_step = *vector::borrow(&common_steps, i);
            let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
            
            if (table::contains(&factory.pools, pool_key)) {
                let pool_id = *table::borrow(&factory.pools, pool_key);
                vector::push_back(&mut matching_pools, pool_id);
            };
            i = i + 1;
        };
        
        matching_pools
    }

    /// NEW: Get detailed pool info by pool ID (FIXED - return separate values)
    public fun get_pool_details(
        factory: &DLMMFactory,
        pool_id: sui::object::ID
    ): (bool, u16, address, u64, TypeName, TypeName) { // (exists, bin_step, creator, created_at, coin_a, coin_b)
        if (table::contains(&factory.pool_registry, pool_id)) {
            let registry = table::borrow(&factory.pool_registry, pool_id);
            (
                true,
                registry.bin_step,
                registry.creator,
                registry.created_at,
                registry.coin_a,
                registry.coin_b
            )
        } else {
            (false, 0, @0x0, 0, type_name::get<u8>(), type_name::get<u8>()) // Dummy types for false case
        }
    }

    /// NEW: Get all pools created by specific address (FIXED - remove unused params)
    public fun get_pools_by_creator(
        _factory: &DLMMFactory,
        _creator: address
    ): vector<sui::object::ID> {
        // Simplified implementation - return empty for now
        // TODO: Implement proper registry iteration when needed
        vector::empty<sui::object::ID>()
    }

    /// Get all pools count
    public fun get_pool_count(factory: &DLMMFactory): u64 {
        factory.pool_count
    }

    /// Get allowed bin steps
    public fun get_allowed_bin_steps(factory: &DLMMFactory): vector<u16> {
        factory.allowed_bin_steps
    }

    /// Check if bin step is allowed
    public fun is_bin_step_allowed(factory: &DLMMFactory, bin_step: u16): bool {
        vector::contains(&factory.allowed_bin_steps, &bin_step)
    }

    // ==================== Governance Functions ====================

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

    /// Remove allowed bin step (admin only)
    public fun remove_allowed_bin_step(
        factory: &mut DLMMFactory,
        bin_step: u16,
        ctx: &sui::tx_context::TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        
        let (found, index) = vector::index_of(&factory.allowed_bin_steps, &bin_step);
        assert!(found, EINVALID_BIN_STEP);
        
        vector::remove(&mut factory.allowed_bin_steps, index);
        
        event::emit(BinStepRemoved {
            factory_id: sui::object::uid_to_inner(&factory.id),
            bin_step,
            admin: factory.admin,
        });
    }

    /// Set protocol fee rate (admin only)
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

    /// Get factory admin
    public fun get_admin(factory: &DLMMFactory): address {
        factory.admin
    }

    /// Get protocol fee rate
    public fun get_protocol_fee_rate(factory: &DLMMFactory): u16 {
        factory.protocol_fee_rate
    }

    // ==================== Utility Functions ====================

    /// Create pool and share it immediately
    public entry fun create_and_share_pool<CoinA, CoinB>(
        factory: &mut DLMMFactory,
        bin_step: u16,
        initial_price: u128,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let pool = create_pool<CoinA, CoinB>(
            factory,
            bin_step,
            initial_price,
            initial_bin_id,
            coin_a,
            coin_b,
            clock,
            ctx
        );
        
        dlmm_pool::share_pool(pool);
    }

    /// Get recommended bin step for token pair based on characteristics
    public fun recommend_bin_step(
        is_stable_pair: bool,
        expected_volatility: u8 // 0-100 scale
    ): u16 {
        if (is_stable_pair) {
            1 // Ultra-tight spread for stablecoins
        } else if (expected_volatility < 20) {
            10 // Low volatility pairs
        } else if (expected_volatility < 50) {
            25 // Medium volatility pairs
        } else if (expected_volatility < 80) {
            100 // High volatility pairs
        } else {
            500 // Very high volatility pairs
        }
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

    public struct BinStepRemoved has copy, drop {
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
    /// Create factory for testing
    public fun create_test_factory(admin: address, ctx: &mut sui::tx_context::TxContext): DLMMFactory {
        DLMMFactory {
            id: sui::object::new(ctx),
            pools: table::new(ctx),
            pool_registry: table::new(ctx), // NEW: Include in test factory
            allowed_bin_steps: vector[1, 5, 10, 25, 50, 100, 200, 500, 1000],
            protocol_fee_rate: 300,
            pool_count: 0,
            admin,
            created_at: 0,
        }
    }

    #[test_only]
    /// Get pool key for testing
    public fun test_generate_pool_key<CoinA, CoinB>(bin_step: u16): vector<u8> {
        generate_pool_key<CoinA, CoinB>(bin_step)
    }

    #[test_only]
    /// Test registry functionality
    public fun test_pool_registry(factory: &DLMMFactory, pool_id: sui::object::ID): bool {
        table::contains(&factory.pool_registry, pool_id)
    }
}