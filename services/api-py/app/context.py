"""Wires settings, chains, keys, store, FX and every service into one object the API uses."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .chain import ChainClient
from .common import EventHub, RateLimiter
from .config import ChainConfig, Settings, load_chains
from .dispute_relay import DisputeRelay
from .fx import FxFeed
from .keepers import Keeper
from .keys import Keys, load_keys
from .listener import Listener
from .onramp import OnrampService
from .paymaster import Paymaster
from .payout_runner import PayoutRunner
from .quote_service import QuoteService
from .settler import Settler
from .store import Store


@dataclass
class Context:
    settings: Settings
    chains: dict[str, ChainConfig]
    clients: dict[str, Any]
    store: Store
    fx: FxFeed
    keys: Keys
    hub: EventHub
    settler: Settler
    runner: PayoutRunner
    listeners: dict[str, Listener]
    keeper: Keeper
    quotes: QuoteService
    paymaster: Paymaster
    disputes: DisputeRelay
    onramp: OnrampService
    near: Any = None
    near_payout: Any = None
    limiter: RateLimiter | None = None
    started_at: float = 0.0
    onchain_roles: dict[str, dict] = field(default_factory=dict)


def build_context(settings: Settings | None = None, *, chains: dict[str, ChainConfig] | None = None,
                  clients: dict[str, Any] | None = None, store: Store | None = None, fx: FxFeed | None = None,
                   keys: Keys | None = None, black_box=None, clock=None, razorpay: Any = None,
                   near: Any = None, near_payout: Any = None) -> Context:
    import time

    settings = settings or Settings()
    chains = load_chains(settings.enabled_chains) if chains is None else chains
    clients = clients if clients is not None else {
        k: ChainClient(cfg, dry_run=settings.dry_run, receipt_timeout=settings.tx_receipt_timeout_sec)
        for k, cfg in chains.items()
    }
    store = store or Store(settings.db_path)
    fx = fx or FxFeed(sorted({"USDCINR", *(c.fx_market for c in chains.values())}), max_age_sec=settings.fx_max_age_sec,
                      poll_sec=settings.fx_poll_sec, global_poll_sec=settings.global_ref_poll_sec)
    if keys is None:
        if chains:
            keys = load_keys(settings.env_file)
        else:
            from .keys import disabled_keys

            keys = disabled_keys()
    clock = clock or time.time
    hub = EventHub()
    if near is None:
        from .near_mvp import NearMvpClient

        near = NearMvpClient()
    if near_payout is None:
        from .environment import AppEnv, current_env, payout_rail
        from .near_payout import NearPayoutService, NearVaultWriter

        rail = payout_rail().name
        near_payout = NearPayoutService(
            store,
            near,
            NearVaultWriter(
                contract=near.config.vault_account_id,
                account=settings.near_settler_account,
                near_cli=settings.near_cli,
                network=near.config.network_id,
                timeout=settings.tx_receipt_timeout_sec,
            ),
            command=settings.payout_command,
            rail=rail,
            enabled=(
                settings.near_payouts
                and bool(settings.near_settler_account)
                and current_env() is AppEnv.PROD
            ),
            timeout_sec=settings.payout_timeout_sec,
            max_lock_age_sec=settings.payout_max_lock_age_sec,
            clock=clock,
        )
    from .near_receipts import anchorer

    settler = Settler(clients, store, keys.settler, alert_after_sec=settings.complete_alert_sec, hub=hub, clock=clock,
                      on_settled=anchorer(contract=settings.near_receipts_contract,
                                          account=settings.near_anchor_account, near_cli=settings.near_cli))
    runner_kwargs = {"black_box": black_box} if black_box else {}
    runner = PayoutRunner(store, settler, command=settings.payout_command, timeout_sec=settings.payout_timeout_sec,
                          max_lock_age_sec=settings.payout_max_lock_age_sec, hub=hub, clock=clock, **runner_kwargs)
    if razorpay is None and settings.collect_rail == "razorpay":
        razorpay = _razorpay_client(settings)  # None if keys are missing; startup then refuses (environment.py)
    listeners = {
        k: Listener(k, clients[k], store, settler, runner, hub=hub, poll_sec=settings.listener_poll_sec,
                    max_range=settings.listener_max_range, confirmations=settings.listener_confirmations)
        for k in clients
    }
    return Context(
        settings=settings, chains=chains, clients=clients, store=store, fx=fx, keys=keys, hub=hub,
        settler=settler, runner=runner, listeners=listeners,
        keeper=Keeper(clients, store, keys.paymaster, hub=hub),
        quotes=QuoteService(settings, chains, store, fx, keys.quote_signer, clients=clients, clock=clock),
        paymaster=Paymaster(chains, clients, store, keys.paymaster, hub=hub, clock=clock),
        disputes=DisputeRelay(chains, clients, store, keys.paymaster, hub=hub),
        onramp=OnrampService(settings, chains, store, fx, settler, clock=clock, razorpay=razorpay),
        near=near, near_payout=near_payout,
        limiter=RateLimiter(settings.rate_limit_per_min),
    )


def _razorpay_client(settings: Settings):
    from .razorpay import RazorpayClient, RazorpayError, load_creds

    try:
        return RazorpayClient(load_creds(settings.env_file))
    except RazorpayError:
        return None
