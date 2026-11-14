from __future__ import annotations

from dataclasses import dataclass, field

import pytest
from fastapi.testclient import TestClient

from app.context import build_context
from app.main import create_app
from app.near_mvp import NearMvpConfig, NearMvpError, valid_account_id

from .conftest import ARC, QR


ACCOUNT = "demo.globalpay-receipts.testnet"
TX = "73W2bhLAyD28getf1XWVUcmBZ6632uriwnVjXuF12S7a"


@dataclass
class FakeNear:
    config: NearMvpConfig = field(default_factory=NearMvpConfig)
    locks: dict[str, dict] = field(default_factory=dict)
    verified: list[tuple[str, str, int]] = field(default_factory=list)
    reject_tx: bool = False

    async def close(self):
        pass

    async def status(self):
        return {"chain_id": "testnet", "sync_info": {"latest_block_height": 277_000_000}}

    async def metadata(self):
        return {"spec": "ft-1.0.0", "name": "Bridged USDC", "symbol": "USDC.e", "decimals": 6}

    async def account(self, account_id):
        if account_id != ACCOUNT:
            raise NearMvpError("account does not exist")
        return {"amount": "1000000000000000000000000"}

    async def balance(self, account_id):
        await self.account(account_id)
        return 100_000_000

    async def storage_balance(self, account_id):
        await self.account(account_id)
        return {"total": "1250000000000000000000", "available": "0"}

    async def treasury(self):
        return "treasury.globalpay-receipts.testnet"

    async def transaction(self, tx_hash, sender):
        return {"transaction": {"hash": tx_hash}, "status": {"SuccessValue": ""}, "receipts_outcome": [],
                "final_execution_status": "FINAL"}

    def verify_lock_transaction(self, outcome, *, sender, id_, amount):
        if self.reject_tx:
            raise NearMvpError("transaction amount differs from the quote")
        self.verified.append((sender, id_, amount))
        return {}

    async def lock(self, id_):
        return self.locks.get(id_)


@pytest.fixture
def near_env(settings, store, fx, keys, chain):
    near = FakeNear()
    ctx = build_context(settings, chains={"arc": ARC}, clients={"arc": chain}, store=store, fx=fx, keys=keys,
                        near=near)
    with TestClient(create_app(ctx, workers=False, fx=False)) as client:
        yield client, ctx, near


def test_near_account_id_validation_is_not_evm_validation():
    assert valid_account_id(ACCOUNT)
    assert valid_account_id("a" * 64)
    assert not valid_account_id("0x" + "11" * 20)
    assert not valid_account_id("Upper.testnet")


def test_config_and_real_account_shapes(near_env):
    client, _, _ = near_env
    config = client.get("/near/config")
    assert config.status_code == 200
    body = config.json()
    assert body["networkId"] == "testnet" and "chainId" not in body
    assert body["token"] == {
        "accountId": "usdc.fakes.testnet", "name": "Bridged USDC", "symbol": "USDC.e",
        "decimals": 6, "spec": "ft-1.0.0", "testAsset": True,
    }
    assert body["treasuryAccountId"] == "treasury.globalpay-receipts.testnet"
    assert body["capabilities"] == {
        "lock": True,
        "refundBeforePayout": True,
        "treasurySettlement": True,
        "merchantPayout": False,
        "payoutRail": None,
    }

    account = client.get(f"/near/account/{ACCOUNT}").json()
    assert account["accountId"] == ACCOUNT and account["tokenBalance"] == "100000000"
    assert account["tokenBalanceFormatted"] == "100.000000" and account["storageRegistered"] is True


def test_quote_reuses_upi_and_fx_logic_without_claiming_payout(near_env):
    client, ctx, _ = near_env
    response = client.post("/near/quote", json={"accountId": ACCOUNT, "inr": "10", "qrText": QR})
    assert response.status_code == 200, response.text
    quote = response.json()
    assert quote["networkId"] == "testnet" and quote["accountId"] == ACCOUNT
    assert quote["tokenAccountId"] == "usdc.fakes.testnet"
    assert quote["vaultAccountId"] == "vault.globalpay-receipts.testnet"
    assert quote["amount"] == "100666" and quote["inrPaise"] == "1000"
    assert quote["payee"]["upiId"] == "chaipoint@okaxis"
    assert quote["transferCall"]["method"] == "ft_transfer_call"
    assert quote["transferCall"]["deposit"] == "1"
    assert ctx.store.get_near_quote(quote["id"])["qr_text"] == QR


def test_track_verifies_final_transaction_and_is_idempotent(near_env):
    client, ctx, near = near_env
    quote = client.post("/near/quote", json={"accountId": ACCOUNT, "inr": "10", "qrText": QR}).json()
    near.locks[quote["id"]] = {
        "id": quote["id"], "payer": ACCOUNT, "token": "usdc.fakes.testnet", "amount": quote["amount"],
        "locked_at": 1_700_000_000, "status": "Locked",
    }
    body = {"id": quote["id"], "accountId": ACCOUNT, "txHash": TX}
    first = client.post("/near/track", json=body)
    assert first.status_code == 200, first.text
    assert first.json()["status"] == "Locked" and first.json()["merchantPayout"] == "NOT_STARTED"
    assert near.verified == [(ACCOUNT, quote["id"], 100666)]
    assert ctx.store.get_near_payment(quote["id"])["tx_hash"] == TX

    second = client.post("/near/track", json=body)
    assert second.status_code == 200 and ctx.store.list_near_payments(ACCOUNT)[0]["id"] == quote["id"]

    private = client.get(f"/near/payment/{quote['id']}", headers={"x-view-token": quote["viewToken"]}).json()
    public = client.get(f"/near/payment/{quote['id']}").json()
    assert private["payee"]["upiId"] == "chaipoint@okaxis" and public["payee"] is None
    assert private["canRefund"] is True
    assert private["merchantPayoutConfigured"] is False

    ctx.store.update_near_payment(quote["id"], payout_state="PAID", payout_ref="11" * 32)
    near.locks[quote["id"]]["status"] = "PayoutPending"
    paid = client.get(f"/near/payment/{quote['id']}").json()
    assert paid["merchantPayout"] == "PAID_SETTLEMENT_PENDING"
    assert paid["merchantPaid"] is True and paid["canRefund"] is False


def test_track_rejects_a_transaction_that_does_not_match(near_env):
    client, _, near = near_env
    quote = client.post("/near/quote", json={"accountId": ACCOUNT, "inr": "10", "qrText": QR}).json()
    near.reject_tx = True
    response = client.post("/near/track", json={"id": quote["id"], "accountId": ACCOUNT, "txHash": TX})
    assert response.status_code == 400 and response.json()["error"] == "NEAR_TRANSACTION"
