const fetch = require('node-fetch');
const { artifacts, web3, accounts, network } = require('hardhat');
const { ether, time } = require('@openzeppelin/test-helpers');

const {
  submitGovernanceProposal,
  getAddressByCodeFactory,
  Address,
  fund,
  unlock,
} = require('./utils');
const { hex } = require('../utils').helpers;
const { ProposalCategory, CoverStatus } = require('../utils').constants;

const OwnedUpgradeabilityProxy = artifacts.require('OwnedUpgradeabilityProxy');
const MemberRoles = artifacts.require('MemberRoles');
const NXMaster = artifacts.require('NXMaster');
const NXMToken = artifacts.require('NXMToken');
const Governance = artifacts.require('Governance');
const TokenFunctions = artifacts.require('TokenFunctions');
const Quotation = artifacts.require('Quotation');
const TokenController = artifacts.require('TokenController');
const Gateway = artifacts.require('Gateway');
const Incidents = artifacts.require('Incidents');
const ERC20MintableDetailed = artifacts.require('ERC20MintableDetailed');
const Pool = artifacts.require('Pool');
const QuotationData = artifacts.require('QuotationData');

describe('sample test', function () {

  this.timeout(0);

  it('initializes contracts', async function () {

    const { mainnet: { abis } } = await fetch('https://api.nexusmutual.io/version-data/data.json').then(r => r.json());
    const getAddressByCode = getAddressByCodeFactory(abis);

    const token = await NXMToken.at(getAddressByCode('NXMTOKEN'));
    const memberRoles = await MemberRoles.at(getAddressByCode('MR'));
    const master = await NXMaster.at(getAddressByCode(('NXMASTER')));
    const governance = await Governance.at(getAddressByCode('GV'));
    this.master = master;
    this.memberRoles = memberRoles;
    this.token = token;
    this.governance = governance;
  });

  it('funds accounts', async function () {

    console.log('Funding accounts');

    const { memberArray: boardMembers } = await this.memberRoles.members('1');
    const voters = boardMembers.slice(1, 4);

    for (const member of [...voters, Address.NXMHOLDER]) {
      await fund(member);
      await unlock(member);
    }

    this.voters = voters;
  });

  it('upgrades contracts', async function () {
    const { master, governance, voters } = this;
    console.log('Deploying contracts');

    const newIncidents = await Incidents.new();
    const newQuotation = await Quotation.new();

    console.log('Upgrading proxy contracts');

    const upgradesActionDataProxy = web3.eth.abi.encodeParameters(
      ['bytes2[]', 'address[]'],
      [
        ['IC'].map(hex),
        [newIncidents].map(c => c.address),
      ],
    );

    await submitGovernanceProposal(
      ProposalCategory.upgradeProxy,
      upgradesActionDataProxy,
      voters,
      governance,
    );

    const icProxy = await OwnedUpgradeabilityProxy.at(await master.getLatestAddress(hex('IC')));
    const icImplementation = await icProxy.implementation();

    assert.equal(newIncidents.address, icImplementation);
    console.log('Proxy Upgrade successful.');

    console.log('Upgrading non-proxy contracts');

    const upgradesActionDataNonProxy = web3.eth.abi.encodeParameters(
      ['bytes2[]', 'address[]'],
      [
        ['QT'].map(hex),
        [newQuotation].map(c => c.address),
      ],
    );

    await submitGovernanceProposal(
      ProposalCategory.upgradeNonProxy,
      upgradesActionDataNonProxy,
      voters,
      governance,
    );
    const storedQTAddress = await master.getLatestAddress(hex('QT'));

    assert.equal(storedQTAddress, newQuotation.address);

    console.log('Non-proxy upgrade successful.');

    this.quotation = await Quotation.at(await master.getLatestAddress(hex('QT')));
  });

  require('./basic-functionality-tests');
});
