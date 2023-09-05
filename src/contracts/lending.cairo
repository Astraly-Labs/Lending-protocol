use starknet::ContractAddress;


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


#[starknet::interface]
trait ILendingProtocolABI<TContractState> {
    fn get_total_liquidity(self: @TContractState) -> u128;
    fn get_total_borrowed(self: @TContractState) -> u128;
    fn get_user_balance(self: @TContractState, user: ContractAddress) -> UserBalance;
    //
    fn deposit(ref self: TContractState, amount: u128);
    fn withdraw(ref self: TContractState, amount: u128);
    fn borrow(ref self: TContractState, amount: u128);
    fn repay(ref self: TContractState, amount: u128);
    fn liquidate(ref self: TContractState, user: ContractAddress);
}


#[starknet::contract]
mod LendingProtocol {
    use array::ArrayTrait;
    use super::{ContractAddress, ILendingProtocolABI, UserBalance, LiquidityPool};
    use Lendingprotocol::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use Lendingprotocol::interfaces::Pragma::{
        PragmaOracleDispatcher, PragmaOracleDispatcherTrait, DataType, AggregationMode,
        PragmaPricesResponse
    };
    use starknet::info;
    use debug::PrintTrait;
    use traits::Into;
    use serde::Serde;


    use result::ResultTrait;
    use traits::TryInto;
    use option::OptionTrait;
    use starknet::contract_address_const;
    use alexandria_math::math::fpow;
    const BORROW_THRESHOLD: u128 = 110;
    const LIQUIDATION_THRESHOLD: u128 = 150;
    const SCALING_FACTOR_INDEX: u32 = 8;
    const ASSET_1: felt252 = 'ASSET1/USD'; //collateral
    const ASSET_2: felt252 = 'ASSET2/USD'; //borrow
    const ONE_HOUR: u64 = 3600;


    #[storage]
    struct Storage {
        borrow_token_storage: ContractAddress,
        collateral_token_storage: ContractAddress,
        oracle_address_storage: ContractAddress,
        liquidity_pool_storage: LiquidityPool,
        user_balances_storage: LegacyMap<ContractAddress, UserBalance>
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, borrow_token: ContractAddress, collateral_token: ContractAddress, oracle_address : ContractAddress
    ) {
        self.borrow_token_storage.write(borrow_token);
        self.collateral_token_storage.write(collateral_token);
        self.oracle_address_storage.write(oracle_address);
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
        fn get_total_liquidity(self: @ContractState) -> u128 {
            self.liquidity_pool_storage.read().total_liquidity
        }

        fn get_total_borrowed(self: @ContractState) -> u128 {
            self.liquidity_pool_storage.read().total_borrowed
        }

        fn get_user_balance(self: @ContractState, user: ContractAddress) -> UserBalance {
            self.user_balances_storage.read(user)
        }
        fn deposit(ref self: ContractState, amount: u128) {
            // amount must be multiplied by the scaling factor (10^SCALING_FACTOR_INDEX)
            //This allows to use decimal values for operations 
            let deposit_token = self.collateral_token_storage.read();
            let deposit_token_dispatcher = IERC20Dispatcher { contract_address: deposit_token };

            let caller = info::get_caller_address();
            let recipient = info::get_contract_address();
            deposit_token_dispatcher.transfer_from(caller, recipient, amount.into());

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
            return ();
        }

        fn withdraw(ref self: ContractState, amount: u128) {
            // amount must be multiplied by the scaling factor (10^SCALING_FACTOR_INDEX)

            let caller = info::get_caller_address();
            let user_balance = self.user_balances_storage.read(caller);
            assert(amount <= user_balance.deposited, 'Not enough deposited');

    
            let (interest, interest_decimals) = compute_interest_rate(@self, ASSET_2); 

    
            let (collateral_price, c_price_decimals) = get_asset_price(@self, ASSET_1);
            let (borrow_price, b_price_decimals) = get_asset_price(@self, ASSET_2);


            let new_debt = user_balance.borrowed * borrow_price * ( fpow(10, interest_decimals.into())
                + interest ) ;

            
        

            // IN OUR CASE, C_PRICE_DECIMALS = B_PRICE_DECIMALS, SO NO NEED TO HANDLE DECIMALS TRANSFORMATION

            let collateral_value = (user_balance.deposited*collateral_price)
                * fpow(10, interest_decimals.into());

            let mut collateral_ratio = (collateral_value * 100) / new_debt;

            assert(collateral_ratio > BORROW_THRESHOLD, 'user below safety ratio');

            let withdrawable = if user_balance.borrowed == 0 {
                user_balance.deposited
            } else {
                (user_balance.deposited / collateral_ratio) * (collateral_ratio - BORROW_THRESHOLD)
            };

            assert(withdrawable >= amount, 'amount unsafe to withdraw');

            self
                .user_balances_storage
                .write(
                    caller,
                    UserBalance {
                        deposited: user_balance.deposited - amount, borrowed: user_balance.borrowed
                    }
                );
            let deposit_token = self.collateral_token_storage.read();
            let deposit_token_dispatcher = IERC20Dispatcher { contract_address: deposit_token };

            deposit_token_dispatcher.transfer(caller, amount.into());

            self.emit(Event::WithdrawEvent(WithdrawEvent { user: caller, amount: amount }));
            return ();
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


            let (collateral_price, c_price_decimals) = get_asset_price(@self, ASSET_1);
            let (borrow_price, b_price_decimals) = get_asset_price(@self, ASSET_2);
            let new_debt = (amount + user_balance.borrowed) *borrow_price;
            let collateral_ratio = (user_balance.deposited*collateral_price * 100) / (new_debt);
            assert(collateral_ratio >= BORROW_THRESHOLD, 'not enough collateral');
            let borrow_token = self.borrow_token_storage.read();
            let borrow_token_dispatcher = IERC20Dispatcher { contract_address: borrow_token };
            let recipient = info::get_contract_address();
            borrow_token_dispatcher.transfer(caller, amount.into());

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
            return ();
        }
        fn repay(ref self: ContractState, amount: u128) {
            assert(amount > 0, 'Cannot repay 0');
            let caller = info::get_caller_address();
            let (interest, decimals) = compute_interest_rate(@self, ASSET_2);
            let user_balance = self.user_balances_storage.read(caller);
            let borrow_token = self.borrow_token_storage.read();
            let borrow_token_dispatcher = IERC20Dispatcher { contract_address: borrow_token };
            let recipient = info::get_contract_address();
            let liquidity = self.liquidity_pool_storage.read();
            let to_pay = (user_balance.borrowed * fpow(10, decimals.into())
                + interest * user_balance.borrowed)
                / fpow(10, decimals.into());
            let interest_amount = interest * user_balance.borrowed;
            if (amount >= to_pay) {
                borrow_token_dispatcher.transfer_from(caller, recipient, to_pay.into());

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
            } else if (amount >= interest_amount / fpow(10, decimals.into())) {
                borrow_token_dispatcher.transfer_from(caller, recipient, amount.into());

                self
                    .user_balances_storage
                    .write(
                        caller,
                        UserBalance {
                            deposited: user_balance.deposited,
                            borrowed: user_balance.borrowed
                                - amount
                                - interest_amount / fpow(10, decimals.into())
                        }
                    );
                self
                    .liquidity_pool_storage
                    .write(
                        LiquidityPool {
                            total_liquidity: liquidity.total_liquidity,
                            total_borrowed: liquidity.total_borrowed
                                - amount
                                - interest_amount / fpow(10, decimals.into() )
                        }
                    );
            } else {
                borrow_token_dispatcher.transfer_from(caller, recipient, amount.into());

                self
                    .user_balances_storage
                    .write(
                        caller,
                        UserBalance {
                            deposited: user_balance.deposited,
                            borrowed: user_balance.borrowed
                                + (interest_amount / fpow(10, decimals.into()) - amount)
                        }
                    );
            }

            self.emit(Event::RepayEvent(RepayEvent { user: caller, amount: amount }));
        }
        fn liquidate(ref self: ContractState, user: ContractAddress) {
            let caller = info::get_caller_address();
            let user_balance = self.user_balances_storage.read(user);
            assert(user_balance.deposited > 0, 'User has no collateral');
            let liquidity = self.liquidity_pool_storage.read();

            let (interest, interest_decimals) = compute_interest_rate(@self, ASSET_2);
            let new_debt = user_balance.borrowed * fpow(10, interest_decimals.into())
                + interest * user_balance.borrowed;

            let collateral_value = user_balance.deposited * fpow(10, interest_decimals.into());

            let mut collateral_ratio = (collateral_value * 100) / new_debt;
            collateral_ratio.print();
            assert(collateral_ratio < LIQUIDATION_THRESHOLD, 'user not below liq threshol');
            self
                .liquidity_pool_storage
                .write(
                    LiquidityPool {
                        total_liquidity: liquidity.total_liquidity,
                        total_borrowed: liquidity.total_borrowed - user_balance.borrowed
                    }
                );
            self.user_balances_storage.write(caller, UserBalance { deposited: 0, borrowed: 0 });
            self.emit(Event::LiquidateEvent(LiquidateEvent { user: caller, amount: 0 }));
            return ();
        }
    }
    fn compute_interest_rate(self: @ContractState, asset_id: felt252) -> (u128, u32) {
        let oracle_contract_address = self.oracle_address_storage.read();
        let oracle_dispatcher = PragmaOracleDispatcher {
            contract_address: oracle_contract_address
        };
        let timestamp = info::get_block_timestamp();
        let start = timestamp - 2592000; // 1 month ago
        let end = timestamp; // now
        let num_samples = 200;

        let (volatility, vol_decimals) = oracle_dispatcher
            .calculate_volatility(
                DataType::SpotEntry(asset_id),
                start.into(),
                end.into(),
                num_samples,
                AggregationMode::Median(())
            );
        //The volatility is returned *10^8 (to keep decimals)
        let base_rate = 0;
        let scaling_factor = 3 * fpow(10, 2); //*10^4 (to keep decimals), real value is 0.03
        let interest_rate = base_rate + volatility * scaling_factor.into();
        let total_decimals: u32 = 8 + 4;
        return (
            interest_rate, total_decimals
        ); //8 number of decimals for the volatility and 6 the number of decimals for the scaling factor
    }

    fn get_asset_price(self: @ContractState, asset_id: felt252) -> (u128, u32) {
        //exercice 1 
        let oracle_contract_address = self.oracle_address_storage.read();
        let oracle_dispatcher = PragmaOracleDispatcher {
            contract_address: oracle_contract_address
        };

        // Call the Oracle contract
        let output: PragmaPricesResponse = oracle_dispatcher
            .get_data_median(DataType::SpotEntry(asset_id));
        assert(
            output.last_updated_timestamp > info::get_block_timestamp() - ONE_HOUR,
            'price is too old'
        );
        return (output.price, output.decimals);
    }
}
