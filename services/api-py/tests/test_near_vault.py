"""The backend's half of the NEAR vault, tested without a chain.

The reads are parsed from real RPC response shapes, and the writes are checked as *commands*: a test
that only asserted "we called send()" would not notice a wrong method name or a wrong argument, and a
wrong argument on `complete` is the difference between paying the merchant and paying nobody.
"""

from __future__ import annotations

import base64
import json

import httpx
import pytest

from app.chain import ChainError
from app.near_vault import (
    NearChainClient,
    NearVault,
    STATUS_BY_NAME,
    lock_message,
    tx_hash_of,
)

CONTRACT = "vault.globalpay.testnet"
TOKEN = "usdc.globalpay.testnet"

OFFRAMP = {
    "id": "0xabc",
    "payer": "payer.testnet",
    "payee": "lp.testnet",
    "amount": "12500",
    "inr_paise": 1000,
    "status": "Locked",
    "locked_at": 1_700_000_000,
    "completable_at": 1_700_000_015,
    "reclaimable_at": 1_700_086_400,
    "dispute_deadline": 0,
    "payout_ref": "",
    "digest": "",
}
WINDOWS = {"completable_delay": 15, "reclaim_after": 86_400, "dispute_window": 86_400,
           "dispute_timeout": 604_800}


def _rpc(value: object, *, error: str | None = None) -> httpx.MockTransport:
    payload = ({"jsonrpc": "2.0", "id": "globalpay", "error": {"message": error}} if error
               else {"jsonrpc": "2.0", "id": "globalpay",
                     "result": {"result": list(json.dumps(value).encode())}})

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=payload)

    return httpx.MockTransport(handler)


def vault(transport: httpx.MockTransport, **kw) -> NearVault:
    return NearVault(CONTRACT, token=TOKEN, transport=transport, account="relayer.testnet", **kw)


def by_method(answers: dict[str, object]) -> httpx.MockTransport:
    """Answer each view method differently, decoding the requested method from the request."""

    def handler(request: httpx.Request) -> httpx.Response:
        sent = json.loads(request.content)
        method = sent["params"]["method_name"]
        value = answers.get(method)
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": "globalpay",
                                         "result": {"result": list(json.dumps(value).encode())}})

    return httpx.MockTransport(handler)


# ---- reads --------------------------------------------------------------------------------------


def test_a_locked_payment_reads_back():
    with vault(_rpc(OFFRAMP)) as v:
        o = v.offramp("0xabc")
    assert o["status"] == "Locked" and o["inr_paise"] == 1000


def test_the_status_names_map_to_the_numbers_the_store_uses():
    # These numbers are what STATUS_NAMES and the settler already speak; drifting them would make a
    # completed payment look refunded.
    assert STATUS_BY_NAME == {"Locked": 1, "Completed": 2, "Refunded": 3, "Reversed": 4,
                              "Released": 5, "Disputed": 6}


def test_an_unknown_payment_is_none():
    with vault(_rpc(None)) as v:
        assert v.offramp("nope") is None


def test_the_settler_sees_the_same_offramp_shape_as_on_evm():
    client = NearChainClient(vault(_rpc(OFFRAMP)))
    st = asyncio_run(client.offramp_state("0xabc"))
    assert st.status == 1 and st.status_name == "LOCKED"
    assert st.user == "payer.testnet" and st.amount == 12_500 and st.inr_paise == 1_000
    assert st.locked_at == 1_700_000_000


def test_a_payment_that_is_not_there_reads_as_none_status():
    client = NearChainClient(vault(_rpc(None)))
    st = asyncio_run(client.offramp_state("0xabc"))
    assert st.status == 0 and st.amount == 0


def test_deadlines_combine_the_payment_with_the_contract_windows():
    client = NearChainClient(vault(by_method({"offramp": OFFRAMP, "windows": WINDOWS})))
    d = asyncio_run(client.deadlines("0xabc"))
    assert d.completable_at == 1_700_000_015
    assert d.reclaimable_at == 1_700_086_400
    assert d.dispute_window == 86_400
    # No dispute yet: the releasable moment is the timeout after a (zero) deadline.
    assert d.releasable_at == 604_800


def test_asking_for_deadlines_of_a_missing_payment_is_an_error():
    client = NearChainClient(vault(_rpc(None)))
    with pytest.raises(ChainError):
        asyncio_run(client.deadlines("0xabc"))


def test_chain_time_is_in_seconds():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": "globalpay",
                                         "result": {"header": {"timestamp": "1700000000123456789"}}})

    with NearVault(CONTRACT, transport=httpx.MockTransport(handler)) as v:
        assert v.chain_time() == 1_700_000_000


def test_an_rpc_error_is_reported():
    with NearVault(CONTRACT, transport=_rpc(None, error="contract does not exist")) as v:
        with pytest.raises(ChainError, match="contract does not exist"):
            v.offramp("0xabc")


# ---- writes -------------------------------------------------------------------------------------


def test_completing_carries_the_receipt_digest():
    with vault(_rpc(None)) as v:
        cmd = v.complete_command("0xabc", "22" * 32, "11" * 32)
    assert cmd[:6] == ["near", "contract", "call-function", "as-transaction", CONTRACT, "complete"]
    args = json.loads(cmd[cmd.index("json-args") + 1])
    assert args == {"id": "0xabc", "payout_ref": "22" * 32, "digest": "11" * 32}
    assert cmd[cmd.index("sign-as") + 1] == "relayer.testnet"


def test_refund_carries_its_reason():
    with NearVault(CONTRACT, transport=_rpc(None)) as v:
        cmd = v.refund_command("0xabc", 3)
    assert json.loads(cmd[cmd.index("json-args") + 1]) == {"id": "0xabc", "reason": 3}


def test_a_lock_is_an_ft_transfer_call_into_the_vault():
    with NearVault(CONTRACT, token=TOKEN, transport=_rpc(None), account="payer.testnet") as v:
        cmd = v.lock_command(amount=12_500, payee="lp.testnet", inr_paise=1000, payment_id="0xabc")
    assert cmd[cmd.index("as-transaction") + 1] == TOKEN
    assert cmd[cmd.index("as-transaction") + 2] == "ft_transfer_call"
    args = json.loads(cmd[cmd.index("json-args") + 1])
    assert args["receiver_id"] == CONTRACT and args["amount"] == "12500"
    assert json.loads(args["msg"]) == {"id": "0xabc", "payee": "lp.testnet", "inr_paise": 1000}
    # A plain ft_transfer would move money with no lock; the call must be the callback form.
    assert "ft_transfer_call" in cmd and cmd[cmd.index("attached-deposit") + 1] == "1 yoctoNEAR"


def test_a_lock_without_a_token_is_refused():
    with NearVault(CONTRACT, transport=_rpc(None)) as v:
        with pytest.raises(ChainError, match="no token account"):
            v.lock_command(amount=1, payee="lp.testnet", inr_paise=1, payment_id="x")


def test_lock_message_is_json_the_contract_can_parse():
    assert json.loads(lock_message("lp.testnet", 1000, "0xabc"))["payee"] == "lp.testnet"


def test_sending_maps_the_settler_call_names_onto_the_contract():
    seen: list[list[str]] = []
    v = NearVault(CONTRACT, transport=_rpc(None), account="relayer.testnet")
    v.run = lambda command, timeout=120.0: (seen.append(command) or (True, "│ Transaction ID: 5Zx1 │"))
    client = NearChainClient(v)

    out = asyncio_run(client.send(object(), "completeOfframp", ("0xabc", "22" * 32, "11" * 32)))
    assert out.hash == "5Zx1"
    assert seen[0][5] == "complete"

    asyncio_run(client.send(object(), "refundOfframp", ("0xabc", 3)))
    assert seen[1][5] == "refund"

    asyncio_run(client.send(object(), "reverseOfframp", ("0xabc",)))
    assert seen[2][5] == "resolve_dispute"
    assert json.loads(seen[2][seen[2].index("json-args") + 1])["refund_payer"] is True

    asyncio_run(client.send(object(), "reclaimOfframp", ("0xabc",)))
    assert seen[3][5] == "reclaim"


def test_an_unknown_call_is_refused_rather_than_guessed():
    client = NearChainClient(NearVault(CONTRACT, transport=_rpc(None)))
    with pytest.raises(ChainError, match="no equivalent"):
        asyncio_run(client.send(object(), "disputeOfframpWithSig", ("0xabc", 1, b"sig")))


def test_a_failed_call_raises_instead_of_looking_settled():
    v = NearVault(CONTRACT, transport=_rpc(None), account="relayer.testnet")
    v.run = lambda command, timeout=120.0: (False, "ERROR Transaction failed: only the settler may settle")
    client = NearChainClient(v)
    with pytest.raises(ChainError, match="only the settler"):
        asyncio_run(client.send(object(), "completeOfframp", ("0xabc", "22" * 32, "11" * 32)))


def test_the_tx_hash_is_read_out_of_the_cli_output():
    boxed = "│    Transaction ID: 7Yq2abcd │\n│    Gas used: 2.0 Tgas"
    assert tx_hash_of(boxed) == "7Yq2abcd"
    assert tx_hash_of("nothing here") == ""


def test_the_explorer_link_points_at_the_transaction():
    client = NearChainClient(NearVault(CONTRACT, transport=_rpc(None)))
    assert client.tx_url("abc") == "https://testnet.nearblocks.io/txns/abc"


# ---- helpers ------------------------------------------------------------------------------------


def asyncio_run(coro):
    import asyncio

    return asyncio.run(coro)
