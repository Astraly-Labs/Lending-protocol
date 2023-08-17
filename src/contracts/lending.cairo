use starknet::ContractAddress;


#[starknet::interface]
trait ILendingProtocolABI<TContractState> {
    fn deposit(ref self: TContractState, amount: u128);
    fn withdraw(ref self: TContractState, amount: u128);
    fn borrow(ref self: TContractState, amount: u128);
    fn repay(ref self: TContractState, amount: u128);
    fn liquidate(ref self: TContractState, user: ContractAddress);
}


#[starknet::contract]
mod LendingProtocol {
    use array::ArrayTrait;
    use super::{ContractAddress, ILendingProtocolABI};
    use Lendingprotocol::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use Lendingprotocol::interfaces::Pragma::{PragmaOracleDispatcher, PragmaOracleDispatcherTrait};
    use starknet::info;
    use traits::Into;
    use Lendingprotocol::interfaces::ISummaryStats::{
        SummaryStatsABIDispatcher, SummaryStatsABIDispatcherTrait
    };
    use debug::PrintTrait;
    use result::ResultTrait;
    use traits::TryInto;
    use option::OptionTrait;
    use starknet::contract_address_const;
    use alexandria_math::math::fpow;
    const BORROW_THRESHOLD: u128 = 150;
    const LIQUIDATION_THRESHOLD: u128 = 120;
    const ASSET_ID: felt252 = 'BTC/USD'; //TO BE CHANGED
    const ONE_HOUR: u64 = 3600;
    #[derive(Serde, Copy, Drop, starknet::Store)]
    struct LiquidityPool {
        total_liquidity: u128,
        total_borrowed: u128,
    }

    #[derive(Serde, Copy, Drop, starknet::Store)]
    struct UserBalance {
        deposited: u128,
        borrowed: u128
    }


    #[storage]
    struct Storage {
        borrow_token_storage: ContractAddress,
        collateral_token_storage: ContractAddress,
        liquidity_pool_storage: LiquidityPool,
        user_balances_storage: LegacyMap<ContractAddress, UserBalance>
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, borrow_token: ContractAddress, collateral_token: ContractAddress
    ) {
        self.borrow_token_storage.write(borrow_token);
        self.collateral_token_storage.write(collateral_token);
    }

    #[derive(Drop, starknet::Event)]
    struct DepositEvent {
        user: ContractAddress,
        amount: u128
    }
    #[derive(Drop, starknet::Event)]
    struct BorrowEvent {
        user: ContractAddress,
        amount: u128
    }

    #[derive(Drop, starknet::Event)]
    struct RepayEvent {
        user: ContractAddress,
        amount: u128
    }

    #[derive(Drop, starknet::Event)]
    struct LiquidateEvent {
        user: ContractAddress,
        amount: u128
    }
    #[derive(Drop, starknet::Event)]
    struct WithdrawEvent {
        user: ContractAddress,
        amount: u128
    }

    #[derive(Drop, starknet::Event)]
    #[event]
    enum Event {
        DepositEvent: DepositEvent,
        BorrowEvent: BorrowEvent,
        RepayEvent: RepayEvent,
        LiquidateEvent: LiquidateEvent, 
        WithdrawEvent: WithdrawEvent
    }

    #[external(v0)]
    impl ILendingProtocolABIImpl of ILendingProtocolABI<ContractState> {
        fn deposit(ref self: ContractState, amount: u128) {
            let deposit_token = self.collateral_token_storage.read();
            let deposit_token_dispatcher = IERC20Dispatcher { contract_address: deposit_token };

            let caller = info::get_caller_address();
            let recipient = info::get_contract_address();

            assert(
                deposit_token_dispatcher.transfer_from(caller, recipient, amount.into()),
                'Transfer failed'
            );
            let liquidity = self.liquidity_pool_storage.read();
            self
                .liquidity_pool_storage
                .write(
                    LiquidityPool {
                        total_liquidity: liquidity.total_liquidity + amount,
                        total_borrowed: liquidity.total_borrowed,
                    }
                );
            let user_info = self.user_balances_storage.read(caller);

            self
                .user_balances_storage
                .write(
                    caller,
                    UserBalance {
                        deposited: user_info.deposited + amount, borrowed: user_info.borrowed
                    }
                );
            self.emit(Event::DepositEvent(DepositEvent { user: caller, amount: amount }));
            return();
        }

        fn withdraw(ref self : ContractState, amount : u128) { 
            let caller = info::get_caller_address();
            let user_balance = self.user_balances_storage.read(caller);
            assert(amount <= user_balance.deposited, 'Not enough deposited');
            let (interest, interest_decimals) = compute_interest_rate(@self, ASSET_ID);
            let new_debt = user_balance.borrowed *fpow(10,interest_decimals.try_into().unwrap()) + interest.try_into().unwrap(); //10^interest_decimals
            let (collateral_price, price_decimals) = get_asset_price(@self, ASSET_ID);
            
            let collateral_value = user_balance.deposited * collateral_price.try_into().unwrap(); //*10^price_decimals
            let mut collateral_ratio= 0;
            let converted_price_decimals: u128 = price_decimals.try_into().unwrap();
            let converted_interest_decimals : u128 = interest_decimals.try_into().unwrap();
            let collateral_ratio = if (converted_price_decimals> converted_interest_decimals){ 
                 let numerator = (collateral_value * 100*fpow(10,converted_price_decimals-converted_interest_decimals));
                 numerator/ (new_debt)
            }else { 
                let denominator = (new_debt*fpow(10,converted_interest_decimals-converted_price_decimals));
                (collateral_value * 100) / denominator
            };
            
            // assert(collateral_ratio > BORROW_THRESHOLD, 'user below safety ratio');
            // let mut withdrawable = 0;
            // if user_balance.borrowed ==0 { 
            //     withdrawable = user_balance.deposited;
            // }else { 
            //     withdrawable = (user_balance.deposited/collateral_ratio)*(collateral_ratio-BORROW_THRESHOLD);
            // }
            // assert(withdrawable>=amount, 'amount unsafe to withdraw');
            // self.user_balances_storage.write(caller, UserBalance { deposited: user_balance.deposited-amount, borrowed: user_balance.borrowed });
            // let deposit_token = self.collateral_token_storage.read();
            // let deposit_token_dispatcher = IERC20Dispatcher { contract_address: deposit_token };
            // assert(
            //     deposit_token_dispatcher.transfer(caller, amount.into()),
            //     'Transfer failed'
            // );
            self.emit(Event::WithdrawEvent(WithdrawEvent { user: caller, amount: amount }));
            return();
        }
        fn borrow(ref self: ContractState, amount: u128) {
            let liquidity = self.liquidity_pool_storage.read();
            assert(
                liquidity.total_liquidity - liquidity.total_borrowed >= amount,
                'Not enough liquidity'
            );
            let caller = info::get_caller_address();
            let user_balance = self.user_balances_storage.read(caller);
            assert(amount <= user_balance.deposited, 'Not enough deposited');
            let new_debt = amount + user_balance.borrowed;
            let (collateral_price, price_decimals) = get_asset_price(@self, ASSET_ID);
            let converted_price_decimals = price_decimals.try_into().unwrap();
            let converted_collateral_price = collateral_price.try_into().unwrap();
            let collateral_value = user_balance.deposited * converted_collateral_price; //*10^price_decimals
            let total_debt = new_debt*fpow(10,converted_price_decimals);
            let collateral_ratio = (collateral_value * 100) / (total_debt);
            assert(collateral_ratio >= BORROW_THRESHOLD, 'not enough collateral');
            let borrow_token = self.borrow_token_storage.read();
            let borrow_token_dispatcher = IERC20Dispatcher { contract_address: borrow_token };
            let recipient = info::get_contract_address();
            assert(
                borrow_token_dispatcher.transfer_from(recipient, caller, amount.into()),
                'Transfer failed'
            );
            self
                .liquidity_pool_storage
                .write(
                    LiquidityPool {
                        total_liquidity: liquidity.total_liquidity,
                        total_borrowed: liquidity.total_borrowed + amount,
                    }
                );
            self
                .user_balances_storage
                .write(
                    caller,
                    UserBalance {
                        deposited: user_balance.deposited, borrowed: user_balance.borrowed + amount
                    }
                );
            self.emit(Event::BorrowEvent(BorrowEvent { user: caller, amount: amount }));
            return();
        }
        fn repay(ref self: ContractState, amount: u128) {
            assert(amount > 0, 'Cannot repay 0');
            let caller = info::get_caller_address();
            let (interest, decimals) = compute_interest_rate(@self, ASSET_ID);
            let converted_interest = interest.try_into().unwrap();
            let converted_decimals = decimals.try_into().unwrap();
            let user_balance = self.user_balances_storage.read(caller);
            let borrow_token = self.borrow_token_storage.read();
            let borrow_token_dispatcher = IERC20Dispatcher { contract_address: borrow_token };
            let recipient = info::get_contract_address();
            let liquidity = self.liquidity_pool_storage.read();
            let to_pay = (user_balance.borrowed + converted_interest)
                / fpow(10, converted_decimals);
            if (amount >= to_pay) {
                assert(
                    borrow_token_dispatcher.transfer_from(caller, recipient, to_pay.into()),
                    'repay transfer failed'
                );
                //NEED TO HANDLE THE INTEREST DUE REDISTRIBUTION
                self
                    .user_balances_storage
                    .write(caller, UserBalance { deposited: user_balance.deposited, borrowed: 0 });
                self
                    .liquidity_pool_storage
                    .write(
                        LiquidityPool {
                            total_liquidity: liquidity.total_liquidity,
                            total_borrowed: liquidity.total_borrowed - to_pay,
                        }
                    );
            } else if (amount >= converted_interest / fpow(10, converted_decimals)) {
                assert(
                    borrow_token_dispatcher.transfer_from(caller, recipient, amount.into()),
                    'repay transfer failed'
                );
                //NEED TO HANDLE THE INTEREST DUE REDISTRIBUTION
                self
                    .user_balances_storage
                    .write(
                        caller,
                        UserBalance {
                            deposited: user_balance.deposited,
                            borrowed: user_balance.borrowed
                                - amount
                                - converted_interest / fpow(10, converted_decimals)
                        }
                    );
                self
                    .liquidity_pool_storage
                    .write(
                        LiquidityPool {
                            total_liquidity: liquidity.total_liquidity,
                            total_borrowed: liquidity.total_borrowed
                                - amount
                                - converted_interest / fpow(10, converted_decimals, )
                        }
                    );
            } else {
                assert(
                    borrow_token_dispatcher.transfer_from(caller, recipient, amount.into()),
                    'repay transfer failed'
                );
                //NEED TO HANDLE THE INTEREST DUE REDISTRIBUTION
                self
                    .user_balances_storage
                    .write(
                        caller,
                        UserBalance {
                            deposited: user_balance.deposited,
                            borrowed: user_balance.borrowed
                                + (converted_interest / fpow(10, converted_decimals) - amount)
                        }
                    );
            }

            self.emit(Event::RepayEvent(RepayEvent { user: caller, amount: amount }));
        }
        fn liquidate(ref self: ContractState, user: ContractAddress) {
            let caller = info::get_caller_address();
            let user_balance = self.user_balances_storage.read(user);
            assert(user_balance.deposited > 0, 'User has no collateral');
            let (interest, interest_decimals) = compute_interest_rate(@self, ASSET_ID);
            let converted_interest = interest.try_into().unwrap();
            let converted_interest_decimals = interest_decimals.try_into().unwrap();
            let (collateral_price, price_decimals) = get_asset_price(@self, ASSET_ID);
            let converted_price_decimals = price_decimals.try_into().unwrap();
            let converted_collateral_price = collateral_price.try_into().unwrap();
            let collateral_value = user_balance.deposited * converted_collateral_price; //*10^price_decimals
            let total_debt = user_balance.borrowed*fpow(10,converted_interest_decimals) + converted_interest; //*10^interest_decimals
            
            let collateral_ratio = if (converted_price_decimals>converted_interest_decimals){ 
                (collateral_value * 100*fpow(10,converted_price_decimals-converted_interest_decimals)) / (total_debt)
            }else { 
                (collateral_value * 100) / (total_debt*fpow(10,converted_interest_decimals-converted_price_decimals))
            };
            assert(collateral_ratio < LIQUIDATION_THRESHOLD, 'user not below liq threshol');
            self.user_balances_storage.write(caller, UserBalance { deposited: 0, borrowed: 0 });
            self.emit(Event::LiquidateEvent(LiquidateEvent { user: caller, amount: 0 }));
            return();
        }
    }
    fn compute_interest_rate(self: @ContractState, asset_id: felt252) -> (felt252, felt252) {
        let summary_stats_address =
            contract_address_const::<0x010181a8a9f738e0ae49007079157428c7ea562d279718a67a325bc4537bc60e>();
        let oracle_dispatcher = SummaryStatsABIDispatcher {
            contract_address: summary_stats_address
        };
        let timestamp = info::get_block_timestamp();
        let start = timestamp - 2592000; // 1 month ago
        let end = timestamp; // now
        let num_samples = 200;

        let volatility = oracle_dispatcher
            .calculate_volatility(asset_id, start.into(), end.into(), num_samples);
        //The volatility is returned *10^8 (to keep decimals)
        let base_rate = 0;
        let scaling_factor = 3 * fpow(10, 4); //*10^6 (to keep decimals), real value is 0.03
        let interest_rate = base_rate + volatility * scaling_factor.into();
        return (
            interest_rate, 8 + 6
        ); //8 number of decimals for the volatility and 6 the number of decimals for the scaling factor
    }

    fn get_asset_price(self: @ContractState, asset_id: felt252) -> (felt252, felt252) {
        //exercice 1 
        let oracle_dispatcher = PragmaOracleDispatcher {
            contract_address: contract_address_const::<0x446812bac98c08190dee8967180f4e3cdcd1db9373ca269904acb17f67f7093>()
        };
        // Call the Oracle contract
        let (price, decimals, last_updated_timestamp, num_sources_aggregated) = oracle_dispatcher
            .get_spot_median(asset_id);
        assert(
            last_updated_timestamp.try_into().unwrap() > info::get_block_timestamp() - ONE_HOUR,
            'price is too old'
        );
        return (price, decimals);

    }

    
}
