use starknet::ContractAddress;
use Lendingprotocol::contracts::lending::{
    ILendingProtocolABIDispatcherTrait, ILendingProtocolABIDispatcher, LendingProtocol
};
use Lendingprotocol::interfaces::Pragma::{PragmaOracleDispatcher, PragmaOracleDispatcherTrait, DataType, AggregationMode};
use Lendingprotocol::contracts::erc20::{erc_20, IERC20Dispatcher, IERC20DispatcherTrait};
use Lendingprotocol::contracts::oracle::Oracle;
use array::ArrayTrait;
use starknet::contract_address_const;
use serde::Serde;
use debug::PrintTrait;
use starknet::syscalls::deploy_syscall;
use starknet::testing::{
    set_caller_address, set_contract_address, set_block_timestamp, set_chain_id
};
use alexandria_math::math::fpow;
use starknet::info;
use starknet::SyscallResultTrait;
use traits::{TryInto, Into};
use result::ResultTrait;
use option::OptionTrait;
const CHAIN_ID: felt252 = 'SN_GOERLI';
const BLOCK_TIMESTAMP: u64 = 1693713892;
const INITIAL_SUPPLY: u128 = 100000000000000000000000000;
const ASSET_1: felt252 = 'ASSET1/USD'; //collateral
const ASSET_2: felt252 = 'ASSET2/USD'; //borrow
fn setup() -> (ILendingProtocolABIDispatcher, IERC20Dispatcher, IERC20Dispatcher, PragmaOracleDispatcher) {
    let admin =
        contract_address_const::<0x0092cC9b7756E6667b654C0B16d9695347AF788EFBC00a286efE82a6E46Bce4b>();
    set_contract_address(admin);
    set_chain_id(CHAIN_ID);

    //oracle 
    let oracle_calldata = ArrayTrait::<felt252>::new();
    let (oracle_contract_address, _) = deploy_syscall(
        Oracle::TEST_CLASS_HASH.try_into().unwrap(), 0, oracle_calldata.span(), true
    )
        .unwrap_syscall();
    let mut oracle = PragmaOracleDispatcher{contract_address : oracle_contract_address};
    //token 1
    let mut token_1_calldata = ArrayTrait::new();
    let token_1: felt252 = 'Pragma1';
    let symbol_1: felt252 = 'PRA1';
    let decimal: u8 = 8;
    let initial_supply: u256 = u256 { high: 0, low: INITIAL_SUPPLY };
    token_1.serialize(ref token_1_calldata);
    symbol_1.serialize(ref token_1_calldata);
    decimal.serialize(ref token_1_calldata);
    initial_supply.serialize(ref token_1_calldata);
    admin.serialize(ref token_1_calldata);
    let (token_1_address, _) = deploy_syscall(
        erc_20::TEST_CLASS_HASH.try_into().unwrap(), 0, token_1_calldata.span(), true
    )
        .unwrap_syscall();
    let mut token_1 = IERC20Dispatcher { contract_address: token_1_address };

    //token 2
    let mut token_2_calldata = ArrayTrait::new();
    let token_2: felt252 = 'Pragma2';
    let symbol_2: felt252 = 'PRA2';
    token_2.serialize(ref token_2_calldata);
    symbol_2.serialize(ref token_2_calldata);
    decimal.serialize(ref token_2_calldata);
    initial_supply.serialize(ref token_2_calldata);
    admin.serialize(ref token_2_calldata);
    let (token_2_address, _) = deploy_syscall(
        erc_20::TEST_CLASS_HASH.try_into().unwrap(), 0, token_2_calldata.span(), true
    )
        .unwrap_syscall();
    let mut token_2 = IERC20Dispatcher { contract_address: token_2_address };
    let mut constructor_calldata = ArrayTrait::new();
    let borrow_address: ContractAddress = token_1_address;
    let collateral_address: ContractAddress = token_2_address;
    borrow_address.serialize(ref constructor_calldata);
    collateral_address.serialize(ref constructor_calldata);
    oracle_contract_address.serialize(ref constructor_calldata);
    let (lending_protocol_address, _) = deploy_syscall(
        LendingProtocol::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_calldata.span(), true
    )
        .unwrap_syscall();
    let mut lending_protocol = ILendingProtocolABIDispatcher {
        contract_address: lending_protocol_address
    };
    let d_supply = initial_supply / 10;

    token_1.approve(lending_protocol_address, initial_supply);
    token_1.transfer(lending_protocol_address, d_supply); //INTIAL WORKING ENTRY

    token_2.approve(lending_protocol_address, initial_supply);
    token_2.transfer(lending_protocol_address, d_supply); //INIITAL WORKING ENTRY
    lending_protocol.set_init_total_liquidity(initial_supply.low / 10);
    return (lending_protocol, token_1, token_2, oracle);
}

//TO CHECK: FOR THE LENDING PROTOCOL, WORKING WITH AMOUNTS
//ASSET 1 : collateral price : 186400000000
//ASSET 2 : borrowed price : 46700000000

#[test]
#[available_gas(1000000000)]
fn test_lending_deploy() {
    // in this code, amounts are multiplied by 10^SCALING_FACTOR_INDEX, e.g. 10^8
    set_block_timestamp(BLOCK_TIMESTAMP);
    let admin =
        contract_address_const::<0x0092cC9b7756E6667b654C0B16d9695347AF788EFBC00a286efE82a6E46Bce4b>();
    let (lending_protocol, token_1, token_2, oracle) = setup();

    //Parameters
    let collateral_price = oracle.get_data_median(DataType::SpotEntry(ASSET_1));
    let borrow_price = oracle.get_data_median(DataType::SpotEntry(ASSET_2));
    let deposited_amount = 100000000;
    let borrow_amount =300000000;
    let withdraw_amount = 30000000;
    let repay_amount = 200000000;
    
    set_contract_address(admin);
    lending_protocol.deposit(deposited_amount);
    let user = lending_protocol.get_user_balance(admin);
    assert(user.deposited == deposited_amount, 'wrong deposited value');
    assert(user.borrowed == 0, 'wrong borrowed value');
    let equivalent_borrowed_value = (deposited_amount * collateral_price.price) / borrow_price.price;
    assert(
        lending_protocol.get_total_liquidity() == INITIAL_SUPPLY / 10 + equivalent_borrowed_value,
        'wrong total liquidity'
    );
    assert(lending_protocol.get_total_borrowed() == 0, 'wrong total borrowed');
    lending_protocol.borrow(borrow_amount);
    assert(
        lending_protocol.get_user_balance(admin).borrowed == borrow_amount,
        'wrong borrowed value(borrow)'
    );
    assert(
        lending_protocol.get_user_balance(admin).deposited == deposited_amount,
        'wrong deposited value(borrow)'
    );
    assert(
        lending_protocol.get_total_liquidity() == INITIAL_SUPPLY / 10 + equivalent_borrowed_value,
        'wrong liquidity(borrow)'
    );
    assert(lending_protocol.get_total_borrowed() == borrow_amount, 'wrong total borrowed(borrow)');
    lending_protocol.withdraw(withdraw_amount);
    assert(
        lending_protocol.get_user_balance(admin).deposited == deposited_amount - withdraw_amount,
        'wrong user deposit(withdraw)'
    );
    assert(
        lending_protocol.get_user_balance(admin).borrowed == borrow_amount,
        'wrong user borrowed(withdraw)'
    );
    assert(
        lending_protocol.get_total_liquidity() == INITIAL_SUPPLY / 10
            + equivalent_borrowed_value
            - (withdraw_amount * collateral_price.price) / (borrow_price.price),
        'wrong liquidity(withdraw)'
    );
    assert(lending_protocol.get_total_borrowed() == borrow_amount, 'wrong total borrowed(withdraw)');
    lending_protocol.repay(repay_amount);
    assert(
        lending_protocol.get_user_balance(admin).deposited == deposited_amount - withdraw_amount,
        'wrong user deposit(repay)'
    );
    assert(
        lending_protocol.get_user_balance(admin).borrowed == borrow_amount - repay_amount + 48600000,
        'wrong user borrowed(repay)'
    );
    assert(
        lending_protocol.get_total_liquidity() == INITIAL_SUPPLY / 10
            + equivalent_borrowed_value
            - (withdraw_amount * collateral_price.price) / (borrow_price.price)
            + repay_amount
            - 48600000, //interest
        'wrong liquidity(repay)'
    );
    assert(
        lending_protocol.get_total_borrowed() == borrow_amount - repay_amount + 48600000,
        'wrong total borrowed(repay)'
    );
    assert(
        lending_protocol.get_user_balance(admin).borrowed == borrow_amount - repay_amount + 48600000,
        'wrong repay value'
    ); //the last element is the interest rate 
    lending_protocol.borrow(100000000);
    lending_protocol.liquidate(admin);
    assert(lending_protocol.get_total_borrowed() == 0, 'liquidation failed');
    assert(
        lending_protocol.get_total_liquidity() == INITIAL_SUPPLY / 10
            + equivalent_borrowed_value
            - (withdraw_amount * collateral_price.price) / (borrow_price.price)
            + repay_amount
            - 48600000, //interests
        'wrong liquidity:liquidate'
    );
    assert(lending_protocol.get_user_balance(admin).borrowed == 0, 'wrong user balance');
    assert(lending_protocol.get_user_balance(admin).deposited == 0, 'wrong user balance');
    return ();
}
//CHECK UP TOTAL LIQUIDITY EVOLUTION


