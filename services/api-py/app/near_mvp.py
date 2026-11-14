"""Read-only NEAR integration for the hackathon MVP.

The payer signs and submits transactions from the internal Flutter wallet. This module verifies final
NEAR execution and reconciles it with the minimal lock/refund vault; it holds no payer key and never
marks an INR merchant payout complete.
"""

from __future__ import annotations

import base64
import json
import os
import re
from dataclasses import dataclass
from typing import Any

import httpx


ACCOUNT_RE = re.compile(r"^(?:[0-9a-f]{64}|[a-z0-9]+(?:[._-][a-z0-9]+)*)$")
EVM_ADDRESS_RE = re.compile(r"^0x[0-9a-f]{40}$")
TX_RE = re.compile(r"^[1-9A-HJ-NP-Za-km-z]{40,50}$")


class NearMvpError(RuntimeError):
    pass


@dataclass(frozen=True)
class NearMvpConfig:
    network_id: str = "testnet"
    rpc_url: str = "https://rpc.testnet.near.org"
    explorer_url: str = "https://explorer.testnet.near.org"
    token_account_id: str = "usdc.fakes.testnet"
    vault_account_id: str = "vault.globalpay-receipts.testnet"
    treasury_account_id: str = "treasury.globalpay-receipts.testnet"
    token_symbol: str = "USDC.e"
    token_decimals: int = 6

    @classmethod
    def from_env(cls) -> "NearMvpConfig":
        network = os.environ.get("NEAR_NETWORK_ID") or "testnet"
        if network != "testnet":
            raise NearMvpError("NEAR MVP requires networkId testnet")
        return cls(
            network_id=network,
            rpc_url=os.environ.get("NEAR_RPC_URL") or cls.rpc_url,
            explorer_url=os.environ.get("NEAR_EXPLORER_URL") or cls.explorer_url,
            token_account_id=os.environ.get("NEAR_TOKEN_ACCOUNT") or cls.token_account_id,
            vault_account_id=os.environ.get("NEAR_VAULT_ACCOUNT") or cls.vault_account_id,
            treasury_account_id=os.environ.get("NEAR_TREASURY_ACCOUNT") or cls.treasury_account_id,
        )

    def tx_url(self, tx_hash: str) -> str:
        return f"{self.explorer_url.rstrip('/')}/transactions/{tx_hash}"


def valid_account_id(value: str) -> bool:
    return 2 <= len(value) <= 64 and ACCOUNT_RE.fullmatch(value) is not None and EVM_ADDRESS_RE.fullmatch(value) is None


def _b64_json(value: dict[str, Any]) -> str:
    return base64.b64encode(json.dumps(value, separators=(",", ":")).encode()).decode()


def _decode_result(result: dict[str, Any]) -> Any:
    raw = bytes(result.get("result") or [])
    return json.loads(raw.decode()) if raw else None


def _failure(status: Any) -> bool:
    return isinstance(status, dict) and "Failure" in status


class NearMvpClient:
    def __init__(self, config: NearMvpConfig | None = None, *, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.config = config or NearMvpConfig.from_env()
        self.http = httpx.AsyncClient(transport=transport, timeout=15.0)
        self._id = 0
        self._metadata_cache: dict[str, Any] | None = None

    async def close(self) -> None:
        await self.http.aclose()

    async def rpc(self, method: str, params: Any) -> Any:
        self._id += 1
        try:
            response = await self.http.post(
                self.config.rpc_url,
                json={"jsonrpc": "2.0", "id": f"globalpay-near-{self._id}", "method": method, "params": params},
            )
            response.raise_for_status()
            body = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise NearMvpError(f"NEAR RPC unavailable: {type(exc).__name__}") from exc
        if body.get("error"):
            error = body["error"]
            raise NearMvpError(str(error.get("data") or error.get("message") or "NEAR RPC error"))
        return body.get("result")

    async def status(self) -> dict[str, Any]:
        result = await self.rpc("status", [])
        if result.get("chain_id") != self.config.network_id:
            raise NearMvpError(f"RPC is {result.get('chain_id')}, expected {self.config.network_id}")
        return result

    async def account(self, account_id: str) -> dict[str, Any]:
        if not valid_account_id(account_id):
            raise NearMvpError("invalid NEAR account ID")
        return await self.rpc("query", {
            "request_type": "view_account", "finality": "final", "account_id": account_id,
        })

    async def view(self, account_id: str, method: str, args: dict[str, Any] | None = None) -> Any:
        result = await self.rpc("query", {
            "request_type": "call_function",
            "finality": "final",
            "account_id": account_id,
            "method_name": method,
            "args_base64": _b64_json(args or {}),
        })
        if result.get("error"):
            raise NearMvpError(str(result["error"]))
        return _decode_result(result)

    async def metadata(self) -> dict[str, Any]:
        if self._metadata_cache is not None:
            return dict(self._metadata_cache)
        value = await self.view(self.config.token_account_id, "ft_metadata")
        if not isinstance(value, dict) or value.get("spec") != "ft-1.0.0":
            raise NearMvpError("configured token did not return NEP-141 metadata")
        self._metadata_cache = dict(value)
        return dict(value)

    async def balance(self, account_id: str) -> int:
        return int(await self.view(self.config.token_account_id, "ft_balance_of", {"account_id": account_id}))

    async def storage_balance(self, account_id: str) -> dict[str, str] | None:
        return await self.view(self.config.token_account_id, "storage_balance_of", {"account_id": account_id})

    async def lock(self, id_: str) -> dict[str, Any] | None:
        value = await self.view(self.config.vault_account_id, "get_lock", {"id": id_})
        return value if isinstance(value, dict) else None

    async def total_locked(self) -> int:
        return int(await self.view(self.config.vault_account_id, "total_locked"))

    async def treasury(self) -> str:
        value = await self.view(self.config.vault_account_id, "treasury")
        if not isinstance(value, str) or not valid_account_id(value):
            raise NearMvpError("vault returned an invalid treasury account")
        return value

    async def payout_reference(self, id_: str) -> str | None:
        value = await self.view(self.config.vault_account_id, "payout_reference", {"id": id_})
        return value if isinstance(value, str) else None

    async def transaction(self, tx_hash: str, sender: str) -> dict[str, Any]:
        if not TX_RE.fullmatch(tx_hash) or not valid_account_id(sender):
            raise NearMvpError("invalid NEAR transaction hash or sender")
        return await self.rpc("tx", {"tx_hash": tx_hash, "sender_account_id": sender, "wait_until": "FINAL"})

    def verify_lock_transaction(
        self, outcome: dict[str, Any], *, sender: str, id_: str, amount: int
    ) -> dict[str, Any]:
        transaction = outcome.get("transaction") or {}
        if transaction.get("signer_id") != sender or transaction.get("receiver_id") != self.config.token_account_id:
            raise NearMvpError("transaction signer or token does not match the quote")
        actions = transaction.get("actions") or []
        if len(actions) != 1 or "FunctionCall" not in actions[0]:
            raise NearMvpError("transaction is not one NEP-141 function call")
        call = actions[0]["FunctionCall"]
        if call.get("method_name") != "ft_transfer_call" or str(call.get("deposit")) != "1":
            raise NearMvpError("transaction is not an ft_transfer_call with one yoctoNEAR")
        try:
            args = json.loads(base64.b64decode(call["args"]))
            msg = json.loads(args["msg"])
        except (KeyError, ValueError, TypeError) as exc:
            raise NearMvpError("transaction arguments are malformed") from exc
        if args.get("receiver_id") != self.config.vault_account_id:
            raise NearMvpError("transaction targets another vault")
        if int(args.get("amount") or 0) != amount or msg.get("id") != id_:
            raise NearMvpError("transaction amount or lock ID differs from the quote")
        receipts = outcome.get("receipts_outcome") or []
        if _failure(outcome.get("status")) or any(_failure((row.get("outcome") or {}).get("status")) for row in receipts):
            raise NearMvpError("NEAR transaction or one of its receipts failed")
        if outcome.get("final_execution_status") != "FINAL":
            raise NearMvpError("NEAR transaction is not final")
        return args
