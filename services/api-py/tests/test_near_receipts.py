"""Receipts anchored on NEAR, tested without a chain or a key.

The digest is the contract between the backend and the merchant: whoever holds the receipt body must
get the same 32 bytes the contract stored. So most of these tests are about the body, and one of them
is about the only thing a merchant actually asks: is this body anchored?
"""

from __future__ import annotations

import base64
import json

import httpx
import pytest

from app.near_receipts import (
    NearError,
    NearReceipts,
    anchor_command,
    anchor_command_str,
    anchor_args,
    anchorer,
    hash_utr,
    receipt_body,
    receipt_digest,
    run_anchor,
)

CONTRACT = "receipts.globalpay.testnet"


def body(**over: object) -> dict:
    base = dict(
        payment_id="0x" + "ab" * 32,
        offramp_id="0x" + "ab" * 32,
        chain="arc",
        amount=12_500,
        inr_paise=1_000,
        utr="424242424242",
        paid_at=1_700_000_000,
    )
    base.update(over)
    return receipt_body(**base)  # type: ignore[arg-type]


# ---- the receipt body ---------------------------------------------------------------------------


def test_the_digest_is_a_32_byte_hash():
    digest = receipt_digest(body())
    assert len(digest) == 64 and digest == digest.lower() and int(digest, 16) >= 0


def test_the_same_receipt_always_hashes_the_same_way():
    assert receipt_digest(body()) == receipt_digest(body())


def test_key_order_does_not_change_the_digest():
    b = body()
    shuffled = {k: b[k] for k in reversed(list(b))}
    assert receipt_digest(shuffled) == receipt_digest(b)


def test_any_difference_changes_the_digest():
    base = receipt_digest(body())
    assert receipt_digest(body(amount=12_501)) != base
    assert receipt_digest(body(paid_at=1_700_000_001)) != base
    assert receipt_digest(body(utr="424242424243")) != base


def test_the_body_never_carries_the_bank_reference():
    b = body(utr="424242424242")
    assert "424242424242" not in json.dumps(b)
    assert b["utr_hash"] == hash_utr("424242424242")


def test_the_body_never_carries_the_upi_id_or_payee():
    # Those live in the quote, which is private; a receipt must not leak them to a public chain.
    text = json.dumps(body())
    assert "chaipoint" not in text and "okaxis" not in text


def test_a_missing_utr_anchors_as_an_empty_hash_not_null():
    assert body(utr=None)["utr_hash"] == ""
    assert body(utr="")["utr_hash"] == ""


def test_anchor_args_are_what_the_contract_expects():
    args = anchor_args(body())
    assert args["digest"] == receipt_digest(body())
    assert set(args) == {"payment_id", "digest", "chain", "amount", "utr_hash", "paid_at"}
    # u64 must arrive as a JSON number: as a string the contract's deserialisation aborts the call.
    assert args["paid_at"] == 1_700_000_000
    assert isinstance(args["paid_at"], int)


def test_the_anchor_command_shows_what_will_be_signed():
    cmd = anchor_command(contract=CONTRACT, account="relayer.testnet", body=body())
    assert cmd[:6] == ["near", "contract", "call-function", "as-transaction", CONTRACT, "anchor"]
    assert json.loads(cmd[cmd.index("json-args") + 1])["digest"] == receipt_digest(body())
    # near-cli-rs names the signer with sign-as; the legacy npm CLI used --accountId.
    assert cmd[cmd.index("sign-as") + 1] == "relayer.testnet"
    assert cmd[-4:] == ["network-config", "testnet", "sign-with-keychain", "send"]
    assert "424242424242" not in anchor_command_str(contract=CONTRACT, account="a.testnet", body=body())


def test_the_command_is_the_cli_we_install():
    """A mismatch here fails silently in production: run_anchor only warns and the receipt is unanchored."""
    cmd = anchor_command(contract=CONTRACT, account="a.testnet", body=body())
    assert "--accountId" not in cmd and "--initFunction" not in cmd
    assert cmd[1:4] == ["contract", "call-function", "as-transaction"]


# ---- reading the chain --------------------------------------------------------------------------


def _rpc(value: object) -> httpx.MockTransport:
    payload = {"jsonrpc": "2.0", "id": "globalpay", "result": {
        "result": list(json.dumps(value).encode()), "logs": [], "block_height": 1, "block_hash": "x"}}

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=payload)

    return httpx.MockTransport(handler)


def test_is_anchored_reads_the_view_result():
    with NearReceipts(CONTRACT, transport=_rpc(True)) as near:
        assert near.is_anchored(receipt_digest(body())) is True
    with NearReceipts(CONTRACT, transport=_rpc(False)) as near:
        assert near.is_anchored(receipt_digest(body())) is False


def test_a_receipt_reads_back_as_a_dict():
    stored = {"payment_id": body()["payment_id"], "digest": receipt_digest(body()), "chain": "arc",
              "amount": "12500", "utr_hash": hash_utr("424242424242"), "paid_at": 1_700_000_000,
              "anchor": "relayer.testnet"}
    with NearReceipts(CONTRACT, transport=_rpc(stored)) as near:
        assert near.receipt(body()["payment_id"])["anchor"] == "relayer.testnet"


def test_an_unknown_receipt_is_none():
    with NearReceipts(CONTRACT, transport=_rpc(None)) as near:
        assert near.receipt("nope") is None


def test_the_view_call_asks_the_right_contract_and_method():
    seen: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent = json.loads(request.content)
        seen.append(sent["params"])
        value = json.dumps(True).encode()
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": "globalpay", "result": {"result": list(value)}})

    with NearReceipts(CONTRACT, transport=httpx.MockTransport(handler)) as near:
        near.is_anchored("11" * 32)

    params = seen[0]
    assert params["account_id"] == CONTRACT and params["method_name"] == "is_anchored"
    assert params["finality"] == "final"
    assert json.loads(base64.b64decode(params["args_base64"])) == {"digest": "11" * 32}


def test_an_rpc_error_is_reported_not_swallowed():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": "x",
                                         "error": {"name": "HANDLER_ERROR", "message": "contract does not exist"}})

    with NearReceipts(CONTRACT, transport=httpx.MockTransport(handler)) as near:
        with pytest.raises(NearError, match="contract does not exist"):
            near.is_anchored("11" * 32)


def test_a_transport_failure_is_reported():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route")

    with NearReceipts(CONTRACT, transport=httpx.MockTransport(handler)) as near:
        with pytest.raises(NearError, match="unavailable"):
            near.receipt("x")


# ---- anchoring from the backend -----------------------------------------------------------------


def test_anchoring_is_off_until_it_is_configured():
    # With no contract or no account, the settler behaves exactly as it did before.
    assert anchorer(contract="", account="relayer.testnet") is None
    assert anchorer(contract=CONTRACT, account="") is None


def test_a_missing_near_cli_is_a_warning_not_a_crash():
    ok, out = run_anchor(["definitely-not-the-near-cli", "call"], timeout=5)
    assert ok is False and "not installed" in out


def test_the_hook_reports_a_failure_without_raising(caplog):
    hook = anchorer(contract=CONTRACT, account="relayer.testnet", near_cli="definitely-not-the-near-cli")
    hook(body())  # must not raise
    assert "receipt anchor failed" in caplog.text


# ---- the settler calls it once the payment completes --------------------------------------------


async def test_a_settlement_anchors_the_receipt(store, chain, user, keys):
    from app.settler import Settler
    from .test_workers import ID, CountingBox, PARSED, locked_row, make_runner

    p = locked_row(store, chain, user.address)
    anchored: list[dict] = []
    settler = Settler({"arc": chain}, store, keys.settler, on_settled=anchored.append)
    await make_runner(store, settler, CountingBox()).dispatch(p, PARSED)
    chain.now = p["locked_at"] + 15

    assert (await settler.tick())[ID] == "completed"
    assert len(anchored) == 1
    receipt = anchored[0]
    assert receipt["payment_id"] == ID and receipt["chain"] == "arc"
    assert receipt["amount"] == str(store.get_payment(ID)["amount"])
    # The escrow's payout reference is hashed, never published.
    assert receipt["utr_hash"] == hash_utr(store.get_payment(ID)["payout_ref"])
    assert store.get_payment(ID)["payout_ref"] not in json.dumps(receipt)


async def test_a_failing_anchor_does_not_undo_a_settlement(store, chain, user, keys):
    from app.settler import Settler
    from .test_workers import ID, CountingBox, PARSED, locked_row, make_runner

    def boom(_: dict) -> None:
        raise RuntimeError("NEAR RPC is down")

    p = locked_row(store, chain, user.address)
    settler = Settler({"arc": chain}, store, keys.settler, on_settled=boom)
    await make_runner(store, settler, CountingBox()).dispatch(p, PARSED)
    chain.now = p["locked_at"] + 15

    # The merchant was paid; a bookkeeping failure must not reverse that.
    assert (await settler.tick())[ID] == "completed"
    assert store.get_payment(ID)["status"] == "COMPLETED"
