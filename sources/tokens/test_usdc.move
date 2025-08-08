// sources/tokens/test_usdc.move
module sui_dlmm::test_usdc {
    use sui::coin::{Self, TreasuryCap};
    use sui::url;

    /// The USDC token type
    public struct TEST_USDC has drop {}

    /// Shared treasury for public minting
    public struct SharedTreasury has key {
        id: sui::object::UID,
        treasury_cap: TreasuryCap<TEST_USDC>,
        max_mint_per_tx: u64,
    }

    /// Initialize the USDC token with shared treasury
    fun init(witness: TEST_USDC, ctx: &mut sui::tx_context::TxContext) {
        let (treasury_cap, metadata) = coin::create_currency<TEST_USDC>(
            witness,
            9, // decimals
            b"USDC",
            b"USD Coin (Test)",
            b"Test USDC token for Sui DLMM protocol - Anyone can mint!",
            std::option::some(url::new_unsafe_from_bytes(b"https://cryptologos.cc/logos/usd-coin-usdc-logo.png")),
            ctx
        );

        // Create shared treasury that anyone can use
        let shared_treasury = SharedTreasury {
            id: sui::object::new(ctx),
            treasury_cap,
            max_mint_per_tx: 100000000000000, // 100K USDC max per tx
        };

        // Share both treasury and metadata
        sui::transfer::share_object(shared_treasury);
        sui::transfer::public_share_object(metadata);
    }

    /// Public mint function - anyone can call this!
    public fun public_mint(
        treasury: &mut SharedTreasury,
        amount: u64,
        recipient: address,
        ctx: &mut sui::tx_context::TxContext
    ) {
        assert!(amount <= treasury.max_mint_per_tx, 0); // Respect per-tx limit
        assert!(amount > 0, 1); // Must mint something
        
        coin::mint_and_transfer(&mut treasury.treasury_cap, amount, recipient, ctx);
    }

    /// Mint tokens to sender (convenience function)
    public fun mint_to_sender(
        treasury: &mut SharedTreasury,
        amount: u64,
        ctx: &mut sui::tx_context::TxContext
    ) {
        public_mint(treasury, amount, sui::tx_context::sender(ctx), ctx);
    }

    /// Get 1000 USDC for testing (entry function)
    public entry fun get_test_tokens(
        treasury: &mut SharedTreasury,
        ctx: &mut sui::tx_context::TxContext
    ) {
        mint_to_sender(treasury, 1000000000000, ctx); // 1000 USDC
    }

    /// Get 10000 USDC for liquidity provision (entry function)
    public entry fun get_liquidity_tokens(
        treasury: &mut SharedTreasury,
        ctx: &mut sui::tx_context::TxContext
    ) {
        mint_to_sender(treasury, 10000000000000, ctx); // 10000 USDC
    }

    /// Get custom amount (entry function)
    public entry fun mint_custom_amount(
        treasury: &mut SharedTreasury,
        amount: u64,
        ctx: &mut sui::tx_context::TxContext
    ) {
        mint_to_sender(treasury, amount, ctx);
    }

    /// Burn USDC tokens (for cleanup)
    public fun burn(treasury: &mut SharedTreasury, coin: sui::coin::Coin<TEST_USDC>) {
        coin::burn(&mut treasury.treasury_cap, coin);
    }

    /// View treasury max mint limit
    public fun get_max_mint_per_tx(treasury: &SharedTreasury): u64 {
        treasury.max_mint_per_tx
    }
}