const TARGET_CHAIN_ID = "0x1aa5"; // Arbitrum Sepolia Hexadecimal Chain Matrix
const ALCHEMY_RPC_URL = "https://eth-mainnet.g.alchemy.com/v2/ZBEvTc4O3PQO8krFEe7M4";
const GRAPH_API_URI = "https://api.thegraph.com/subgraphs/name/yourteam/defi-super-app";

const CONTRACT_ADDRESSES = {
    governanceToken: "0xYourDeployedGovernanceTokenAddress",
    defiGovernor: "0xYourDeployedDeFiGovernorAddress",
    yieldVault: "0xYourDeployedYieldVaultAddress",
    lpPositionNFT: "0xYourDeployedLPPositionNFTAddress",
    ammPairProxy: "0xYourActiveAMMPairProxyAddress" 
};

const GOVERNANCE_TOKEN_ABI = [
    "function balanceOf(address account) view returns (uint256)",
    "function delegates(address account) view returns (address)",
    "function getVotes(address account) view returns (uint256)",
    "function delegate(address delegatee) returns ()",
    "function approve(address spender, uint256 amount) returns (bool)",
    "error MaxSupplyExceeded()",
    "error ZeroAddress()"
];

const STANDARD_ERC20_ABI = [
    "function balanceOf(address account) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)"
];

const GOVERNOR_ABI = [
    "function castVote(uint256 proposalId, uint8 support) returns (uint256)",
    "function proposalThreshold() view returns (uint256)"
];

const YIELD_VAULT_ABI = [
    "function asset() view returns (address)",
    "function balanceOf(address account) view returns (uint256)",
    "function deposit(uint256 assets, address receiver) returns (uint256)"
];

const AMM_PAIR_ABI = [
    "function tokenA() view returns (address)",
    "function tokenB() view returns (address)",
    "function reserveA() view returns (uint256)",
    "function reserveB() view returns (uint256)",
    "function balanceOf(address account) view returns (uint256)",
    "function addLiquidity(uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin) returns (uint256 amountA, uint256 amountB, uint256 liquidity)",
    "function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin) returns (uint256 amountOut)",
    "error KInvariantViolated()",
    "error SlippageExceeded()",
    "error InsufficientLiquidity()"
];

const LP_NFT_ENUMERABLE_ABI = [
    "function balanceOf(address owner) view returns (uint256)",
    "function tokenOfOwnerByIndex(address owner, uint256 index) view returns (uint256)",
    "function positions(uint256 tokenId) view returns (address pair, uint256 lpAmount, uint256 mintedAt)"
];

// Context Architecture States
let provider = null;
let signer = null;
let currentAccount = "";
let currentChainId = "";

// Capture DOM Nodes
const connectBtn = document.getElementById("connectBtn");
const walletDetails = document.getElementById("walletDetails");
const accountDisplay = document.getElementById("accountDisplay");
const networkBadge = document.getElementById("networkBadge");
const errorBanner = document.getElementById("errorBanner");
const errorMessage = document.getElementById("errorMessage");
const depositInput = document.getElementById("depositAmount");
const submitDepositBtn = document.getElementById("submitDepositBtn");
const delegateSelfBtn = document.getElementById("delegateSelfBtn");
const nftContainer = document.getElementById("nftContainer");
const nftLoadingMsg = document.getElementById("nftLoadingMsg");
const proposalContainer = document.getElementById("proposalContainer");
const governanceStatusMsg = document.getElementById("governanceStatusMsg");

// Core AMM Element Injections
const amountADesiredInput = document.getElementById("amountADesired");
const amountBDesiredInput = document.getElementById("amountBDesired");
const submitLiquidityBtn = document.getElementById("submitLiquidityBtn");
const tokenInSelect = document.getElementById("tokenInSelect");
const swapAmountIn = document.getElementById("swapAmountIn");
const submitSwapBtn = document.getElementById("submitSwapBtn");

window.addEventListener('DOMContentLoaded', () => {
    if (window.ethereum) {
        window.ethereum.on('accountsChanged', handleAccountsChanged);
        window.ethereum.on('chainChanged', handleChainChanged);
    } else {
        showError("Web3 signature client missing. Install Metamask or Rabby extension framework.");
    }
});

connectBtn.addEventListener('click', connectWallet);
document.getElementById("vaultForm").addEventListener('submit', executeVaultDeposit);
delegateSelfBtn.addEventListener('click', executeSelfDelegation);
document.getElementById("addLiquidityForm").addEventListener('submit', executeAddLiquidity);
document.getElementById("swapForm").addEventListener('submit', executeAMMSwap);

async function connectWallet() {
    clearError();
    try {
        provider = new ethers.BrowserProvider(window.ethereum);
        const accounts = await provider.send("eth_requestAccounts", []);
        const network = await provider.getNetwork();
        
        currentChainId = "0x" + network.chainId.toString(16);
        signer = await provider.getSigner();
        currentAccount = accounts[0];

        updateDOMWalletElements();

        if (currentChainId !== TARGET_CHAIN_ID) {
            await enforceNetworkSwitch();
        } else {
            await runAggregationPipeline();
        }
    } catch (err) {
        handleExceptionLogs(err);
    }
}

async function enforceNetworkSwitch() {
    try {
        await window.ethereum.request({
            method: "wallet_switchEthereumChain",
            params: [{ chainId: TARGET_CHAIN_ID }]
        });
    } catch (err) {
        if (err.code === 4902) showError("Ecosystem target chain layout missing from provider arrays.");
        else handleExceptionLogs(err);
    }
}

function updateDOMWalletElements() {
    if (currentAccount) {
        connectBtn.classList.add("hidden");
        walletDetails.classList.remove("hidden");
        accountDisplay.innerText = `${currentAccount.slice(0, 6)}...${currentAccount.slice(-4)}`;
        
        const isCorrectChain = currentChainId === TARGET_CHAIN_ID;
        networkBadge.innerText = isCorrectChain ? "L2 Core Synchronized" : "MALFORMED NETWORK CONFIG";
        networkBadge.className = isCorrectChain ? "badge badge-green" : "badge badge-red";

        const inputs = [depositInput, amountADesiredInput, amountBDesiredInput, swapAmountIn, tokenInSelect];
        const buttons = [submitDepositBtn, delegateSelfBtn, submitLiquidityBtn, submitSwapBtn];
        
        inputs.forEach(i => isCorrectChain ? i.removeAttribute("disabled") : i.setAttribute("disabled", "true"));
        buttons.forEach(b => isCorrectChain ? b.removeAttribute("disabled") : b.setAttribute("disabled", "true"));
    }
}

async function runAggregationPipeline() {
    if (!provider || currentChainId !== TARGET_CHAIN_ID) return;
    try {
        const govToken = new ethers.Contract(CONTRACT_ADDRESSES.governanceToken, GOVERNANCE_TOKEN_ABI, provider);
        const vault = new ethers.Contract(CONTRACT_ADDRESSES.yieldVault, YIELD_VAULT_ABI, provider);
        const ammPair = new ethers.Contract(CONTRACT_ADDRESSES.ammPairProxy, AMM_PAIR_ABI, provider);

        const [govBal, votingPower, currentDelegate, vaultShares, lpBalance] = await Promise.all([
            govToken.balanceOf(currentAccount),
            govToken.getVotes(currentAccount),
            govToken.delegates(currentAccount),
            vault.balanceOf(currentAccount),
            ammPair.balanceOf(currentAccount)
        ]);

        document.getElementById("govBalance").innerText = parseFloat(ethers.formatEther(govBal)).toFixed(4);
        document.getElementById("votingPower").innerText = parseFloat(ethers.formatEther(votingPower)).toFixed(4);
        document.getElementById("vaultShares").innerText = parseFloat(ethers.formatEther(vaultShares)).toFixed(4);
        document.getElementById("lpBalance").innerText = parseFloat(ethers.formatEther(lpBalance)).toFixed(4);
        
        document.getElementById("delegateDisplay").innerText = 
            currentDelegate === ethers.ZeroAddress ? "None Designated" : `${currentDelegate.slice(0, 6)}...${currentDelegate.slice(-4)}`;

        await pullUserNFTRecords();
        await syncTheGraphGovernanceData();
    } catch (err) {
        console.error("Aggregation node failed to capture balances: ", err);
    }
}

async function executeAddLiquidity(e) {
    e.preventDefault();
    clearError();
    try {
        const ammPair = new ethers.Contract(CONTRACT_ADDRESSES.ammPairProxy, AMM_PAIR_ABI, signer);
        const tokenAAddress = await ammPair.tokenA();
        const tokenBAddress = await ammPair.tokenB();

        const tA = new ethers.Contract(tokenAAddress, STANDARD_ERC20_ABI, signer);
        const tB = new ethers.Contract(tokenBAddress, STANDARD_ERC20_ABI, signer);

        const rawA = ethers.parseEther(amountADesiredInput.value);
        const rawB = ethers.parseEther(amountBDesiredInput.value);

        submitLiquidityBtn.innerText = "Authorizing Base Assets...";
        // Sequential Approval execution logic
        await (await tA.approve(CONTRACT_ADDRESSES.ammPairProxy, rawA)).wait();
        await (await tB.approve(CONTRACT_ADDRESSES.ammPairProxy, rawB)).wait();

        submitLiquidityBtn.innerText = "Interacting with Pool Proxy...";
        // Safe 1% default slippage bounds setup
        const tx = await ammPair.addLiquidity(rawA, rawB, (rawA * 99n) / 100n, (rawB * 99n) / 100n);
        await tx.wait();

        amountADesiredInput.value = "";
        amountBDesiredInput.value = "";
        await runAggregationPipeline();
    } catch (err) {
        handleExceptionLogs(err);
    } finally {
        submitLiquidityBtn.innerText = "Provide Dual Liquidity";
    }
}

async function executeAMMSwap(e) {
    e.preventDefault();
    clearError();
    try {
        const ammPair = new ethers.Contract(CONTRACT_ADDRESSES.ammPairProxy, AMM_PAIR_ABI, signer);
        const tokenInAddress = tokenInSelect.value === "tokenA" ? await ammPair.tokenA() : await ammPair.tokenB();
        const tIn = new ethers.Contract(tokenInAddress, STANDARD_ERC20_ABI, signer);

        const amountInParsed = ethers.parseEther(swapAmountIn.value);

        submitSwapBtn.innerText = "Unlocking Asset Allowance...";
        await (await tIn.approve(CONTRACT_ADDRESSES.ammPairProxy, amountInParsed)).wait();

        submitSwapBtn.innerText = "Evaluating Constant Product K...";
        // Execution with defensive custom slippage baseline parameters
        const tx = await ammPair.swap(tokenInAddress, amountInParsed, 1n); 
        await tx.wait();

        swapAmountIn.value = "";
        await runAggregationPipeline();
    } catch (err) {
        handleExceptionLogs(err);
    } finally {
        submitSwapBtn.innerText = "Execute Custom Swap";
    }
}

async function executeVaultDeposit(e) {
    e.preventDefault();
    clearError();
    try {
        const vault = new ethers.Contract(CONTRACT_ADDRESSES.yieldVault, YIELD_VAULT_ABI, signer);
        const underlying = await vault.asset();
        const tIn = new ethers.Contract(underlying, STANDARD_ERC20_ABI, signer);
        
        const size = ethers.parseEther(depositInput.value);
        submitDepositBtn.innerText = "Approving underlying asset...";
        await (await tIn.approve(CONTRACT_ADDRESSES.yieldVault, size)).wait();
        
        submitDepositBtn.innerText = "Depositing into vault matrix...";
        await (await vault.deposit(size, currentAccount)).wait();
        
        depositInput.value = "";
        await runAggregationPipeline();
    } catch (err) {
        handleExceptionLogs(err);
    } finally {
        submitDepositBtn.innerText = "Approve & Deposit Assets";
    }
}

async function executeSelfDelegation() {
    clearError();
    try {
        const token = new ethers.Contract(CONTRACT_ADDRESSES.governanceToken, GOVERNANCE_TOKEN_ABI, signer);
        await (await token.delegate(currentAccount)).wait();
        await runAggregationPipeline();
    } catch (err) {
        handleExceptionLogs(err);
    }
}

async function pullUserNFTRecords() {
    try {
        const nftContract = new ethers.Contract(CONTRACT_ADDRESSES.lpPositionNFT, LP_NFT_ENUMERABLE_ABI, provider);
        const ownedNFTCount = await nftContract.balanceOf(currentAccount);
        nftLoadingMsg.classList.add("hidden");
        nftContainer.innerHTML = "";

        if (ownedNFTCount == 0n) {
            nftContainer.innerHTML = `<p class="status-msg">No liquidity position tracking tokens found.</p>`;
            return;
        }
        for (let i = 0; i < Number(ownedNFTCount); i++) {
            const tokenId = await nftContract.tokenOfOwnerByIndex(currentAccount, i);
            const pos = await nftContract.positions(tokenId);
            const gridCard = document.createElement("div");
            gridCard.className = "nft-card";
            gridCard.innerHTML = `
                <h4>Position Tracker ID: #${tokenId.toString()}</h4>
                <p style="font-size:12px; margin:4px 0;"><strong>AMM Pool Node:</strong> ${pos.pair.slice(0,6)}...${pos.pair.slice(-4)}</p>
                <p style="font-size:12px; margin:4px 0;"><strong>Deposited Asset size:</strong> ${parseFloat(ethers.formatEther(pos.lpAmount)).toFixed(4)} LP</p>
            `;
            nftContainer.appendChild(gridCard);
        }
    } catch (err) { console.error(err); }
}

async function syncTheGraphGovernanceData() {
    const graphQLQueryPayload = { query: `{ proposals(orderBy: startBlock, orderDirection: desc, first: 5) { id description } }` };
    try {
        const response = await fetch(GRAPH_API_URI, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(graphQLQueryPayload)
        });
        const deserializedData = await response.json();
        const activeProposals = deserializedData.data?.proposals || [];
        governanceStatusMsg.classList.add("hidden");
        proposalContainer.innerHTML = "";

        if (activeProposals.length === 0) {
            proposalContainer.innerHTML = `<p class="status-msg">No active proposal indices detected.</p>`;
            return;
        }
        activeProposals.forEach(proposal => {
            const rowItem = document.createElement("div");
            rowItem.className = "proposal-item";
            rowItem.innerHTML = `
                <p><strong>Proposal ID (Hash):</strong> ${proposal.id.slice(0, 16)}...</p>
                <p style="color: #cbd5e1; margin: 8px 0;">${proposal.description || 'No specific proposal text provided.'}</p>
                <div class="proposal-actions">
                    <button class="btn btn-success" onclick="castVoteOnChain('${proposal.id}', 1)">Vote For (YAE)</button>
                    <button class="btn btn-danger" onclick="castVoteOnChain('${proposal.id}', 0)">Vote Against (NAY)</button>
                </div>
            `;
            proposalContainer.appendChild(rowItem);
        });
    } catch (err) { governanceStatusMsg.innerText = "Error pulling indexer metrics."; }
}

async function castVoteOnChain(proposalId, positionSelection) {
    clearError();
    try {
        const governorWithSigner = new ethers.Contract(CONTRACT_ADDRESSES.defiGovernor, GOVERNOR_ABI, signer);
        await (await governorWithSigner.castVote(proposalId, positionSelection)).wait();
        alert(`Voting choice finalized on-chain.`);
        await runAggregationPipeline();
    } catch (err) { handleExceptionLogs(err); }
}
window.castVoteOnChain = castVoteOnChain;

function handleExceptionLogs(error) {
    console.error("Tracking transaction failure: ", error);
    if (error.code === "ACTION_REJECTED" || error.message?.includes("user rejected")) {
        showError("The signature request was declined by the user signature device.");
        return;
    }
    const textualMessage = error.message || "";
    if (textualMessage.includes("KInvariantViolated")) {
        showError("Yul Execution Exception: The constant product constant (x * y = k) dropped below bounds.");
    } else if (textualMessage.includes("SlippageExceeded")) {
        showError("Transaction Reverted: Output amount falls below defined minimum slippage protection bounds.");
    } else if (textualMessage.includes("MaxSupplyExceeded")) {
        showError("Revert Exception: Mint allocation constraints exceed global MAX_SUPPLY parameters.");
    } else {
        showError(error.reason || textualMessage || "An unhandled transaction pipeline exception occurred.");
    }
}

function showError(message) { errorMessage.innerText = message; errorBanner.classList.remove("hidden"); }
function clearError() { errorBanner.classList.add("hidden"); }
function handleAccountsChanged(accounts) { currentAccount = accounts[0] || ""; updateDOMWalletElements(); runAggregationPipeline(); }
function handleChainChanged(hexChainId) { currentChainId = hexChainId; updateDOMWalletElements(); runAggregationPipeline(); }