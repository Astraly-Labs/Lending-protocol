use Lendingprotocol::interfaces::Pragma::{
    BaseEntry, SpotEntry, Currency, Pair, DataType, PragmaPricesResponse, Checkpoint,
    PossibleEntryStorage, FutureEntry, GenericEntry, SimpleDataType, SpotEntryStorage,
    FutureEntryStorage, AggregationMode, GenericEntryStorage, PossibleEntries, ArrayEntry,
    PragmaOracle
};

use serde::Serde;

use starknet::{
    storage_read_syscall, storage_write_syscall, storage_address_from_base_and_offset,
    storage_access::storage_base_address_from_felt252, Store, StorageBaseAddress, SyscallResult,
    ContractAddress, get_caller_address
};
use starknet::class_hash::ClassHash;
use traits::{Into, TryInto};
use result::{ResultTrait, ResultTraitImpl};
use box::BoxTrait;
use array::{SpanTrait, ArrayTrait};
use zeroable::Zeroable;


#[starknet::contract]
mod Oracle {
    use super::{
        BaseEntry, SpotEntry, Currency, Pair, DataType, PragmaPricesResponse, Checkpoint,
        PossibleEntryStorage, FutureEntry, GenericEntry, SimpleDataType, SpotEntryStorage,
        FutureEntryStorage, AggregationMode, PossibleEntries, ArrayEntry, Serde,
        storage_read_syscall, storage_write_syscall, storage_address_from_base_and_offset,
        storage_base_address_from_felt252, Store, StorageBaseAddress, SyscallResult,
        ContractAddress, get_caller_address, ClassHash, Into, TryInto, ResultTrait, ResultTraitImpl,
        BoxTrait, ArrayTrait, SpanTrait, Zeroable, PragmaOracle, GenericEntryStorage
    };
    use hash::LegacyHash;

    use starknet::{get_block_timestamp, Felt252TryIntoContractAddress};

    use option::OptionTrait;
    use debug::PrintTrait;
    const BACKWARD_TIMESTAMP_BUFFER: u64 = 100;
    const ASSET_1: felt252 = 'ASSET1/USD';
    const ASSET_2: felt252 = 'ASSET2/USD';
    #[storage]
    struct Storage {
        //oracle controller address storage, contractAddress
        oracle_controller_address_storage: ContractAddress,
        // oracle publisher registry address, ContractAddres
        oracle_publisher_registry_address_storage: ContractAddress,
        //oracle pair storage, legacy map between the pair_id and the pair in question (no need to specify the data type here).
        oracle_pairs_storage: LegacyMap::<felt252, Pair>,
        //oracle_pair_id_storage, legacy Map between (quote_currency_id, base_currency_id) and the pair_id
        oracle_pair_id_storage: LegacyMap::<(felt252, felt252), felt252>,
        //oracle_currencies_storage, legacy Map between (currency_id) and the currency
        oracle_currencies_storage: LegacyMap::<felt252, Currency>,
        //oralce_sources_storage, legacyMap between (pair_id ,(SPOT/FUTURES/OPTIONS/GENERIC), index, expiration_timestamp ) and the source
        oracle_sources_storage: LegacyMap::<(felt252, felt252, u64, u64), felt252>,
        //oracle_sources_len_storage, legacyMap between (pair_id ,(SPOT/FUTURES/OPTIONS/GENERIC), expiration_timestamp) and the len of the sources array
        oracle_sources_len_storage: LegacyMap::<(felt252, felt252, u64), u64>,
        //oracle_data_entry_storage, legacyMap between (pair_id, (SPOT/FUTURES/OPTIONS/GENERIC), source, expiration_timestamp (0 for SPOT))
        oracle_data_entry_storage: LegacyMap::<(felt252, felt252, felt252, u64), u256>,
        //oracle_data_entry_storage len , legacyMap between pair_id, (SPOT/FUTURES/OPTIONS/GENERIC), expiration_timestamp and the length
        oracle_data_len_all_sources: LegacyMap::<(felt252, felt252, u64), u64>,
        //oracle_checkpoints, legacyMap between, (pair_id, (SPOT/FUTURES/OPTIONS), index, expiration_timestamp (0 for SPOT), aggregation_mode) associated to a checkpoint
        oracle_checkpoints: LegacyMap::<(felt252, felt252, u64, u64, u8), Checkpoint>,
        //oracle_checkpoint_index, legacyMap between (pair_id, (SPOT/FUTURES/OPTIONS), expiration_timestamp (0 for SPOT)) and the index of the last checkpoint
        oracle_checkpoint_index: LegacyMap::<(felt252, felt252, u64, u8), u64>,
        oracle_sources_threshold_storage: u32,
    }

    /// DataType should implement this trait
    /// If it has a `base_entry` field defined by `BaseEntry` struct
    trait hasBaseEntry<T> {
        fn get_base_entry(self: @T) -> BaseEntry;
        fn get_base_timestamp(self: @T) -> u64;
    }


    /// DataType should implement this trait
    /// If it has a `price` field defined in `self`
    trait HasPrice<T> {
        fn get_price(self: @T) -> u128;
    }

    impl SHasPriceImpl of HasPrice<SpotEntry> {
        fn get_price(self: @SpotEntry) -> u128 {
            (*self).price
        }
    }
    impl FHasPriceImpl of HasPrice<FutureEntry> {
        fn get_price(self: @FutureEntry) -> u128 {
            (*self).price
        }
    }

    impl SpotPartialOrd of PartialOrd<SpotEntry> {
        #[inline(always)]
        fn le(lhs: SpotEntry, rhs: SpotEntry) -> bool {
            lhs.price <= rhs.price
        }
        fn ge(lhs: SpotEntry, rhs: SpotEntry) -> bool {
            lhs.price >= rhs.price
        }
        fn lt(lhs: SpotEntry, rhs: SpotEntry) -> bool {
            lhs.price < rhs.price
        }
        fn gt(lhs: SpotEntry, rhs: SpotEntry) -> bool {
            lhs.price > rhs.price
        }
    }

    impl FuturePartialOrd of PartialOrd<FutureEntry> {
        #[inline(always)]
        fn le(lhs: FutureEntry, rhs: FutureEntry) -> bool {
            lhs.price <= rhs.price
        }
        fn ge(lhs: FutureEntry, rhs: FutureEntry) -> bool {
            lhs.price >= rhs.price
        }
        fn lt(lhs: FutureEntry, rhs: FutureEntry) -> bool {
            lhs.price < rhs.price
        }
        fn gt(lhs: FutureEntry, rhs: FutureEntry) -> bool {
            lhs.price > rhs.price
        }
    }

    impl AggregationModeIntoU8 of Into<AggregationMode, u8> {
        fn into(self: AggregationMode) -> u8 {
            match self {
                AggregationMode::Median(()) => 0_u8,
                AggregationMode::Mean(()) => 1_u8,
                AggregationMode::Error(()) => 150_u8,
            }
        }
    }
    impl TupleSize4LegacyHash<
        E0,
        E1,
        E2,
        E3,
        E4,
        impl E0LegacyHash: LegacyHash<E0>,
        impl E1LegacyHash: LegacyHash<E1>,
        impl E2LegacyHash: LegacyHash<E2>,
        impl E3LegacyHash: LegacyHash<E3>,
        impl E4LegacyHash: LegacyHash<E4>,
        impl E0Drop: Drop<E0>,
        impl E1Drop: Drop<E1>,
        impl E2Drop: Drop<E2>,
        impl E3Drop: Drop<E3>,
        impl E4Drop: Drop<E4>,
    > of LegacyHash<(E0, E1, E2, E3, E4)> {
        fn hash(state: felt252, value: (E0, E1, E2, E3, E4)) -> felt252 {
            let (e0, e1, e2, e3, e4) = value;
            let state = E0LegacyHash::hash(state, e0);
            let state = E1LegacyHash::hash(state, e1);
            let state = E2LegacyHash::hash(state, e2);
            let state = E3LegacyHash::hash(state, e3);
            E4LegacyHash::hash(state, e4)
        }
    }

    fn u8_into_AggregationMode(value: u8) -> AggregationMode {
        if value == 0_u8 {
            AggregationMode::Median(())
        } else if value == 1_u8 {
            AggregationMode::Mean(())
        } else {
            AggregationMode::Error(())
        }
    }
    impl CheckpointStoreImpl of Store<Checkpoint> {
        fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult<Checkpoint> {
            let timestamp_base = storage_base_address_from_felt252(
                storage_address_from_base_and_offset(base, 0_u8).into()
            );
            let timestamp: u64 = Store::<u128>::read(address_domain, timestamp_base)?
                .try_into()
                .unwrap();

            let value_base = storage_base_address_from_felt252(
                storage_address_from_base_and_offset(base, 1_u8).into()
            );
            let value: u128 = Store::<u128>::read(address_domain, value_base)?;
            let u8_aggregation_mode: u8 = Store::<felt252>::read(
                address_domain,
                storage_base_address_from_felt252(
                    storage_address_from_base_and_offset(base, 3_u8).into()
                )
            )?
                .try_into()
                .unwrap();

            let aggregation_mode: AggregationMode = u8_into_AggregationMode(u8_aggregation_mode);
            Result::Ok(
                Checkpoint {
                    timestamp: timestamp,
                    value: value,
                    aggregation_mode: aggregation_mode,
                    num_sources_aggregated: storage_read_syscall(
                        address_domain, storage_address_from_base_and_offset(base, 4_u8)
                    )?
                        .try_into()
                        .unwrap(),
                }
            )
        }
        #[inline(always)]
        fn write(
            address_domain: u32, base: StorageBaseAddress, value: Checkpoint
        ) -> SyscallResult<()> {
            let timestamp_base = storage_base_address_from_felt252(
                storage_address_from_base_and_offset(base, 0_u8).into()
            );
            Store::write(address_domain, timestamp_base, value.timestamp)?;
            let value_base = storage_base_address_from_felt252(
                storage_address_from_base_and_offset(base, 1_u8).into()
            );
            Store::write(address_domain, value_base, value.value)?;
            let aggregation_mode_u8: u8 = value.aggregation_mode.into();
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 3_u8),
                aggregation_mode_u8.into(),
            )?;
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 4_u8),
                value.num_sources_aggregated.into(),
            )
        }
        fn read_at_offset(
            address_domain: u32, base: starknet::StorageBaseAddress, offset: u8
        ) -> starknet::SyscallResult<Checkpoint> {
            CheckpointStoreImpl::read_at_offset(address_domain, base, offset)
        }
        fn write_at_offset(
            address_domain: u32, base: starknet::StorageBaseAddress, offset: u8, value: Checkpoint
        ) -> starknet::SyscallResult<()> {
            CheckpointStoreImpl::write_at_offset(address_domain, base, offset, value)
        }
        fn size() -> u8 {
            4_u8
        }
    }


    #[derive(Drop, starknet::Event)]
    struct UpdatedPublisherRegistryAddress {
        old_publisher_registry_address: ContractAddress,
        new_publisher_registry_address: ContractAddress
    }


    #[derive(Drop, starknet::Event)]
    struct SubmittedSpotEntry {
        spot_entry: SpotEntry
    }


    #[derive(Drop, starknet::Event)]
    struct SubmittedFutureEntry {
        future_entry: FutureEntry
    }


    #[derive(Drop, starknet::Event)]
    struct SubmittedGenericEntry {
        generic_entry: GenericEntry
    }


    #[derive(Drop, starknet::Event)]
    struct SubmittedCurrency {
        currency: Currency
    }


    #[derive(Drop, starknet::Event)]
    struct UpdatedCurrency {
        currency: Currency
    }

    #[derive(Drop, starknet::Event)]
    struct SubmittedPair {
        pair: Pair
    }


    #[derive(Drop, starknet::Event)]
    struct CheckpointSpotEntry {
        pair_id: felt252, 
    }

    #[derive(Drop, starknet::Event)]
    struct CheckpointFutureEntry {
        pair_id: felt252,
        expiration_timestamp: u64,
    }
    #[derive(Drop, starknet::Event)]
    #[event]
    enum Event {
        UpdatedPublisherRegistryAddress: UpdatedPublisherRegistryAddress,
        SubmittedSpotEntry: SubmittedSpotEntry,
        SubmittedFutureEntry: SubmittedFutureEntry,
        SubmittedGenericEntry: SubmittedGenericEntry,
        SubmittedCurrency: SubmittedCurrency,
        UpdatedCurrency: UpdatedCurrency,
        SubmittedPair: SubmittedPair,
        CheckpointSpotEntry: CheckpointSpotEntry,
        CheckpointFutureEntry: CheckpointFutureEntry
    }


    #[external(v0)]
    impl IOracleImpl of PragmaOracle<ContractState> {
        //
        // Getters
        //

        fn get_data_entries_for_sources(
            self: @ContractState, data_type: DataType, sources: Span<felt252>
        ) -> (Span<PossibleEntries>, u64) {
            assert(1 == 1, 'not allowed');
            let array = ArrayTrait::<PossibleEntries>::new();
            return (array.span(), 0);
        }


        fn get_data_entries(self: @ContractState, data_type: DataType) -> Span<PossibleEntries> {
            assert(1 == 1, 'not allowed');
            let array = ArrayTrait::<PossibleEntries>::new();
            return array.span();
        }


        fn get_data_median(self: @ContractState, data_type: DataType) -> PragmaPricesResponse {
            let sources = ArrayTrait::<felt252>::new();
            let prices_response: PragmaPricesResponse = PragmaOracle::get_data_for_sources(
                self, data_type, AggregationMode::Median(()), sources.span()
            );
            prices_response
        }


        fn get_data_median_for_sources(
            self: @ContractState, data_type: DataType, sources: Span<felt252>
        ) -> PragmaPricesResponse {
            let sources = ArrayTrait::<felt252>::new();
            let prices_response: PragmaPricesResponse = PragmaOracle::get_data_for_sources(
                self, data_type, AggregationMode::Median(()), sources.span()
            );
            prices_response
        }


        fn get_data_median_multi(
            self: @ContractState, data_types: Span<DataType>, sources: Span<felt252>
        ) -> Span<PragmaPricesResponse> {
            assert(1 == 1, 'not allowed');
            let array = ArrayTrait::<PragmaPricesResponse>::new();
            return array.span();
        }


        fn get_data(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode
        ) -> PragmaPricesResponse {
            let sources = ArrayTrait::<felt252>::new();
            let prices_response: PragmaPricesResponse = PragmaOracle::get_data_for_sources(
                self, data_type, aggregation_mode, sources.span()
            );

            prices_response
        }

        fn calculate_volatility(
            self: @ContractState,
            data_type: DataType,
            start_tick: u64,
            end_tick: u64,
            num_samples: u64,
            aggregation_mode: AggregationMode
        ) -> (u128, u32) {
            return (540000000, 8);
        }


        fn get_data_for_sources(
            self: @ContractState,
            data_type: DataType,
            aggregation_mode: AggregationMode,
            sources: Span<felt252>
        ) -> PragmaPricesResponse {
            let timestamp = starknet::get_block_timestamp();
            match data_type {
                DataType::SpotEntry(pair_id) => {
                    if (pair_id == ASSET_1) {
                        return PragmaPricesResponse {
                            price: 186400000000,
                            decimals: 8,
                            last_updated_timestamp: timestamp,
                            num_sources_aggregated: 3,
                            expiration_timestamp: Option::Some(0),
                        };
                    } else if (pair_id == ASSET_2) {
                        return PragmaPricesResponse {
                            price: 46700000000,
                            decimals: 8,
                            last_updated_timestamp: timestamp,
                            num_sources_aggregated: 3,
                            expiration_timestamp: Option::Some(0),
                        };
                    } else {
                        return PragmaPricesResponse {
                            price: 0,
                            decimals: 0,
                            last_updated_timestamp: 0,
                            num_sources_aggregated: 0,
                            expiration_timestamp: Option::Some(0),
                        };
                    }
                },
                DataType::FutureEntry((
                    pair_id, expiration_timestamp
                )) => {
                    return PragmaPricesResponse {
                        price: 0,
                        decimals: 0,
                        last_updated_timestamp: 0,
                        num_sources_aggregated: 0,
                        expiration_timestamp: Option::Some(0),
                    };
                },
                DataType::GenericEntry(pair_id) => {
                    return PragmaPricesResponse {
                        price: 0,
                        decimals: 0,
                        last_updated_timestamp: 0,
                        num_sources_aggregated: 0,
                        expiration_timestamp: Option::Some(0),
                    };
                }
            }
        }


        fn get_publisher_registry_address(self: @ContractState) -> ContractAddress {
            self.oracle_publisher_registry_address_storage.read()
        }


        //Can be simplified using just the pair_id instead of the data_type
        fn get_decimals(self: @ContractState, data_type: DataType) -> u32 {
            assert(1 == 1, 'not allowed');
            return 0;
        }


        fn get_data_with_USD_hop(
            self: @ContractState,
            base_currency_id: felt252,
            quote_currency_id: felt252,
            aggregation_mode: AggregationMode,
            typeof: SimpleDataType,
            expiration_timestamp: Option<u64>
        ) -> PragmaPricesResponse {
            assert(1 == 1, 'not allowed');
            return (PragmaPricesResponse {
                price: 0,
                decimals: 0,
                last_updated_timestamp: 0,
                num_sources_aggregated: 0,
                expiration_timestamp: Option::Some(0),
            });
        }


        fn get_latest_checkpoint_index(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode
        ) -> (u64, bool) {
            assert(1 == 1, 'not allowed');
            return (0, false);
        }


        fn get_latest_checkpoint(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode
        ) -> Checkpoint {
            assert(1 == 1, 'not allowed');
            return (Checkpoint {
                timestamp: 0,
                value: 0,
                aggregation_mode: AggregationMode::Median(()),
                num_sources_aggregated: 0
            });
        }


        fn get_checkpoint(
            self: @ContractState,
            data_type: DataType,
            checkpoint_index: u64,
            aggregation_mode: AggregationMode
        ) -> Checkpoint {
            assert(1 == 1, 'not allowed');
            return (Checkpoint {
                timestamp: 0,
                value: 0,
                aggregation_mode: AggregationMode::Median(()),
                num_sources_aggregated: 0
            });
        }


        fn get_sources_threshold(self: @ContractState) -> u32 {
            assert(1 == 1, 'not allowed');
            return 0;
        }


        fn get_last_checkpoint_before(
            self: @ContractState,
            data_type: DataType,
            timestamp: u64,
            aggregation_mode: AggregationMode,
        ) -> (Checkpoint, u64) {
            assert(1 == 1, 'not allowed');
            return (
                Checkpoint {
                    timestamp: 0,
                    value: 0,
                    aggregation_mode: AggregationMode::Median(()),
                    num_sources_aggregated: 0
                }, 0
            );
        }


        fn get_data_entry(
            self: @ContractState, data_type: DataType, source: felt252
        ) -> PossibleEntries {
            assert(1 == 1, 'not allowed');
            return (PossibleEntries::Spot(
                SpotEntry {
                    base: BaseEntry {
                        timestamp: 0, source: 0, publisher: 0
                    }, price: 0, pair_id: 0, volume: 0
                }
            ));
        }

        //
        // Setters
        //

        fn publish_data(ref self: ContractState, new_entry: PossibleEntries) {
            assert(1 == 1, 'not allowed');
        }


        fn publish_data_entries(ref self: ContractState, new_entries: Span<PossibleEntries>) {
            assert(1 == 1, 'not allowed');
        }


        fn update_publisher_registry_address(
            ref self: ContractState, new_publisher_registry_address: ContractAddress
        ) {
            assert(1 == 1, 'not allowed');
        }


        fn add_currency(ref self: ContractState, new_currency: Currency) {
            assert(1 == 1, 'not allowed');
        }


        fn update_currency(ref self: ContractState, currency: Currency) {
            assert(1 == 1, 'not allowed');
        }


        fn add_pair(ref self: ContractState, new_pair: Pair) {
            assert(1 == 1, 'not allowed');
        }


        fn set_checkpoint(
            ref self: ContractState, data_type: DataType, aggregation_mode: AggregationMode
        ) {
            assert(1 == 1, 'not allowed');
        }


        fn set_checkpoints(
            ref self: ContractState, data_types: Span<DataType>, aggregation_mode: AggregationMode
        ) {
            assert(1 == 1, 'not allowed');
        }


        fn set_admin_address(ref self: ContractState, new_admin_address: ContractAddress) {
            assert(1 == 1, 'not allowed');
        }


        fn set_sources_threshold(ref self: ContractState, threshold: u32) {
            self.oracle_sources_threshold_storage.write(threshold);
        }
    }
}

