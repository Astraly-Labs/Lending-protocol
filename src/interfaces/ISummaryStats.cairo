#[starknet::interface]
trait SummaryStatsABI<TContractState> {
    fn calculate_mean(
        self: @TContractState, key: felt252, start: felt252, stop: felt252
    ) -> felt252;

    fn calculate_volatility(
        self: @TContractState, key: felt252, start: felt252, stop: felt252, num_samples: felt252
    ) -> felt252;
}
