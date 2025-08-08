#[test_only]
module sui_dlmm::factory_tests {
    use sui::test_scenario::{Self as test};
    use sui::test_utils::assert_eq;
    use sui::coin;
    use sui::clock;
    
    use sui_dlmm::factory;
    use sui_dlmm::dlmm_pool;
    use sui_dlmm::bin_math;

    // Test tokens
    public struct USDC has drop {}
    public struct ETH has drop {}
    public struct BTC has drop {}

    const ADMIN: address = @0x1;
    const ALICE: address = @0x2;

    const INITIAL_USDC: u64 = 10000000; // 10M USDC
    const INITIAL_ETH: u64 = 3000;      // 3K ETH
    const INITIAL_BTC: u64 = 150;       // 150 BTC

    // ==================== 🏗️ FACTORY CREATION TESTS ====================

    #[test]
    fun test_factory_initialization() {
        let mut scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== FACTORY INITIALIZATION TEST ==="));
        
        // Create factory
        let factory = factory::create_test_factory_with_storage(ADMIN, test::ctx(&mut scenario));
        
        // Verify initial state
        assert_eq(factory::get_pool_count(&factory), 0);
        assert_eq(factory::get_admin(&factory), ADMIN);
        assert!(factory::get_protocol_fee_rate(&factory) > 0, 0);
        
        let allowed_steps = factory::get_allowed_bin_steps(&factory);
        assert!(vector::length(&allowed_steps) > 0, 0);
        
        // Check default allowed bin steps
        assert!(vector::contains(&allowed_steps, &25), 0); // 0.25%
        assert!(vector::contains(&allowed_steps, &100), 0); // 1%
        assert!(vector::contains(&allowed_steps, &500), 0); // 5%
        
        let (pool_count, protocol_fee, admin, steps) = factory::get_factory_info(&factory);
        assert_eq(pool_count, 0);
        assert!(protocol_fee > 0, 0);
        assert_eq(admin, ADMIN);
        assert_eq(vector::length(&steps), vector::length(&allowed_steps));
        
        std::debug::print(&std::string::utf8(b"Protocol fee rate: "));
        std::debug::print(&protocol_fee);
        std::debug::print(&std::string::utf8(b"Allowed bin steps: "));
        std::debug::print(&vector::length(&allowed_steps));
        
        std::debug::print(&std::string::utf8(b"✅ Factory initialization test passed"));
        
        // Cleanup
        factory::transfer_factory_for_testing(factory, ADMIN);
        test::end(scenario);
    }

    #[test]
    fun test_factory_pool_creation() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(test::ctx(&mut scenario));
        
        std::debug::print(&std::string::utf8(b"=== FACTORY POOL CREATION TEST ==="));
        
        // Create factory
        let mut factory = factory::create_test_factory_with_storage(ADMIN, test::ctx(&mut scenario));
        
        // Verify initial state
        assert_eq(factory::get_pool_count(&factory), 0);
        
        // Test pool creation with real coins
        let coin_a = coin::mint_for_testing<USDC>(INITIAL_USDC, test::ctx(&mut scenario));
        let coin_b = coin::mint_for_testing<ETH>(INITIAL_ETH, test::ctx(&mut scenario));
        
        let initial_bin_id = 1000u32;
        let bin_step = 25u16;
        let initial_price = bin_math::calculate_bin_price(initial_bin_id, bin_step);
        
        // Create and store pool
        let pool_id = factory::create_and_store_pool<USDC, ETH>(
            &mut factory,
            bin_step,
            initial_price,
            initial_bin_id,
            coin_a,
            coin_b,
            &clock,
            test::ctx(&mut scenario)
        );
        
        // Verify pool was created and stored
        assert_eq(factory::get_pool_count(&factory), 1);
        assert!(factory::pool_exists_in_factory(&factory, pool_id), 0);
        assert!(factory::pool_exists<USDC, ETH>(&factory, bin_step), 0);
        
        // Test pool retrieval
        let pool_id_opt = factory::get_pool_id<USDC, ETH>(&factory, bin_step);
        assert!(std::option::is_some(&pool_id_opt), 0);
        
        let mut pool_id_opt_mut = pool_id_opt;
        let retrieved_pool_id = std::option::extract(&mut pool_id_opt_mut);
        assert_eq(retrieved_pool_id, pool_id);
        
        // Test pool data extraction
        let pool_data_opt = factory::get_pool_data<USDC, ETH>(&factory, pool_id);
        assert!(std::option::is_some(&pool_data_opt), 0);
        
        let mut pool_data_opt_mut = pool_data_opt;
        let pool_data = std::option::extract(&mut pool_data_opt_mut);
        let (extracted_bin_step, reserves_a, reserves_b, current_price, is_active) = 
            factory::extract_pool_data(&pool_data);
        
        assert_eq(extracted_bin_step, bin_step);
        assert!(reserves_a > 0, 0);
        assert!(reserves_b > 0, 0);
        assert!(current_price > 0, 0);
        assert!(is_active, 0);
        
        std::debug::print(&std::string::utf8(b"Pool ID created: "));
        std::debug::print(&sui::object::id_to_address(&pool_id));
        std::debug::print(&std::string::utf8(b"Reserves A: "));
        std::debug::print(&reserves_a);
        std::debug::print(&std::string::utf8(b"Reserves B: "));
        std::debug::print(&reserves_b);
        
        std::debug::print(&std::string::utf8(b"✅ Factory pool creation test passed"));
        
        // Cleanup
        factory::transfer_factory_for_testing(factory, ADMIN);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_factory_pool_discovery() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(test::ctx(&mut scenario));
        
        std::debug::print(&std::string::utf8(b"=== FACTORY POOL DISCOVERY TEST ==="));
        
        let mut factory = factory::create_test_factory_with_storage(ADMIN, test::ctx(&mut scenario));
        
        // Create multiple pools with different bin steps
        let bin_steps = vector[25u16, 50u16, 100u16];
        let mut pool_ids = vector::empty<sui::object::ID>();
        
        let mut i = 0;
        while (i < vector::length(&bin_steps)) {
            let bin_step = *vector::borrow(&bin_steps, i);
            let coin_a = coin::mint_for_testing<USDC>(1000000, test::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<ETH>(300, test::ctx(&mut scenario));
            
            let initial_price = bin_math::calculate_bin_price(1000, bin_step);
            let pool_id = factory::create_and_store_pool<USDC, ETH>(
                &mut factory,
                bin_step,
                initial_price,
                1000,
                coin_a,
                coin_b,
                &clock,
                test::ctx(&mut scenario)
            );
            
            vector::push_back(&mut pool_ids, pool_id);
            i = i + 1;
        };
        
        // Test pool discovery
        assert_eq(factory::get_pool_count(&factory), 3);
        
        let found_pools = factory::get_pools_for_tokens<USDC, ETH>(&factory);
        assert_eq(vector::length(&found_pools), 3);
        
        // Test best pool finding
        let best_pool_opt = factory::find_best_pool<USDC, ETH>(&factory);
        assert!(std::option::is_some(&best_pool_opt), 0);
        
        // Test individual pool existence
        let mut j = 0;
        while (j < vector::length(&bin_steps)) {
            let bin_step = *vector::borrow(&bin_steps, j);
            assert!(factory::pool_exists<USDC, ETH>(&factory, bin_step), 0);
            j = j + 1;
        };
        
        std::debug::print(&std::string::utf8(b"Found pools: "));
        std::debug::print(&vector::length(&found_pools));
        
        std::debug::print(&std::string::utf8(b"✅ Factory pool discovery test passed"));
        
        // Cleanup
        factory::transfer_factory_for_testing(factory, ADMIN);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_factory_admin_functions() {
        let mut scenario = test::begin(ADMIN);
        
        std::debug::print(&std::string::utf8(b"=== FACTORY ADMIN FUNCTIONS TEST ==="));
        
        let mut factory = factory::create_test_factory_with_storage(ADMIN, test::ctx(&mut scenario));
        
        // Test protocol fee rate update
        let initial_fee_rate = factory::get_protocol_fee_rate(&factory);
        factory::set_protocol_fee_rate(&mut factory, 500, test::ctx(&mut scenario)); // 5%
        let updated_fee_rate = factory::get_protocol_fee_rate(&factory);
        assert_eq(updated_fee_rate, 500);
        assert!(updated_fee_rate != initial_fee_rate, 0);
        
        // Test adding new bin step
        let initial_steps = factory::get_allowed_bin_steps(&factory);
        let initial_count = vector::length(&initial_steps);
        
        factory::add_allowed_bin_step(&mut factory, 75, test::ctx(&mut scenario));
        let updated_steps = factory::get_allowed_bin_steps(&factory);
        assert_eq(vector::length(&updated_steps), initial_count + 1);
        assert!(vector::contains(&updated_steps, &75), 0);
        
        // Test admin transfer
        let initial_admin = factory::get_admin(&factory);
        assert_eq(initial_admin, ADMIN);
        
        factory::transfer_admin(&mut factory, ALICE, test::ctx(&mut scenario));
        let new_admin = factory::get_admin(&factory);
        assert_eq(new_admin, ALICE);
        
        std::debug::print(&std::string::utf8(b"Initial fee rate: "));
        std::debug::print(&initial_fee_rate);
        std::debug::print(&std::string::utf8(b"Updated fee rate: "));
        std::debug::print(&updated_fee_rate);
        std::debug::print(&std::string::utf8(b"New admin: "));
        std::debug::print(&sui::address::to_u256(new_admin));
        
        std::debug::print(&std::string::utf8(b"✅ Factory admin functions test passed"));
        
        // Cleanup
        factory::transfer_factory_for_testing(factory, ALICE);
        test::end(scenario);
    }

    #[test]
    fun test_factory_multi_token_pools() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(test::ctx(&mut scenario));
        
        std::debug::print(&std::string::utf8(b"=== FACTORY MULTI-TOKEN POOLS TEST ==="));
        
        let mut factory = factory::create_test_factory_with_storage(ADMIN, test::ctx(&mut scenario));
        
        // Create USDC/ETH pool
        let usdc_coin = coin::mint_for_testing<USDC>(INITIAL_USDC, test::ctx(&mut scenario));
        let eth_coin = coin::mint_for_testing<ETH>(INITIAL_ETH, test::ctx(&mut scenario));
        
        let usdc_eth_pool_id = factory::create_and_store_pool<USDC, ETH>(
            &mut factory,
            25,
            bin_math::calculate_bin_price(1000, 25),
            1000,
            usdc_coin,
            eth_coin,
            &clock,
            test::ctx(&mut scenario)
        );
        
        // Create ETH/BTC pool
        let eth_coin_2 = coin::mint_for_testing<ETH>(INITIAL_ETH, test::ctx(&mut scenario));
        let btc_coin = coin::mint_for_testing<BTC>(INITIAL_BTC, test::ctx(&mut scenario));
        
        let eth_btc_pool_id = factory::create_and_store_pool<ETH, BTC>(
            &mut factory,
            25,
            bin_math::calculate_bin_price(1000, 25),
            1000,
            eth_coin_2,
            btc_coin,
            &clock,
            test::ctx(&mut scenario)
        );
        
        // Verify both pools exist
        assert_eq(factory::get_pool_count(&factory), 2);
        assert!(factory::pool_exists_in_factory(&factory, usdc_eth_pool_id), 0);
        assert!(factory::pool_exists_in_factory(&factory, eth_btc_pool_id), 0);
        
        // Test pool access
        let usdc_eth_pool = factory::borrow_pool<USDC, ETH>(&factory, usdc_eth_pool_id);
        let (usdc_reserves_a, usdc_reserves_b) = dlmm_pool::get_pool_reserves(usdc_eth_pool);
        assert!(usdc_reserves_a > 0, 0);
        assert!(usdc_reserves_b > 0, 0);
        
        let eth_btc_pool = factory::borrow_pool<ETH, BTC>(&factory, eth_btc_pool_id);
        let (eth_reserves_a, eth_reserves_b) = dlmm_pool::get_pool_reserves(eth_btc_pool);
        assert!(eth_reserves_a > 0, 0);
        assert!(eth_reserves_b > 0, 0);
        
        // Test pool discovery for different pairs
        let usdc_eth_pools = factory::get_pools_for_tokens<USDC, ETH>(&factory);
        let eth_btc_pools = factory::get_pools_for_tokens<ETH, BTC>(&factory);
        
        assert_eq(vector::length(&usdc_eth_pools), 1);
        assert_eq(vector::length(&eth_btc_pools), 1);
        
        std::debug::print(&std::string::utf8(b"USDC/ETH reserves A: "));
        std::debug::print(&usdc_reserves_a);
        std::debug::print(&std::string::utf8(b"ETH/BTC reserves A: "));
        std::debug::print(&eth_reserves_a);
        
        std::debug::print(&std::string::utf8(b"✅ Factory multi-token pools test passed"));
        
        // Cleanup
        factory::transfer_factory_for_testing(factory, ADMIN);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_factory_pool_data_extraction() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(test::ctx(&mut scenario));
        
        std::debug::print(&std::string::utf8(b"=== FACTORY POOL DATA EXTRACTION TEST ==="));
        
        let mut factory = factory::create_test_factory_with_storage(ADMIN, test::ctx(&mut scenario));
        
        // Create pool
        let coin_a = coin::mint_for_testing<USDC>(INITIAL_USDC, test::ctx(&mut scenario));
        let coin_b = coin::mint_for_testing<ETH>(INITIAL_ETH, test::ctx(&mut scenario));
        
        let bin_step = 50u16;
        let initial_bin_id = 1000u32;
        let initial_price = bin_math::calculate_bin_price(initial_bin_id, bin_step);
        
        let pool_id = factory::create_and_store_pool<USDC, ETH>(
            &mut factory,
            bin_step,
            initial_price,
            initial_bin_id,
            coin_a,
            coin_b,
            &clock,
            test::ctx(&mut scenario)
        );
        
        // Test pool data extraction
        let pool_data_opt = factory::get_pool_data<USDC, ETH>(&factory, pool_id);
        assert!(std::option::is_some(&pool_data_opt), 0);
        
        let mut pool_data_opt_mut = pool_data_opt;
        let pool_data = std::option::extract(&mut pool_data_opt_mut);
        let (extracted_bin_step, reserves_a, reserves_b, current_price, is_active) = 
            factory::extract_pool_data(&pool_data);
        
        // Verify extracted data matches creation parameters
        assert_eq(extracted_bin_step, bin_step);
        assert!(reserves_a > 0, 0);
        assert!(reserves_b > 0, 0);
        assert!(current_price > 0, 0);
        assert!(is_active, 0);
        
        // FIXED: Destructure tuple immediately in function call
        let (direct_reserves_a, direct_reserves_b) = factory::get_pool_reserves<USDC, ETH>(&factory, pool_id);
        assert_eq(direct_reserves_a, reserves_a);
        assert_eq(direct_reserves_b, reserves_b);
        
        // Test swap capability check
        let can_handle_small = factory::can_pool_handle_swap<USDC, ETH>(&factory, pool_id, 1000, true);
        let can_handle_huge = factory::can_pool_handle_swap<USDC, ETH>(&factory, pool_id, reserves_a * 2, true);
        
        assert!(can_handle_small, 0); // Should handle small swaps
        assert!(!can_handle_huge, 0); // Should reject excessive swaps
        
        std::debug::print(&std::string::utf8(b"Extracted bin step: "));
        std::debug::print(&extracted_bin_step);
        std::debug::print(&std::string::utf8(b"Reserves A: "));
        std::debug::print(&reserves_a);
        std::debug::print(&std::string::utf8(b"Can handle small: "));
        std::debug::print(&can_handle_small);
        std::debug::print(&std::string::utf8(b"Can handle huge: "));
        std::debug::print(&can_handle_huge);
        
        std::debug::print(&std::string::utf8(b"✅ Factory pool data extraction test passed"));
        
        // Cleanup
        factory::transfer_factory_for_testing(factory, ADMIN);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_factory_error_conditions() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(test::ctx(&mut scenario));
        
        std::debug::print(&std::string::utf8(b"=== FACTORY ERROR CONDITIONS TEST ==="));
        
        let factory = factory::create_test_factory_with_storage(ADMIN, test::ctx(&mut scenario));
        
        // Test non-existent pool queries
        let fake_pool_id = sui::object::id_from_address(@0x999);
        let fake_exists = factory::pool_exists_in_factory(&factory, fake_pool_id);
        assert!(!fake_exists, 0);
        
        let fake_pool_data = factory::get_pool_data<USDC, ETH>(&factory, fake_pool_id);
        assert!(std::option::is_none(&fake_pool_data), 0);
        
        // FIXED: Destructure tuple immediately in function call
        let (fake_reserves_a, fake_reserves_b) = factory::get_pool_reserves<USDC, ETH>(&factory, fake_pool_id);
        assert_eq(fake_reserves_a, 0);
        assert_eq(fake_reserves_b, 0);
        
        let fake_can_handle = factory::can_pool_handle_swap<USDC, ETH>(&factory, fake_pool_id, 1000, true);
        assert!(!fake_can_handle, 0);
        
        // Test non-existent token pair
        let no_pool_id = factory::get_pool_id<USDC, BTC>(&factory, 25);
        assert!(std::option::is_none(&no_pool_id), 0);
        
        let no_pools = factory::get_pools_for_tokens<USDC, BTC>(&factory);
        assert_eq(vector::length(&no_pools), 0);
        
        let no_best_pool = factory::find_best_pool<USDC, BTC>(&factory);
        assert!(std::option::is_none(&no_best_pool), 0);
        
        std::debug::print(&std::string::utf8(b"✅ Factory error conditions test passed"));
        
        // Cleanup
        factory::transfer_factory_for_testing(factory, ADMIN);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}