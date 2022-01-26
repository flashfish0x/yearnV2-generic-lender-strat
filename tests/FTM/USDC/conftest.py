import pytest
from brownie import Wei, config, Contract

@pytest.fixture
def ftm_dai(interface):
    #ftm dai!
    yield interface.ERC20('0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E')

@pytest.fixture
def ftm_usdc(interface):
    #ftm usdc
    yield interface.ERC20('0x04068DA6C83AFCFA0e13ba15A6696662335D5B75')

@pytest.fixture
def hUsdc(interface):
    yield interface.CErc20I("0x243E33aa7f6787154a8E59d3C27a66db3F8818ee")

@pytest.fixture
def hUsdc_guage(Contract):
    yield Contract('0x110614276F7b9Ae8586a1C1D9Bc079771e2CE8cF')

@pytest.fixture
def ibUsdc(interface):
    yield interface.CErc20I("0x328A7b4d538A2b3942653a9983fdA3C12c571141")

@pytest.fixture
def gov(accounts):
    yield accounts.at('0xC0E2830724C946a6748dDFE09753613cd38f6767', force=True)

@pytest.fixture
def whale(accounts):
    yield accounts.at("0x93C08a3168fC469F3fC165cd3A471D19a37ca19e", force=True)

@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract

@pytest.fixture
def guardian(accounts):
    # YFI Whale, probably
    yield accounts[2]

@pytest.fixture
def strategist(accounts):
    # YFI Whale, probably
    yield accounts[2]

@pytest.fixture
def keeper(accounts):
    # This is our trusty bot!
    yield accounts[4]

@pytest.fixture
def vault(gov, rewards, guardian, ftm_usdc, pm):
    Vault = pm(config["dependencies"][0]).Vault
    vault = Vault.deploy({"from": guardian})
    vault.initialize(ftm_usdc, gov, rewards, "", "")
    vault.setDepositLimit(2**256-1, {"from": gov})

    yield vault

@pytest.fixture
def Vault(pm):
    yield pm(config["dependencies"][0]).Vault

@pytest.fixture
def live_ftm_dai_strategy(
    Strategy
): 
    yield Strategy.at('0x754133e0f67CB51263d6d5F41f2dF1a58a9D36b7')


@pytest.fixture
def strategy(
    strategist,
    keeper,
    vault,
    gov,
    Strategy,
    GenericScream,
    GenericIronBank,
    hUsdc_guage,
    hUsdc,
    ibUsdc,
    GenericHundredFinance
):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)

    ibPlugin = strategist.deploy(GenericIronBank, strategy, "IB", ibUsdc)
    
    strategy.addLender(ibPlugin, {"from": gov})
    bPlugin = strategist.deploy(GenericHundredFinance, strategy, "Hundred",hUsdc, hUsdc_guage)

    print(bPlugin.compBlockShareInWant(0, True))
    print(bPlugin.apr()/1e18)
    
    strategy.addLender(bPlugin, {"from": gov})

    assert strategy.numLenders() == 2
    yield strategy
