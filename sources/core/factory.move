module sui_dlmm::factory {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{TxContext, sender};
    use sui::table::{Self, Table};
    use sui::coin::Coin;
    use sui::clock::Clock;
    use sui::event;
    use sui::transfer;
    use std::type_name::{Self, TypeName};
    use std::string::{Self, String};
    use std::bcs;
    
    use sui_dlmm::dlmm_pool::{Self, DLMMPool};

    // Error codes
    const EINVALID_BIN_STEP: u64 = 1;
    const EPOOL_ALREADY_EXISTS: u64 = 2;
    const EUNAUTHORIZED: u64 = 3;
    const EINVALID_PROTOCOL_FEE: u64 = 4;

    /// Factory for creating and managing pools
    public struct DLMMFactory has key {
        id: UID,
        pools: Table<vector<u8>, ID>,           // pool_key -> pool_id mapping
        allowed_bin_steps: vector<u16>,          // Allowed bin step values
        protocol_fee_rate: u16,                  // Global protocol fee rate
        pool_count: u64,                         // Total pools created
        admin: address,                          // Admin address for governance
        created_at: u64,                         // Factory creation timestamp
    }

    /// Pool registry entry
    public struct PoolRegistry has copy, drop, store {
        pool_id: ID,
        coin_a: TypeName,
        coin_b: TypeName,
        bin_step: u16,
        creator: address,
        created_at: u64,
    }

    // ==================== Factory Creation ====================

    /// Initialize factory - called once at deployment
    fun init(ctx: &mut TxContext) {
        let factory = DLMMFactory {
            id: object::new(ctx),
            pools: table::new(ctx),
            allowed_bin_steps: vector[1, 5, 10, 25, 50, 100, 200, 500, 1000], // Common bin steps
            protocol_fee_rate: 300, // 3% default
            pool_count: 0,
            admin: sender(ctx),
            created_at: 0, // Will be set properly when we have clock
        };
        transfer::share_object(factory);
    }

    // ==================== Pool Creation ====================

    /// Create a new DLMM pool
    public fun create_pool<CoinA, CoinB>(
        factory: &mut DLMMFactory,
        bin_step: u16,
        initial_price: u128,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut TxContext
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

        let pool_id = object::id(&pool);
        
        // Register pool in factory
        table::add(&mut factory.pools, pool_key, pool_id);
        factory.pool_count = factory.pool_count + 1;

        // Emit pool creation event
        event::emit(PoolCreatedInFactory {
            factory_id: object::uid_to_inner(&factory.id),
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
        
        // Get type names
        let type_a = type_name::get<CoinA>();
        let type_b = type_name::get<CoinB>();
        
        // Ensure consistent ordering (A < B lexicographically)
        let type_a_str = type_name::borrow_string(&type_a);
        let type_b_str = type_name::borrow_string(&type_b);
        
        let (first_type_str, second_type_str) = if (string::bytes(type_a_str) < string::bytes(type_b_str)) {
            (type_a_str, type_b_str)
        } else {
            (type_b_str, type_a_str)
        };
        
        // Construct key: type_a + "::" + type_b + "::" + bin_step
        vector::append(&mut key, *string::bytes(first_type_str));
        vector::append(&mut key, b"::");
        vector::append(&mut key, *string::bytes(second_type_str));
        vector::append(&mut key, b"::");
        vector::append(&mut key, bcs::to_bytes(&bin_step));
        
        key
    }

    // ==================== Pool Registry & Discovery ====================

    /// Get pool ID for a specific token pair and bin step
    public fun get_pool_id<CoinA, CoinB>(
        factory: &DLMMFactory,
        bin_step: u16
    ): option::Option<ID> {
        let pool_key = generate_pool_key<CoinA, CoinB>(bin_step);
        if (table::contains(&factory.pools, pool_key)) {
            option::some(*table::borrow(&factory.pools, pool_key))
        } else {
            option::none()
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
        ctx: &TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        assert!(!vector::contains(&factory.allowed_bin_steps, &bin_step), EINVALID_BIN_STEP);
        
        vector::push_back(&mut factory.allowed_bin_steps, bin_step);
        
        event::emit(BinStepAdded {
            factory_id: object::uid_to_inner(&factory.id),
            bin_step,
            admin: factory.admin,
        });
    }

    /// Remove allowed bin step (admin only)
    public fun remove_allowed_bin_step(
        factory: &mut DLMMFactory,
        bin_step: u16,
        ctx: &TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        
        let (found, index) = vector::index_of(&factory.allowed_bin_steps, &bin_step);
        assert!(found, EINVALID_BIN_STEP);
        
        vector::remove(&mut factory.allowed_bin_steps, index);
        
        event::emit(BinStepRemoved {
            factory_id: object::uid_to_inner(&factory.id),
            bin_step,
            admin: factory.admin,
        });
    }

    /// Set protocol fee rate (admin only)
    public fun set_protocol_fee_rate(
        factory: &mut DLMMFactory,
        protocol_fee_rate: u16,
        ctx: &TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        assert!(protocol_fee_rate <= 5000, EINVALID_PROTOCOL_FEE); // Max 50%
        
        let old_rate = factory.protocol_fee_rate;
        factory.protocol_fee_rate = protocol_fee_rate;
        
        event::emit(ProtocolFeeRateChanged {
            factory_id: object::uid_to_inner(&factory.id),
            old_rate,
            new_rate: protocol_fee_rate,
            admin: factory.admin,
        });
    }

    /// Transfer admin rights
    public fun transfer_admin(
        factory: &mut DLMMFactory,
        new_admin: address,
        ctx: &TxContext
    ) {
        assert!(sender(ctx) == factory.admin, EUNAUTHORIZED);
        
        let old_admin = factory.admin;
        factory.admin = new_admin;
        
        event::emit(AdminTransferred {
            factory_id: object::uid_to_inner(&factory.id),
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
    public fun create_and_share_pool<CoinA, CoinB>(
        factory: &mut DLMMFactory,
        bin_step: u16,
        initial_price: u128,
        initial_bin_id: u32,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        ctx: &mut TxContext
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
        
        transfer::share_object(pool);
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
        factory_id: ID,
        pool_id: ID,
        coin_a: TypeName,
        coin_b: TypeName,
        bin_step: u16,
        initial_price: u128,
        creator: address,
        pool_count: u64,
    }

    public struct BinStepAdded has copy, drop {
        factory_id: ID,
        bin_step: u16,
        admin: address,
    }

    public struct BinStepRemoved has copy, drop {
        factory_id: ID,
        bin_step: u16,
        admin: address,
    }

    public struct ProtocolFeeRateChanged has copy, drop {
        factory_id: ID,
        old_rate: u16,
        new_rate: u16,
        admin: address,
    }

    public struct AdminTransferred has copy, drop {
        factory_id: ID,
        old_admin: address,
        new_admin: address,
    }

    // ==================== Test Helpers ====================

    #[test_only]
    /// Create factory for testing
    public fun create_test_factory(admin: address, ctx: &mut TxContext): DLMMFactory {
        DLMMFactory {
            id: object::new(ctx),
            pools: table::new(ctx),
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
}