/**
 * A wallet for the local Hardhat chain, so the app can be used without an extension installed.
 *
 * It is a plain EIP-1193 provider — the same interface a browser wallet exposes — that signs typed
 * data with a well-known test key. It exists only when the app is served by `vite dev` **and** the
 * backend reports chain 31337, so a built app and a real network (Arc, Whitechain) can never select it.
 *
 * The key below is Hardhat's account #0. It is published in Hardhat's own docs and funded only on a
 * local node; it controls nothing anywhere else.
 */
import { createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { AppConfig } from "./api";
import type { Eip1193Provider, WalletOption } from "./wallet";

const LOCAL_DEV_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const LOCAL_CHAIN_ID = 31337;

type TypedDataRequest = Parameters<ReturnType<typeof createWalletClient>["signTypedData"]>[0];

export function localDevWallet(config: AppConfig): WalletOption | null {
  if (!import.meta.env.DEV) return null;
  const chain = config.chains.local;
  if (!chain || chain.chainId !== LOCAL_CHAIN_ID) return null;

  const account = privateKeyToAccount(LOCAL_DEV_KEY);
  const client = createWalletClient({
    account,
    chain: {
      id: chain.chainId,
      name: chain.name,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [chain.rpc] } },
    },
    transport: http(chain.rpc),
  });
  const chainId = `0x${chain.chainId.toString(16)}`;

  const provider: Eip1193Provider = {
    async request({ method, params }) {
      switch (method) {
        case "eth_requestAccounts":
        case "eth_accounts":
          return [account.address];
        case "eth_chainId":
          return chainId;
        case "wallet_switchEthereumChain": {
          const wanted = (params?.[0] as { chainId?: string } | undefined)?.chainId;
          if (wanted && wanted.toLowerCase() !== chainId) {
            throw Object.assign(new Error("The local test wallet only signs on the local chain."), { code: 4902 });
          }
          return null;
        }
        case "wallet_addEthereumChain":
          return null;
        case "eth_signTypedData_v4": {
          const [, json] = params as [string, string];
          const typed = JSON.parse(json) as {
            domain?: unknown;
            types?: Record<string, unknown>;
            primaryType?: string;
            message?: unknown;
          };
          // Wallets reject EIP712Domain in `types`; viem derives it from `domain`.
          const { EIP712Domain: _ignored, ...types } = typed.types ?? {};
          return client.signTypedData({
            account,
            domain: typed.domain,
            types,
            primaryType: typed.primaryType,
            message: typed.message,
          } as TypedDataRequest);
        }
        default:
          throw Object.assign(new Error(`The local test wallet cannot ${method}.`), { code: 4200 });
      }
    },
  };

  return {
    id: "local-dev",
    name: "Local test wallet (Hardhat)",
    provider,
  };
}
