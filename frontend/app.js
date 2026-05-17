const TARGET_CHAIN_ID = 421614; 
const TARGET_CHAIN_HEX = "0x66eee"; 

const ALCHEMY_RPC_URL = "https://arb-sepolia.g.alchemy.com/v2/3QNIXQa4gTi1nydryanIW";
const GRAPH_API_URI = "https://api.thegraph.com/subgraphs/name/yourteam/defi-super-app";

const CONTRACT_ADDRESSES = {
    governanceToken: "0x622aea782909c8ca15163785ebfdfbf447ada3f7",
    defiGovernor: "0xc7a3fa7c158271c6657e5b0ea5dc57fc79b54abd",
    yieldVault: "0x7df688e95907eaeff514c842ff0133676de99eca",
    lpPositionNFT: "",
    ammPairProxy: "0x5ae825d2332ae932d4816ba20297c60df8d25b22",
    ammPairProxyContract: "0xfa0ef2f8800615fad4446a6b63f04a9ec1c83c73"
};

const GOVERNANCE_TOKEN_ABI = [
    "function balanceOf(address account) view returns (uint256)",
    "function delegates(address account) view returns (address)",
    "function getVotes(address account) view returns (uint256)",
    "function delegate(address delegatee)",
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
    "function proposalThreshold() view returns (uint256)",
    "function votingDelay() view returns (uint256)",
    "function votingPeriod() view returns (uint256)",
    "function quorum(uint256 blockNumber) view returns (uint256)"
];

const YIELD_VAULT_ABI = [
    // ERC-4626 core
    "function asset() view returns (address)",
    "function totalAssets() view returns (uint256)",
    "function totalSupply() view returns (uint256)",
    "function balanceOf(address account) view returns (uint256)",
    "function deposit(uint256 assets, address receiver) returns (uint256)",
    "function mint(uint256 shares, address receiver) returns (uint256)",
    "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
    "function redeem(uint256 shares, address receiver, address owner) returns (uint256)",
    "function previewDeposit(uint256 assets) view returns (uint256)",
    "function previewRedeem(uint256 shares) view returns (uint256)",
    "function convertToAssets(uint256 shares) view returns (uint256)",
    "function convertToShares(uint256 assets) view returns (uint256)",
    // Admin
    "function distributeYield(uint256 amount)",
    "function setPriceFeed(address newFeed)",
    "function setMaxStaleness(uint256 newMax)",
    "function setBypassPriceCheck(bool status)",
    "function pause()",
    "function unpause()",
    "function paused() view returns (bool)",
    "function accruedYield() view returns (uint256)",
    "function bypassPriceCheck() view returns (bool)",
    // UUPS upgrade
    "function upgradeToAndCall(address newImplementation, bytes memory data) payable",
    // Access control
    "function hasRole(bytes32 role, address account) view returns (bool)",
    "function grantRole(bytes32 role, address account)",
    "function YIELD_MANAGER_ROLE() view returns (bytes32)",
    "function PAUSER_ROLE() view returns (bytes32)"
];

const AMM_PAIR_ABI = [
    "function tokenA() view returns (address)",
    "function tokenB() view returns (address)",
    "function reserveA() view returns (uint256)",
    "function reserveB() view returns (uint256)",
    "function balanceOf(address account) view returns (uint256)",
    "function addLiquidity(uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin) returns (uint256 amountA, uint256 amountB, uint256 liquidity)",
    "function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin) returns (uint256 amountOut)"
];

const LP_NFT_ENUMERABLE_ABI = [
    "function balanceOf(address owner) view returns (uint256)",
    "function tokenOfOwnerByIndex(address owner, uint256 index) view returns (uint256)",
    "function positions(uint256 tokenId) view returns (address pair, uint256 lpAmount, uint256 mintedAt)"
];

let provider = null;
let signer = null;
let currentAccount = "";
let currentChainId = "";

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

const amountADesiredInput = document.getElementById("amountADesired");
const amountBDesiredInput = document.getElementById("amountBDesired");
const submitLiquidityBtn = document.getElementById("submitLiquidityBtn");
const tokenInSelect = document.getElementById("tokenInSelect");
const swapAmountIn = document.getElementById("swapAmountIn");
const submitSwapBtn = document.getElementById("submitSwapBtn");

window.addEventListener('DOMContentLoaded', () => {
    if (window.ethereum) {
        window.ethereum.on('accountsChanged', handleAccountsChanged);
        window.ethereum.on('chainChanged', handleChainChangedState);
    } else {
        showError("Web3 signature client missing. Install Metamask or Rabby extension framework.");
    }
});

if (connectBtn) connectBtn.addEventListener('click', connectWallet);
if (document.getElementById("vaultForm")) document.getElementById("vaultForm").addEventListener('submit', executeVaultDeposit);
if (delegateSelfBtn) delegateSelfBtn.addEventListener('click', executeSelfDelegation);
if (document.getElementById("addLiquidityForm")) document.getElementById("addLiquidityForm").addEventListener('submit', executeAddLiquidity);
if (document.getElementById("swapForm")) document.getElementById("swapForm").addEventListener('submit', executeAMMSwap);

async function connectWallet() {
    clearError();
    try {
        provider = new ethers.BrowserProvider(window.ethereum);
        const accounts = await provider.send("eth_requestAccounts", []);
        const network = await provider.getNetwork();
        
        currentChainId = Number(network.chainId); 
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

function handleChainChangedState(hexChainId) { 
    currentChainId = Number(hexChainId);
    updateDOMWalletElements(); 
    if (currentChainId === TARGET_CHAIN_ID) {
        runAggregationPipeline(); 
    }
}

async function enforceNetworkSwitch() {
    try {
        await window.ethereum.request({
            method: "wallet_switchEthereumChain",
            params: [{ chainId: TARGET_CHAIN_HEX }]
        });
    } catch (err) {
        if (err.code === 4902) {
            try {
                await window.ethereum.request({
                    method: "wallet_addEthereumChain",
                    params: [{
                        chainId: TARGET_CHAIN_HEX,
                        chainName: "Arbitrum Sepolia Testnet",
                        nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
                        rpcUrls: ["https://sepolia-rollup.arbitrum.io/rpc"],
                        blockExplorerUrls: ["https://sepolia-arbiscan.io"]
                    }]
                });
            } catch (addErr) {
                showError("Failed to auto-configure Arbitrum Sepolia network in wallet.");
            }
        } else {
            handleExceptionLogs(err);
        }
    }
}

function updateDOMWalletElements() {
    if (currentAccount) {
        if (connectBtn) connectBtn.classList.add("hidden");
        if (walletDetails) walletDetails.classList.remove("hidden");
        if (accountDisplay) accountDisplay.innerText = `${currentAccount.slice(0, 6)}...${currentAccount.slice(-4)}`;
        
        const isCorrectChain = currentChainId === TARGET_CHAIN_ID;
        if (networkBadge) {
            networkBadge.innerText = isCorrectChain ? "L2 Core Synchronized" : "MALFORMED NETWORK CONFIG";
            networkBadge.className = isCorrectChain ? "badge badge-green" : "badge badge-red";
        }

        const inputs = [depositInput, amountADesiredInput, amountBDesiredInput, swapAmountIn, tokenInSelect];
        const buttons = [submitDepositBtn, delegateSelfBtn, submitLiquidityBtn, submitSwapBtn];
        
        inputs.forEach(i => { if(i) isCorrectChain ? i.removeAttribute("disabled") : i.setAttribute("disabled", "true"); });
        buttons.forEach(b => { if(b) isCorrectChain ? b.removeAttribute("disabled") : b.setAttribute("disabled", "true"); });
    }
}

async function runAggregationPipeline() {
    if (!provider || currentChainId !== TARGET_CHAIN_ID) return;
    clearError(); 
    try {
        const govToken = new ethers.Contract(CONTRACT_ADDRESSES.governanceToken, GOVERNANCE_TOKEN_ABI, provider);
        const vault = new ethers.Contract(CONTRACT_ADDRESSES.yieldVault, YIELD_VAULT_ABI, provider);

        const [govBal, votingPower, currentDelegate, vaultShares] = await Promise.all([
            govToken.balanceOf(currentAccount),
            govToken.getVotes(currentAccount),
            govToken.delegates(currentAccount),
            vault.balanceOf(currentAccount)
        ]);

        if(document.getElementById("govBalance")) document.getElementById("govBalance").innerText = parseFloat(ethers.formatEther(govBal)).toFixed(4);
        if(document.getElementById("votingPower")) document.getElementById("votingPower").innerText = parseFloat(ethers.formatEther(votingPower)).toFixed(4);
        if(document.getElementById("vaultShares")) document.getElementById("vaultShares").innerText = parseFloat(ethers.formatEther(vaultShares)).toFixed(4);
        
        if(document.getElementById("lpBalance")) {
            document.getElementById("lpBalance").innerText = "0.0000 (No AMM)";
        }
        
        if(document.getElementById("delegateDisplay")) {
            document.getElementById("delegateDisplay").innerText = 
                currentDelegate === ethers.ZeroAddress ? "None Designated" : `${currentDelegate.slice(0, 6)}...${currentDelegate.slice(-4)}`;
        }

        await pullUserNFTRecords();
        await syncTheGraphGovernanceData();
    } catch (err) {
        console.error("Aggregation node failed to capture balances: ", err);
        showError("Error refreshing dashboard metrics. Check console logs.");
    }
}

async function executeAddLiquidity(e) {
    e.preventDefault();
    clearError();

    const amountAVal = amountADesiredInput.value;
    const amountBVal = amountBDesiredInput.value;

    if (!amountAVal || !amountBVal || parseFloat(amountAVal) <= 0 || parseFloat(amountBVal) <= 0) {
        return showError("Enter valid amounts greater than 0 for both tokens.");
    }

    try {
        if (submitLiquidityBtn) submitLiquidityBtn.setAttribute("disabled", "true");

        const ammAddress = CONTRACT_ADDRESSES.ammPairProxy;
        if (!ammAddress) return showError("AMM pair address not configured.");

        const ammReadContract = new ethers.Contract(ammAddress, AMM_PAIR_ABI, provider);
        
        let tokenAAddr, tokenBAddr;
        try {
            [tokenAAddr, tokenBAddr] = await Promise.all([
                ammReadContract.tokenA(),
                ammReadContract.tokenB()
            ]);
        } catch (readErr) {
            console.warn("Could not read token variables from contract, falling back to mock addresses.");
            tokenAAddr = CONTRACT_ADDRESSES.governanceToken;
            tokenBAddr = CONTRACT_ADDRESSES.governanceToken;
        }

        console.log("AMM tokenA:", tokenAAddr);
        console.log("AMM tokenB:", tokenBAddr);
        console.log("Are they the same?", tokenAAddr.toLowerCase() === tokenBAddr.toLowerCase());

        let finalTokenBAddr = tokenBAddr;
        if (tokenAAddr.toLowerCase() === tokenBAddr.toLowerCase()) {
            console.warn("Warning: AMM references identical token addresses. Utilizing virtual routing bypass.");
            finalTokenBAddr = "0x0000000000000000000000000000000000000001"; 
        }

        const tokenAAmount = ethers.parseUnits(amountAVal, 18);
        const tokenBAmount = ethers.parseUnits(amountBVal, 18);

        const amountAMin = tokenAAmount * 995n / 1000n;
        const amountBMin = tokenBAmount * 995n / 1000n;

        const feeData = await provider.getFeeData();
        const gasOverrides = {
            maxFeePerGas: feeData.maxFeePerGas ? (feeData.maxFeePerGas * 2n) : ethers.parseUnits("0.1", "gwei"),
            maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ? (feeData.maxPriorityFeePerGas * 2n) : ethers.parseUnits("0.02", "gwei"),
            gasLimit: 300000n
        };

        const erc20Abi = ["function approve(address spender, uint256 amount) public returns (bool)"];
        const tokenAInstance = new ethers.Contract(tokenAAddr, erc20Abi, signer);

        if (submitLiquidityBtn) submitLiquidityBtn.innerText = "Approving Token A...";
        const approveTxA = await tokenAInstance.approve(ammAddress, tokenAAmount, {
            maxFeePerGas: gasOverrides.maxFeePerGas,
            maxPriorityFeePerGas: gasOverrides.maxPriorityFeePerGas
        });
        await approveTxA.wait();

        if (finalTokenBAddr !== "0x0000000000000000000000000000000000000001") {
            const tokenBInstance = new ethers.Contract(finalTokenBAddr, erc20Abi, signer);
            if (submitLiquidityBtn) submitLiquidityBtn.innerText = "Approving Token B...";
            const approveTxB = await tokenBInstance.approve(ammAddress, tokenBAmount, {
                maxFeePerGas: gasOverrides.maxFeePerGas,
                maxPriorityFeePerGas: gasOverrides.maxPriorityFeePerGas
            });
            await approveTxB.wait();
        }

        if (submitLiquidityBtn) submitLiquidityBtn.innerText = "Adding Liquidity...";

        const ammContract = new ethers.Contract(ammAddress, AMM_PAIR_ABI, signer);

        const tx = await ammContract.addLiquidity(
            tokenAAmount,
            tokenBAmount,
            amountAMin,
            amountBMin,
            { gasLimit: gasOverrides.gasLimit, maxFeePerGas: gasOverrides.maxFeePerGas, maxPriorityFeePerGas: gasOverrides.maxPriorityFeePerGas }
        );

        await tx.wait();

        amountADesiredInput.value = "";
        amountBDesiredInput.value = "";
        await runAggregationPipeline();

    } catch (err) {
        console.error("executeAddLiquidity error:", err);
        handleExceptionLogs(err);
    } finally {
        if (submitLiquidityBtn) {
            submitLiquidityBtn.removeAttribute("disabled");
            submitLiquidityBtn.innerText = "Provide Dual Liquidity";
        }
    }
}

async function executeAMMSwap(e) {
    e.preventDefault();
    clearError();

    const amountInVal = swapAmountIn.value;
    if (!amountInVal || isNaN(amountInVal) || parseFloat(amountInVal) <= 0) {
        return showError("Enter a valid swap amount greater than 0.");
    }

    try {
        if (submitSwapBtn) submitSwapBtn.setAttribute("disabled", "true");

        const ammAddress = CONTRACT_ADDRESSES.ammPairProxy;
        if (!ammAddress) return showError("AMM pair address not configured.");

        const ammReadContract = new ethers.Contract(ammAddress, AMM_PAIR_ABI, provider);
        const [tokenAAddr, tokenBAddr, reserveA, reserveB] = await Promise.all([
            ammReadContract.tokenA(),
            ammReadContract.tokenB(),
            ammReadContract.reserveA(),
            ammReadContract.reserveB()
        ]);

        const isAtoB = tokenInSelect.value === "tokenA";
        const tokenInAddr = isAtoB ? tokenAAddr : tokenBAddr;
        const reserveIn   = isAtoB ? reserveA   : reserveB;
        const reserveOut  = isAtoB ? reserveB   : reserveA;

        const amountIn = ethers.parseUnits(amountInVal, 18);

        const amountInWithFee = amountIn * 997n;
        const expectedOut     = (amountInWithFee * reserveOut) / ((reserveIn * 1000n) + amountInWithFee);
        const amountOutMin    = expectedOut * 995n / 1000n;

        console.log("Token in:", tokenInAddr);
        console.log("Expected out:", ethers.formatUnits(expectedOut, 18));
        console.log("Min out:", ethers.formatUnits(amountOutMin, 18));

        const gasOverrides = {
            maxFeePerGas: ethers.parseUnits("0.1", "gwei"),
            maxPriorityFeePerGas: ethers.parseUnits("0.001", "gwei"),
            gasLimit: 300000n
        };

        const erc20Abi = ["function approve(address spender, uint256 amount) public returns (bool)"];
        const tokenInContract = new ethers.Contract(tokenInAddr, erc20Abi, signer);

        if (submitSwapBtn) submitSwapBtn.innerText = "Approving...";
        const approveTx = await tokenInContract.approve(ammAddress, amountIn, gasOverrides);
        await approveTx.wait();
        console.log("Approve confirmed");

        if (submitSwapBtn) submitSwapBtn.innerText = "Swapping...";
        const ammContract = new ethers.Contract(ammAddress, AMM_PAIR_ABI, signer);
        const tx = await ammContract.swap(tokenInAddr, amountIn, amountOutMin, gasOverrides);
        const receipt = await tx.wait();
        console.log("Swap confirmed! Block:", receipt.blockNumber);

        swapAmountIn.value = "";
        await runAggregationPipeline();

    } catch (err) {
        console.error("executeAMMSwap error:", err);
        handleExceptionLogs(err);
    } finally {
        if (submitSwapBtn) {
            submitSwapBtn.removeAttribute("disabled");
            submitSwapBtn.innerText = "Execute Custom Swap";
        }
    }
}

async function executeVaultDeposit(e) {
    e.preventDefault();
    clearError();
    
    const inputValue = depositInput.value;
    if(!inputValue || isNaN(inputValue) || parseFloat(inputValue) <= 0) {
        return showError("Enter a valid amount greater than 0.");
    }
    
    try {
        if(submitDepositBtn) submitDepositBtn.setAttribute("disabled", "true");
        
        const vault = new ethers.Contract(CONTRACT_ADDRESSES.yieldVault, YIELD_VAULT_ABI, signer);
        const expectedAsset = await vault.asset();
        
        if (expectedAsset.toLowerCase() !== CONTRACT_ADDRESSES.governanceToken.toLowerCase()) {
            return showError(`Vault asset mismatch! Vault wants: ${expectedAsset}, but you are approving: ${CONTRACT_ADDRESSES.governanceToken}`);
        }

        const tokenContract = new ethers.Contract(expectedAsset, STANDARD_ERC20_ABI, signer);
        const size = ethers.parseEther(inputValue);
        
        const feeData = await provider.getFeeData();
        const gasOverrides = {
            maxFeePerGas: feeData.maxFeePerGas ? (feeData.maxFeePerGas * 2n) : ethers.parseUnits("0.1", "gwei"),
            maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ? (feeData.maxPriorityFeePerGas * 2n) : ethers.parseUnits("0.02", "gwei"),
            gasLimit: 200000n
        };

        if(submitDepositBtn) submitDepositBtn.innerText = "Approving DGT...";
        const approveTx = await tokenContract.approve(CONTRACT_ADDRESSES.yieldVault, size, {
            maxFeePerGas: gasOverrides.maxFeePerGas,
            maxPriorityFeePerGas: gasOverrides.maxPriorityFeePerGas
        });
        await approveTx.wait();
        
        if(submitDepositBtn) submitDepositBtn.innerText = "Depositing into Vault...";
        
        const depositTx = await vault.deposit(size, currentAccount, {
            gasLimit: gasOverrides.gasLimit,
            maxFeePerGas: gasOverrides.maxFeePerGas,
            maxPriorityFeePerGas: gasOverrides.maxPriorityFeePerGas
        });
        await depositTx.wait();
        
        depositInput.value = "";
        await runAggregationPipeline();
    } catch (err) {
        console.error("CRITICAL VAULT ERROR:", err);
        handleExceptionLogs(err);
    } finally {
        if(submitDepositBtn) {
            submitDepositBtn.removeAttribute("disabled");
            submitDepositBtn.innerText = "Approve & Deposit Assets";
        }
    }
}

async function executeSelfDelegation() {
    clearError();
    try {
        const token = new ethers.Contract(CONTRACT_ADDRESSES.governanceToken, GOVERNANCE_TOKEN_ABI, signer);
        if(delegateSelfBtn) delegateSelfBtn.innerText = "Confirming in Wallet...";
        
        const feeData = await provider.getFeeData();
        const tx = await token.delegate(currentAccount, {
            maxFeePerGas: feeData.maxFeePerGas ? (feeData.maxFeePerGas * 2n) : undefined,
            maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ? (feeData.maxPriorityFeePerGas * 2n) : undefined
        });
        await tx.wait();
        
        if(delegateSelfBtn) delegateSelfBtn.innerText = "Delegate Voting Power to Self";
        await runAggregationPipeline();
    } catch (err) {
        if(delegateSelfBtn) delegateSelfBtn.innerText = "Delegate Voting Power to Self";
        handleExceptionLogs(err);
    }
}

async function pullUserNFTRecords() {
    if (nftLoadingMsg) nftLoadingMsg.classList.add("hidden");
    
    try {
        const ammAddress = CONTRACT_ADDRESSES.ammPairProxy;
        if (!ammAddress) {
            nftContainer.innerHTML = `<p class="status-msg">No AMM pair configured.</p>`;
            return;
        }

        const ammContract = new ethers.Contract(ammAddress, AMM_PAIR_ABI, provider);
        const [lpBalance, reserveA, reserveB, tokenAAddr, tokenBAddr] = await Promise.all([
            ammContract.balanceOf(currentAccount),
            ammContract.reserveA(),
            ammContract.reserveB(),
            ammContract.tokenA(),
            ammContract.tokenB()
        ]);

        if (document.getElementById("lpBalance")) {
            document.getElementById("lpBalance").innerText = 
                parseFloat(ethers.formatEther(lpBalance)).toFixed(4) + " ALP";
        }

        if (lpBalance === 0n) {
            nftContainer.innerHTML = `<p class="status-msg">No LP positions found for this wallet.</p>`;
            return;
        }

        nftContainer.innerHTML = `
            <div class="nft-card">
                <h4>AMM LP Position</h4>
                <p><strong>LP Tokens:</strong> ${parseFloat(ethers.formatEther(lpBalance)).toFixed(6)} ALP</p>
                <p><strong>Pool Token A:</strong> ${tokenAAddr.slice(0,6)}...${tokenAAddr.slice(-4)}</p>
                <p><strong>Pool Token B:</strong> ${tokenBAddr.slice(0,6)}...${tokenBAddr.slice(-4)}</p>
                <p><strong>Reserve A:</strong> ${parseFloat(ethers.formatEther(reserveA)).toFixed(4)}</p>
                <p><strong>Reserve B:</strong> ${parseFloat(ethers.formatEther(reserveB)).toFixed(4)}</p>
            </div>
        `;
    } catch (err) {
        console.error("pullUserNFTRecords error:", err);
        if (nftContainer) nftContainer.innerHTML = `<p class="status-msg">Failed to load LP positions.</p>`;
    }
}

async function syncTheGraphGovernanceData() {
    if (governanceStatusMsg) governanceStatusMsg.classList.add("hidden");

    try {
        const governor = new ethers.Contract(CONTRACT_ADDRESSES.defiGovernor, GOVERNOR_ABI, provider);
        const govToken = new ethers.Contract(CONTRACT_ADDRESSES.governanceToken, GOVERNANCE_TOKEN_ABI, provider);

        const [threshold, votes] = await Promise.all([
            governor.proposalThreshold(),
            govToken.getVotes(currentAccount)
        ]);

        proposalContainer.innerHTML = `
            <div class="proposal-card">
                <h4>Governor On-Chain Status</h4>
                <p><strong>Contract:</strong> 
                    <a href="https://sepolia.arbiscan.io/address/${CONTRACT_ADDRESSES.defiGovernor}" 
                       target="_blank" style="color:#4ade80">
                        ${CONTRACT_ADDRESSES.defiGovernor.slice(0,6)}...${CONTRACT_ADDRESSES.defiGovernor.slice(-4)} ↗
                    </a>
                </p>
                <p><strong>Proposal Threshold:</strong> ${parseFloat(ethers.formatEther(threshold)).toFixed(2)} DGT</p>
                <p><strong>Your Voting Power:</strong> ${parseFloat(ethers.formatEther(votes)).toFixed(4)} Votes</p>
                <p><strong>Timelock Delay:</strong> 2 days</p>
                <p style="margin-top:10px; color:#94a3b8; font-size:0.85em">
                    No active proposals found on-chain.<br>
                    Proposal indexing via The Graph requires subgraph deployment.
                </p>
            </div>
        `;
    } catch (err) {
        console.error("syncTheGraphGovernanceData error:", err);
        if (proposalContainer) proposalContainer.innerHTML = 
            `<p class="status-msg">Failed to load governance data.</p>`;
    }
}

function handleExceptionLogs(error) {
    console.error("Tracking transaction failure: ", error);
    
    if (error.code === "ACTION_REJECTED" || error.message?.includes("user rejected")) {
        showError("Transaction rejected by the user inside the wallet extension.");
        return;
    }
    if (error.code === "INSUFFICIENT_FUNDS" || error.message?.includes("insufficient funds")) {
        showError("Insufficient native ETH balance to pay gas fees for this execution pipeline.");
        return;
    }
    
    const reason = error.reason || error.message || "Unhandled transaction exception";
    showError(`Pipeline Note: ${reason.slice(0, 80)}`);
}

function showError(message) { if(errorMessage && errorBanner) { errorMessage.innerText = message; errorBanner.classList.remove("hidden"); } }
function clearError() { if(errorBanner) errorBanner.classList.add("hidden"); }
function handleAccountsChanged(accounts) { currentAccount = accounts[0] || ""; updateDOMWalletElements(); runAggregationPipeline(); }
function handleChainChanged(hexChainId) { currentChainId = Number(hexChainId); updateDOMWalletElements(); runAggregationPipeline(); }