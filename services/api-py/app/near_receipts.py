"""Receipts anchored on NEAR.

A settled rupee payment leaves two parties who could disagree later: the buyer and the merchant. The
vault's `COMPLETED` state proves tokens moved, not that the merchant was paid, and the bank reference
that does prove it is private. So each settled payment gets a receipt body, the body is hashed, and
only the digest is anchored on NEAR (`near-receipts/`). Anyone holding the body can recompute the
digest and ask the contract whether it was anchored; nobody learns the UPI ID, the payee name or the
UTR from the chain.

Two halves live here so they are tested against each other:

* the canonical body and its digest — the thing a merchant or an auditor recomputes;
* a read-only RPC client, so `is_anchored` needs no key at all.

Anchoring writes to the chain, so it is a signed call made by a relayer account through `near-cli`
(see `anchor_command`). This module never moves money and never needs the payer's keys.
"""

from __future__ import annotations

import hashlib
import json
import shlex
from typing import Any

import httpx

NEAR_RPC = "https://rpc.testnet.near.org"
NEAR_EXPLORER = "https://testnet.nearblocks.io"
DEFAULT_GAS_TGAS = 30  # anchoring one receipt is a few writes; 30 TGas is generous and bounded


class NearError(RuntimeError):
    """The chain could not be read (or a view call came back malformed)."""


def hash_utr(utr: str | None) -> str:
    """The bank reference, hashed. An empty or missing UTR anchors as an empty string, never as null."""
    return hashlib.sha256(utr.encode("utf-8")).hexdigest() if utr else ""


def receipt_body(
    *,
    payment_id: str,
    offramp_id: str,
    chain: str,
    amount: int,
    inr_paise: int,
    utr: str | None,
    paid_at: int,
    vault: str | None = None,
) -> dict[str, Any]:
    """The receipt as the merchant would keep it: what was paid, on which vault, in which currency.

    `utr` is hashed here, so a caller cannot accidentally anchor the reference itself. Everything in
    this dict is either public already (amounts, ids, chain) or a hash.
    """
    body: dict[str, Any] = {
        "payment_id": str(payment_id),
        "offramp_id": str(offramp_id),
        "chain": str(chain),
        "amount": str(int(amount)),
        "inr_paise": str(int(inr_paise)),
        "utr_hash": hash_utr(utr),
        "paid_at": int(paid_at),
    }
    if vault:
        body["vault"] = str(vault)
    return body


def canonical(body: dict[str, Any]) -> bytes:
    """Sorted keys, no whitespace. The digest depends on the bytes, so the encoding must be fixed."""
    return json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")


def receipt_digest(body: dict[str, Any]) -> str:
    """Lowercase hex SHA-256 of the canonical body, which is the contract's `digest` argument."""
    return hashlib.sha256(canonical(body)).hexdigest()


def anchor_args(body: dict[str, Any]) -> dict[str, str]:
    """The contract's `anchor` arguments, flattened as NEAR JSON arguments."""
    return {
        "payment_id": body["payment_id"],
        "digest": receipt_digest(body),
        "chain": body["chain"],
        "amount": body["amount"],
        "utr_hash": body["utr_hash"],
        # A JSON number, not a string: the contract takes paid_at as u64 and aborts on a type miss.
        "paid_at": int(body["paid_at"]),
    }


def anchor_command(
    *, contract: str, account: str, body: dict[str, Any], near_cli: str = "near", network: str = "testnet"
) -> list[str]:
    """The argv that anchors one receipt, so the operator can see exactly what will be signed.

    This is near-cli-rs (`near contract call-function as-transaction …`), the CLI the docs install.
    The older npm `near call` accepts different flags, so a wrong CLI here means anchors silently
    never land: `test_the_command_is_the_cli_we_install` pins the shape.
    """
    return [
        near_cli,
        "contract",
        "call-function",
        "as-transaction",
        contract,
        "anchor",
        "json-args",
        json.dumps(anchor_args(body), sort_keys=True),
        "prepaid-gas",
        f"{DEFAULT_GAS_TGAS} TeraGas",
        "attached-deposit",
        "0 NEAR",
        "sign-as",
        account,
        "network-config",
        network,
        "sign-with-keychain",
        "send",
    ]


def anchor_command_str(**kwargs: Any) -> str:
    return " ".join(shlex.quote(part) for part in anchor_command(**kwargs))


class NearReceipts:
    """Read side of the anchor contract: no keys, no gas, safe to call from anywhere."""

    def __init__(
        self, contract: str, *, rpc_url: str = NEAR_RPC, transport: httpx.BaseTransport | None = None,
        timeout: float = 8.0,
    ) -> None:
        self.contract = contract
        self.rpc_url = rpc_url
        self._client = httpx.Client(transport=transport, timeout=timeout)

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "NearReceipts":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def _view(self, method: str, args: dict[str, Any]) -> Any:
        payload = {
            "jsonrpc": "2.0",
            "id": "globalpay",
            "method": "query",
            "params": {
                "request_type": "call_function",
                "finality": "final",
                "account_id": self.contract,
                "method_name": method,
                "args_base64": _b64(json.dumps(args).encode("utf-8")),
            },
        }
        try:
            res = self._client.post(self.rpc_url, json=payload)
            res.raise_for_status()
            data = res.json()
        except httpx.HTTPError as e:
            raise NearError(f"NEAR RPC unavailable: {e}") from e
        except ValueError as e:
            raise NearError(f"NEAR RPC returned non-JSON: {e}") from e

        if isinstance(data.get("error"), dict):
            message = data["error"].get("message") or data["error"].get("cause", {}).get("name")
            raise NearError(f"NEAR RPC error: {message or 'unknown'}")
        result = data.get("result")
        if not isinstance(result, dict) or "result" not in result:
            raise NearError("NEAR RPC response had no result")
        # A view call returns the method's JSON as raw bytes.
        raw = bytes(result["result"])
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError as e:
            raise NearError(f"view call returned unreadable JSON: {e}") from e

    def receipt(self, payment_id: str) -> dict[str, Any] | None:
        out = self._view("receipt", {"payment_id": str(payment_id)})
        return out if isinstance(out, dict) else None

    def is_anchored(self, digest: str) -> bool:
        return self._view("is_anchored", {"digest": str(digest)}) is True

    def receipt_count(self) -> int:
        out = self._view("receipt_count", {})
        return int(out) if isinstance(out, (int, float)) else 0

    def verifies(self, body: dict[str, Any]) -> bool:
        """The check that matters: this body's own digest is the one the chain holds."""
        return self.is_anchored(receipt_digest(body))


def _b64(data: bytes) -> str:
    import base64

    return base64.b64encode(data).decode("ascii")


def run_anchor(command: list[str], *, timeout: float = 90.0) -> tuple[bool, str]:
    """Run the anchor call. Returns (ok, output) and never raises: anchoring is a record, not a payment."""
    import subprocess

    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return False, "the near CLI is not installed on this host"
    except subprocess.TimeoutExpired:
        return False, "the anchor call timed out"
    except OSError as e:
        return False, str(e)
    out = (done.stdout or "").strip() or (done.stderr or "").strip()
    return done.returncode == 0, out[:400]


def anchorer(*, contract: str, account: str, near_cli: str = "near", network: str = "testnet"):
    """`on_settled` hook for the settler, or None when no anchor account is configured.

    Returning None keeps every existing deployment behaving exactly as before: a settlement is written
    whether or not there is a NEAR account to record it, and a failed anchor only warns.
    """
    if not contract or not account:
        return None

    def on_settled(body: dict[str, Any]) -> None:
        ok, out = run_anchor(anchor_command(contract=contract, account=account, body=body, near_cli=near_cli, network=network))
        if not ok:
            import logging

            logging.getLogger("globalpay.near").warning(
                "receipt anchor failed for %s (escrow unaffected): %s", body.get("payment_id"), out)

    return on_settled
