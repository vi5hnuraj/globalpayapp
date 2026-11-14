//! Callback-safe GlobalPay escrow for the NEAR hackathon MVP.
//!
//! The merchant payout happens off-chain. The configured settler must freeze the payer's refund
//! before starting that payout, and may transfer escrow to the configured treasury only after the
//! provider returns definitive paid evidence. Unknown payout outcomes remain frozen for review.
use near_sdk::json_types::U128;
use near_sdk::serde_json::json;
use near_sdk::{
    env, ext_contract, near, AccountId, Gas, NearToken, PanicOnDefault, Promise, PromiseOrValue,
};

const GAS_FOR_FT_TRANSFER: Gas = Gas::from_tgas(15);
const GAS_FOR_TRANSFER_CALLBACK: Gas = Gas::from_tgas(10);
const MAX_ID_LENGTH: usize = 96;

#[ext_contract(ext_ft)]
#[allow(dead_code)]
trait FungibleToken {
    fn ft_transfer(&mut self, receiver_id: AccountId, amount: U128, memo: Option<String>);
}

#[ext_contract(ext_self)]
#[allow(dead_code)]
trait RefundCallback {
    fn on_refund_complete(&mut self, id: String) -> bool;
    fn on_settlement_complete(&mut self, id: String, treasury: AccountId) -> bool;
}

#[near(serializers = [json, borsh])]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Locked,
    RefundPending,
    Refunded,
    PayoutPending,
    SettlementPending,
    Settled,
}

#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EscrowLock {
    pub id: String,
    pub payer: AccountId,
    pub token: AccountId,
    pub amount: U128,
    pub locked_at: u64,
    pub status: Status,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Contract {
    owner: AccountId,
    token: AccountId,
    settler: AccountId,
    locks: near_sdk::store::LookupMap<String, EscrowLock>,
    total_locked: u128,
    treasury: AccountId,
    payout_refs: near_sdk::store::LookupMap<String, String>,
    used_payout_refs: near_sdk::store::LookupMap<String, String>,
    refund_from_payout: near_sdk::store::LookupMap<String, bool>,
}

/// Exact state layout of the lock/refund-only contract deployed before treasury settlement was
/// added. Lock values remain byte-compatible because new `Status` variants were appended.
#[near(serializers = [borsh])]
pub struct OldContract {
    owner: AccountId,
    token: AccountId,
    settler: AccountId,
    locks: near_sdk::store::LookupMap<String, EscrowLock>,
    total_locked: u128,
}

#[near]
impl Contract {
    #[init]
    pub fn new(
        owner: AccountId,
        token: AccountId,
        settler: AccountId,
        treasury: AccountId,
    ) -> Self {
        Self {
            owner,
            token,
            settler,
            locks: near_sdk::store::LookupMap::new(b"l"),
            total_locked: 0,
            treasury,
            payout_refs: near_sdk::store::LookupMap::new(b"p"),
            used_payout_refs: near_sdk::store::LookupMap::new(b"u"),
            refund_from_payout: near_sdk::store::LookupMap::new(b"r"),
        }
    }

    #[init(ignore_state)]
    pub fn migrate(treasury: AccountId) -> Self {
        let old: OldContract = env::state_read().expect("old contract state is missing");
        let caller = env::predecessor_account_id();
        assert!(
            caller == env::current_account_id() || caller == old.owner,
            "only the contract account or owner may migrate"
        );
        Self {
            owner: old.owner,
            token: old.token,
            settler: old.settler,
            locks: old.locks,
            total_locked: old.total_locked,
            treasury,
            payout_refs: near_sdk::store::LookupMap::new(b"p"),
            used_payout_refs: near_sdk::store::LookupMap::new(b"u"),
            refund_from_payout: near_sdk::store::LookupMap::new(b"r"),
        }
    }

    pub fn owner(&self) -> AccountId {
        self.owner.clone()
    }

    pub fn token(&self) -> AccountId {
        self.token.clone()
    }

    pub fn settler(&self) -> AccountId {
        self.settler.clone()
    }

    pub fn treasury(&self) -> AccountId {
        self.treasury.clone()
    }

    pub fn payout_reference(&self, id: String) -> Option<String> {
        self.payout_refs.get(&id).cloned()
    }

    pub fn set_settler(&mut self, settler: AccountId) {
        assert_eq!(
            env::predecessor_account_id(),
            self.owner,
            "only the owner may change the settler"
        );
        let old = self.settler.clone();
        self.settler = settler.clone();
        Self::event("settler_updated", json!({ "old": old, "new": settler }));
    }

    pub fn set_treasury(&mut self, treasury: AccountId) {
        assert_eq!(
            env::predecessor_account_id(),
            self.owner,
            "only the owner may change the treasury"
        );
        let old = self.treasury.clone();
        self.treasury = treasury.clone();
        Self::event("treasury_updated", json!({ "old": old, "new": treasury }));
    }

    pub fn get_lock(&self, id: String) -> Option<EscrowLock> {
        self.locks.get(&id).cloned()
    }

    pub fn total_locked(&self) -> U128 {
        U128(self.total_locked)
    }

    /// Accept a token transfer and create one escrow lock.
    ///
    /// The token call must contain `msg = {"id":"..."}`. Returning zero accepts the full
    /// transfer. Invalid input panics, causing the NEP-141 token to resolve the transfer back to
    /// the sender.
    pub fn ft_on_transfer(
        &mut self,
        sender_id: AccountId,
        amount: U128,
        msg: String,
    ) -> PromiseOrValue<U128> {
        assert_eq!(
            env::predecessor_account_id(),
            self.token,
            "only the configured token may create locks"
        );
        assert!(amount.0 > 0, "amount must be positive");

        let body: near_sdk::serde_json::Value =
            near_sdk::serde_json::from_str(&msg).expect("msg must be JSON");
        let id = body
            .get("id")
            .and_then(|value| value.as_str())
            .expect("msg.id is required")
            .to_string();
        assert!(
            !id.is_empty() && id.len() <= MAX_ID_LENGTH,
            "invalid lock id"
        );
        assert!(self.locks.get(&id).is_none(), "lock id already exists");

        self.total_locked = self
            .total_locked
            .checked_add(amount.0)
            .expect("locked amount overflow");
        let lock = EscrowLock {
            id: id.clone(),
            payer: sender_id.clone(),
            token: self.token.clone(),
            amount,
            locked_at: env::block_timestamp_ms() / 1_000,
            status: Status::Locked,
        };
        self.locks.insert(id.clone(), lock);
        Self::event(
            "escrow_locked",
            json!({
                "id": id,
                "payer": sender_id,
                "token": self.token,
                "amount": amount.0.to_string(),
                "total_locked": self.total_locked.to_string(),
            }),
        );
        PromiseOrValue::Value(U128(0))
    }

    /// Start a callback-safe refund. A payer may cancel only before payout begins. The configured
    /// settler may also refund a frozen payout, but only after it has a definitive provider failure.
    /// An unknown provider result must stay `PayoutPending` for operator review.
    pub fn request_refund(&mut self, id: String) -> Promise {
        let mut lock = self.locks.get(&id).expect("no such lock").clone();
        let caller = env::predecessor_account_id();
        let from_payout = lock.status == Status::PayoutPending;
        let allowed = if caller == lock.payer {
            lock.status == Status::Locked
        } else if caller == self.settler {
            lock.status == Status::Locked || from_payout
        } else {
            false
        };
        assert!(allowed, "lock is not refundable by this caller");

        lock.status = Status::RefundPending;
        self.locks.insert(id.clone(), lock.clone());
        self.refund_from_payout.insert(id.clone(), from_payout);
        Self::event(
            "refund_pending",
            json!({
                "id": id,
                "payer": lock.payer,
                "amount": lock.amount.0.to_string(),
            }),
        );

        ext_ft::ext(self.token.clone())
            .with_attached_deposit(NearToken::from_yoctonear(1))
            .with_static_gas(GAS_FOR_FT_TRANSFER)
            .ft_transfer(
                lock.payer,
                lock.amount,
                Some(format!("GlobalPay refund {}", lock.id)),
            )
            .then(
                ext_self::ext(env::current_account_id())
                    .with_static_gas(GAS_FOR_TRANSFER_CALLBACK)
                    .on_refund_complete(id),
            )
    }

    /// Finalize a refund only after the NEP-141 transfer receipt succeeds. This callback avoids
    /// panic paths: after a successful external transfer, panicking here would leave the tokens sent
    /// while the lock still looked pending.
    #[private]
    pub fn on_refund_complete(&mut self, id: String) -> bool {
        assert_eq!(
            env::predecessor_account_id(),
            env::current_account_id(),
            "refund callback is private"
        );
        let Some(mut lock) = self.locks.get(&id).cloned() else {
            env::log_str("REFUND_CALLBACK_ERROR: lock is missing");
            return false;
        };
        if lock.status != Status::RefundPending {
            env::log_str("REFUND_CALLBACK_ERROR: lock is not pending");
            return false;
        }

        let transfer_succeeded =
            env::promise_results_count() == 1 && env::promise_result_checked(0, 1_024).is_ok();
        if !transfer_succeeded {
            lock.status = if self.refund_from_payout.get(&id).copied().unwrap_or(false) {
                Status::PayoutPending
            } else {
                Status::Locked
            };
            self.refund_from_payout.remove(&id);
            self.locks.insert(id.clone(), lock);
            Self::event("refund_failed", json!({ "id": id, "retryable": true }));
            return false;
        }

        if self.total_locked < lock.amount.0 {
            // This should be unreachable because no other transition can reduce a pending lock.
            // Do not panic after tokens have left the contract; record the terminal state and make
            // the accounting failure visible in logs.
            env::log_str(
                "REFUND_CALLBACK_ACCOUNTING_ERROR: total_locked was below the refund amount",
            );
            self.total_locked = 0;
        } else {
            self.total_locked -= lock.amount.0;
        }
        lock.status = Status::Refunded;
        self.refund_from_payout.remove(&id);
        self.locks.insert(id.clone(), lock.clone());
        Self::event(
            "escrow_refunded",
            json!({
                "id": id,
                "payer": lock.payer,
                "amount": lock.amount.0.to_string(),
                "total_locked": self.total_locked.to_string(),
            }),
        );
        true
    }

    /// Freeze payer cancellation before handing the private UPI details to a payout provider. The
    /// backend calls this first; an unknown payout outcome remains here for operator review.
    pub fn start_payout(&mut self, id: String) -> bool {
        self.assert_settler();
        let mut lock = self.locks.get(&id).expect("no such lock").clone();
        if lock.status == Status::PayoutPending {
            return false;
        }
        assert_eq!(
            lock.status,
            Status::Locked,
            "only a locked escrow may start payout"
        );
        lock.status = Status::PayoutPending;
        self.locks.insert(id.clone(), lock);
        Self::event("payout_pending", json!({ "id": id }));
        true
    }

    /// Send escrow to treasury only after the payout provider returned definitive paid evidence.
    /// `payout_ref` is a high-entropy commitment to provider payout ID + UTR, never the raw UTR.
    pub fn request_settlement(&mut self, id: String, payout_ref: String) -> Promise {
        self.assert_settler();
        assert!(
            Self::is_hash(&payout_ref),
            "payout reference must be 32 lowercase hex bytes"
        );
        assert!(
            self.used_payout_refs.get(&payout_ref).is_none(),
            "payout reference already used"
        );
        let mut lock = self.locks.get(&id).expect("no such lock").clone();
        assert_eq!(lock.status, Status::PayoutPending, "payout is not pending");
        lock.status = Status::SettlementPending;
        self.locks.insert(id.clone(), lock.clone());
        self.payout_refs.insert(id.clone(), payout_ref.clone());
        self.used_payout_refs.insert(payout_ref.clone(), id.clone());
        Self::event(
            "settlement_pending",
            json!({ "id": id, "payout_ref": payout_ref, "treasury": self.treasury }),
        );

        // Carry the exact transfer target into the callback. The owner may update the configured
        // treasury while this promise is in flight; the event must still identify where this
        // particular transfer actually went.
        let treasury = self.treasury.clone();
        ext_ft::ext(self.token.clone())
            .with_attached_deposit(NearToken::from_yoctonear(1))
            .with_static_gas(GAS_FOR_FT_TRANSFER)
            .ft_transfer(
                treasury.clone(),
                lock.amount,
                Some(format!("GlobalPay settlement {}", lock.id)),
            )
            .then(
                ext_self::ext(env::current_account_id())
                    .with_static_gas(GAS_FOR_TRANSFER_CALLBACK)
                    .on_settlement_complete(id, treasury),
            )
    }

    #[private]
    pub fn on_settlement_complete(&mut self, id: String, treasury: AccountId) -> bool {
        self.assert_private_callback();
        let Some(mut lock) = self.locks.get(&id).cloned() else {
            env::log_str("SETTLEMENT_CALLBACK_ERROR: lock is missing");
            return false;
        };
        if lock.status != Status::SettlementPending {
            env::log_str("SETTLEMENT_CALLBACK_ERROR: lock is not pending");
            return false;
        }
        let transfer_succeeded =
            env::promise_results_count() == 1 && env::promise_result_checked(0, 1_024).is_ok();
        if !transfer_succeeded {
            lock.status = Status::PayoutPending;
            self.locks.insert(id.clone(), lock);
            if let Some(reference) = self.payout_refs.remove(&id) {
                self.used_payout_refs.remove(&reference);
            }
            Self::event("settlement_failed", json!({ "id": id, "retryable": true }));
            return false;
        }
        self.subtract_after_transfer(lock.amount.0, "SETTLEMENT_CALLBACK_ACCOUNTING_ERROR");
        lock.status = Status::Settled;
        self.locks.insert(id.clone(), lock.clone());
        let payout_ref = self.payout_refs.get(&lock.id).cloned();
        Self::event(
            "escrow_settled",
            json!({
                "id": id,
                "treasury": treasury,
                "amount": lock.amount.0.to_string(),
                "payout_ref": payout_ref,
                "total_locked": self.total_locked.to_string(),
            }),
        );
        true
    }
}

impl Contract {
    fn assert_settler(&self) {
        assert_eq!(
            env::predecessor_account_id(),
            self.settler,
            "only the settler may do this"
        );
    }

    fn assert_private_callback(&self) {
        assert_eq!(
            env::predecessor_account_id(),
            env::current_account_id(),
            "callback is private"
        );
    }

    fn subtract_after_transfer(&mut self, amount: u128, error: &str) {
        if self.total_locked < amount {
            env::log_str(error);
            self.total_locked = 0;
        } else {
            self.total_locked -= amount;
        }
    }

    fn is_hash(value: &str) -> bool {
        value.len() == 64
            && value.bytes().any(|byte| byte != b'0')
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    }

    fn event(name: &str, data: near_sdk::serde_json::Value) {
        env::log_str(&format!(
            "EVENT_JSON:{}",
            json!({ "standard": "globalpay", "version": "1.0.0", "event": name, "data": [data] })
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use near_sdk::test_utils::VMContextBuilder;
    use near_sdk::{test_vm_config, testing_env, PromiseResult, RuntimeFeesConfig};
    use std::collections::HashMap;

    const CONTRACT: &str = "vault.testnet";
    const OWNER: &str = "owner.testnet";
    const TOKEN: &str = "usdc.testnet";
    const SETTLER: &str = "settler.testnet";
    const TREASURY: &str = "treasury.testnet";
    const PAYER: &str = "payer.testnet";
    const PAYOUT_REF: &str = "1111111111111111111111111111111111111111111111111111111111111111";
    const OTHER_PAYOUT_REF: &str =
        "2222222222222222222222222222222222222222222222222222222222222222";

    fn context(predecessor: &str, timestamp_sec: u64) -> VMContextBuilder {
        let mut builder = VMContextBuilder::new();
        builder
            .current_account_id(CONTRACT.parse().unwrap())
            .predecessor_account_id(predecessor.parse().unwrap())
            .block_timestamp(timestamp_sec * 1_000_000_000);
        builder
    }

    fn at(predecessor: &str) {
        testing_env!(context(predecessor, 1_700_000_000).build());
    }

    fn callback(result: PromiseResult) {
        testing_env!(
            context(CONTRACT, 1_700_000_001).build(),
            test_vm_config(),
            RuntimeFeesConfig::test(),
            HashMap::default(),
            vec![result],
        );
    }

    fn contract() -> Contract {
        at(OWNER);
        Contract::new(
            OWNER.parse().unwrap(),
            TOKEN.parse().unwrap(),
            SETTLER.parse().unwrap(),
            TREASURY.parse().unwrap(),
        )
    }

    fn lock(c: &mut Contract, id: &str, amount: u128) {
        at(TOKEN);
        let accepted = c.ft_on_transfer(
            PAYER.parse().unwrap(),
            U128(amount),
            format!(r#"{{"id":"{id}"}}"#),
        );
        assert!(matches!(accepted, PromiseOrValue::Value(U128(0))));
    }

    #[test]
    fn roles_and_token_are_configured() {
        let c = contract();
        assert_eq!(c.owner(), OWNER.parse::<AccountId>().unwrap());
        assert_eq!(c.token(), TOKEN.parse::<AccountId>().unwrap());
        assert_eq!(c.settler(), SETTLER.parse::<AccountId>().unwrap());
        assert_eq!(c.treasury(), TREASURY.parse::<AccountId>().unwrap());
        assert_eq!(c.total_locked(), U128(0));
    }

    #[test]
    fn only_owner_changes_settler() {
        let mut c = contract();
        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.set_settler("new-settler.testnet".parse().unwrap())
        }))
        .is_err());
        at(OWNER);
        c.set_settler("new-settler.testnet".parse().unwrap());
        assert_eq!(
            c.settler(),
            "new-settler.testnet".parse::<AccountId>().unwrap()
        );
    }

    #[test]
    fn only_owner_changes_treasury() {
        let mut c = contract();
        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.set_treasury("other-treasury.testnet".parse().unwrap())
        }))
        .is_err());
        at(OWNER);
        c.set_treasury("other-treasury.testnet".parse().unwrap());
        assert_eq!(
            c.treasury(),
            "other-treasury.testnet".parse::<AccountId>().unwrap()
        );
    }

    #[test]
    fn configured_token_creates_a_lock_and_accounts_for_it() {
        let mut c = contract();
        lock(&mut c, "pay-1", 1_250_000);
        let item = c.get_lock("pay-1".into()).unwrap();
        assert_eq!(item.payer, PAYER.parse::<AccountId>().unwrap());
        assert_eq!(item.token, TOKEN.parse::<AccountId>().unwrap());
        assert_eq!(item.amount, U128(1_250_000));
        assert_eq!(item.locked_at, 1_700_000_000);
        assert_eq!(item.status, Status::Locked);
        assert_eq!(c.total_locked(), U128(1_250_000));
    }

    #[test]
    fn wrong_token_cannot_create_a_lock() {
        let mut c = contract();
        at("other-token.testnet");
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.ft_on_transfer(PAYER.parse().unwrap(), U128(1), r#"{"id":"x"}"#.into())
        }));
        assert!(result.is_err());
        assert!(c.get_lock("x".into()).is_none());
        assert_eq!(c.total_locked(), U128(0));
    }

    #[test]
    fn zero_amount_is_rejected() {
        let mut c = contract();
        at(TOKEN);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.ft_on_transfer(PAYER.parse().unwrap(), U128(0), r#"{"id":"x"}"#.into())
        }));
        assert!(result.is_err());
        assert_eq!(c.total_locked(), U128(0));
    }

    #[test]
    fn lock_id_must_be_present_and_unique() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(TOKEN);
        let duplicate = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.ft_on_transfer(PAYER.parse().unwrap(), U128(20), r#"{"id":"pay-1"}"#.into())
        }));
        assert!(duplicate.is_err());
        assert_eq!(c.total_locked(), U128(10));
        assert_eq!(c.get_lock("pay-1".into()).unwrap().amount, U128(10));
    }

    #[test]
    fn stranger_cannot_refund() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at("stranger.testnet");
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_refund("pay-1".into());
        }));
        assert!(result.is_err());
        assert_eq!(c.get_lock("pay-1".into()).unwrap().status, Status::Locked);
        assert_eq!(c.total_locked(), U128(10));
    }

    #[test]
    fn payer_starts_refund_without_decrementing_accounting() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(PAYER);
        let _promise = c.request_refund("pay-1".into());
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::RefundPending
        );
        assert_eq!(c.total_locked(), U128(10));
    }

    #[test]
    fn settler_may_start_refund() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(SETTLER);
        let _promise = c.request_refund("pay-1".into());
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::RefundPending
        );
    }

    #[test]
    fn duplicate_refund_is_blocked_while_pending() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(PAYER);
        let _promise = c.request_refund("pay-1".into());
        let duplicate = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_refund("pay-1".into());
        }));
        assert!(duplicate.is_err());
        assert_eq!(c.total_locked(), U128(10));
    }

    #[test]
    fn successful_callback_finalizes_refund_and_accounting() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(PAYER);
        let _promise = c.request_refund("pay-1".into());
        callback(PromiseResult::Successful(Vec::new()));
        assert!(c.on_refund_complete("pay-1".into()));
        assert_eq!(c.get_lock("pay-1".into()).unwrap().status, Status::Refunded);
        assert_eq!(c.total_locked(), U128(0));
    }

    #[test]
    fn failed_transfer_restores_locked_state_and_allows_retry() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(PAYER);
        let _promise = c.request_refund("pay-1".into());
        callback(PromiseResult::Failed);
        assert!(!c.on_refund_complete("pay-1".into()));
        assert_eq!(c.get_lock("pay-1".into()).unwrap().status, Status::Locked);
        assert_eq!(c.total_locked(), U128(10));

        at(PAYER);
        let _retry = c.request_refund("pay-1".into());
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::RefundPending
        );
    }

    #[test]
    fn refunded_lock_cannot_be_refunded_or_finalized_twice() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(PAYER);
        let _promise = c.request_refund("pay-1".into());
        callback(PromiseResult::Successful(Vec::new()));
        assert!(c.on_refund_complete("pay-1".into()));

        callback(PromiseResult::Successful(Vec::new()));
        assert!(!c.on_refund_complete("pay-1".into()));
        assert_eq!(c.total_locked(), U128(0));
        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_refund("pay-1".into());
        }))
        .is_err());
    }

    #[test]
    fn callback_requires_the_contract_as_predecessor() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(PAYER);
        let _promise = c.request_refund("pay-1".into());
        callback(PromiseResult::Successful(Vec::new()));
        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.on_refund_complete("pay-1".into())
        }))
        .is_err());
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::RefundPending
        );
        assert_eq!(c.total_locked(), U128(10));
    }

    #[test]
    fn multiple_locks_keep_aggregate_accounting_consistent() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        lock(&mut c, "pay-2", 25);
        at(PAYER);
        let _promise = c.request_refund("pay-1".into());
        callback(PromiseResult::Successful(Vec::new()));
        assert!(c.on_refund_complete("pay-1".into()));
        assert_eq!(c.total_locked(), U128(25));
        assert_eq!(c.get_lock("pay-2".into()).unwrap().status, Status::Locked);
    }

    #[test]
    fn only_settler_starts_payout_and_repeat_freeze_is_idempotent() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);

        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.start_payout("pay-1".into())
        }))
        .is_err());

        at(SETTLER);
        assert!(c.start_payout("pay-1".into()));
        assert!(!c.start_payout("pay-1".into()));
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::PayoutPending
        );
        assert_eq!(c.total_locked(), U128(10));
    }

    #[test]
    fn payer_cannot_refund_after_payout_starts_but_settler_can_after_failure() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(SETTLER);
        c.start_payout("pay-1".into());

        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_refund("pay-1".into());
        }))
        .is_err());

        at(SETTLER);
        let _promise = c.request_refund("pay-1".into());
        callback(PromiseResult::Successful(Vec::new()));
        assert!(c.on_refund_complete("pay-1".into()));
        assert_eq!(c.get_lock("pay-1".into()).unwrap().status, Status::Refunded);
        assert_eq!(c.total_locked(), U128(0));
    }

    #[test]
    fn failed_post_payout_refund_stays_frozen_for_retry_by_settler() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(SETTLER);
        c.start_payout("pay-1".into());
        let _promise = c.request_refund("pay-1".into());

        callback(PromiseResult::Failed);
        assert!(!c.on_refund_complete("pay-1".into()));
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::PayoutPending
        );
        assert_eq!(c.total_locked(), U128(10));

        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_refund("pay-1".into());
        }))
        .is_err());
        at(SETTLER);
        let _retry = c.request_refund("pay-1".into());
    }

    #[test]
    fn settlement_requires_settler_pending_payout_and_nonzero_hash() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);

        at(SETTLER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_settlement("pay-1".into(), PAYOUT_REF.into());
        }))
        .is_err());
        c.start_payout("pay-1".into());

        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_settlement("pay-1".into(), PAYOUT_REF.into());
        }))
        .is_err());
        at(SETTLER);
        for invalid in [
            "0".repeat(64),
            "A".repeat(64),
            "1".repeat(63),
            format!("0x{}", "1".repeat(64)),
        ] {
            assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _ = c.request_settlement("pay-1".into(), invalid.clone());
            }))
            .is_err());
        }
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::PayoutPending
        );
    }

    #[test]
    fn successful_settlement_moves_to_terminal_state_and_reduces_accounting() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(SETTLER);
        c.start_payout("pay-1".into());
        let _promise = c.request_settlement("pay-1".into(), PAYOUT_REF.into());
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::SettlementPending
        );
        assert_eq!(c.total_locked(), U128(10));

        callback(PromiseResult::Successful(Vec::new()));
        assert!(c.on_settlement_complete("pay-1".into(), TREASURY.parse().unwrap()));
        assert_eq!(c.get_lock("pay-1".into()).unwrap().status, Status::Settled);
        assert_eq!(c.payout_reference("pay-1".into()), Some(PAYOUT_REF.into()));
        assert_eq!(c.total_locked(), U128(0));

        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_refund("pay-1".into());
        }))
        .is_err());
    }

    #[test]
    fn failed_settlement_returns_to_frozen_state_and_same_evidence_can_retry() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(SETTLER);
        c.start_payout("pay-1".into());
        let _promise = c.request_settlement("pay-1".into(), PAYOUT_REF.into());

        callback(PromiseResult::Failed);
        assert!(!c.on_settlement_complete("pay-1".into(), TREASURY.parse().unwrap()));
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::PayoutPending
        );
        assert_eq!(c.payout_reference("pay-1".into()), None);
        assert_eq!(c.total_locked(), U128(10));

        at(SETTLER);
        let _retry = c.request_settlement("pay-1".into(), PAYOUT_REF.into());
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::SettlementPending
        );
    }

    #[test]
    fn one_payout_reference_cannot_settle_two_locks() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        lock(&mut c, "pay-2", 20);
        at(SETTLER);
        c.start_payout("pay-1".into());
        c.start_payout("pay-2".into());
        let _first = c.request_settlement("pay-1".into(), PAYOUT_REF.into());

        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = c.request_settlement("pay-2".into(), PAYOUT_REF.into());
        }))
        .is_err());
        let _second = c.request_settlement("pay-2".into(), OTHER_PAYOUT_REF.into());
    }

    #[test]
    fn settlement_callback_is_private() {
        let mut c = contract();
        lock(&mut c, "pay-1", 10);
        at(SETTLER);
        c.start_payout("pay-1".into());
        let _promise = c.request_settlement("pay-1".into(), PAYOUT_REF.into());
        callback(PromiseResult::Successful(Vec::new()));
        at(PAYER);
        assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            c.on_settlement_complete("pay-1".into(), TREASURY.parse().unwrap())
        }))
        .is_err());
        assert_eq!(
            c.get_lock("pay-1".into()).unwrap().status,
            Status::SettlementPending
        );
        assert_eq!(c.total_locked(), U128(10));
    }

    #[test]
    fn migration_preserves_old_lock_and_accounting() {
        at(OWNER);
        let mut locks = near_sdk::store::LookupMap::new(b"l");
        locks.insert(
            "old-pay".into(),
            EscrowLock {
                id: "old-pay".into(),
                payer: PAYER.parse().unwrap(),
                token: TOKEN.parse().unwrap(),
                amount: U128(42),
                locked_at: 1_699_999_999,
                status: Status::Locked,
            },
        );
        // `store::LookupMap` caches writes until it is flushed or dropped. A deployed old contract
        // has already ended its receipt before migration, so mirror that boundary in this unit test.
        locks.flush();
        let old = OldContract {
            owner: OWNER.parse().unwrap(),
            token: TOKEN.parse().unwrap(),
            settler: SETTLER.parse().unwrap(),
            locks,
            total_locked: 42,
        };
        env::state_write(&old);

        let c = Contract::migrate(TREASURY.parse().unwrap());
        assert_eq!(c.owner(), OWNER.parse::<AccountId>().unwrap());
        assert_eq!(c.treasury(), TREASURY.parse::<AccountId>().unwrap());
        assert_eq!(c.total_locked(), U128(42));
        assert_eq!(
            c.get_lock("old-pay".into()).unwrap(),
            EscrowLock {
                id: "old-pay".into(),
                payer: PAYER.parse().unwrap(),
                token: TOKEN.parse().unwrap(),
                amount: U128(42),
                locked_at: 1_699_999_999,
                status: Status::Locked,
            }
        );
    }
}
