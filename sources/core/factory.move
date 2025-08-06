module sui_dlmm::factory {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::table::Table;

    /// Factory for creating and managing pools
    struct DLMMFactory has key {
        id: UID,
        pools: Table<vector<u8>, ID>,
        allowed_bin_steps: vector<u16>,
        protocol_fee_rate: u16,
    }

    /// Initialize factory
    fun init(ctx: &mut TxContext) {
        let factory = DLMMFactory {
            id: object::new(ctx),
            pools: table::new(ctx),
            allowed_bin_steps: vector[10, 25, 50, 100, 200, 500],
            protocol_fee_rate: 300, // 3%
        };
        transfer::share_object(factory);
    }
}