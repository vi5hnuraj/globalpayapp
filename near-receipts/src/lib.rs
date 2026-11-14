//! GlobalPay receipt anchor.
//!
//! Every settled rupee payment has a receipt the merchant and the buyer could argue about later: which
//! payment, which escrow, how much, and which bank reference. Those details cannot go on a public chain
//! — a UPI ID or a UTR next to an amount is somebody's private business. So this contract stores only
//! a 32-byte digest of a receipt that
//! lives off-chain, plus the few public facts needed to find it again.
//!
//! What it buys us: after a payout is confirmed, the digest is anchored here by a relayer account, and
//! anyone holding the receipt can recompute the digest and check `is_anchored`. A receipt cannot be
//! quietly rewritten afterwards, and nothing private is published to prove it.
//!
//! What it is *not*: proof that money moved. `COMPLETED` on the vault does not prove the merchant was
//! paid, and neither does this. The digest is only as truthful as the backend that anchored it, which
//! is exactly why the anchor set is an explicit, owner-managed allow-list.
use near_sdk::serde_json::json;
use near_sdk::{env, near, AccountId, NearToken, PanicOnDefault};

/// One anchored receipt. `digest` is lowercase hex of a 32-byte SHA-256 over the receipt body.
/// `utr_hash` is hex SHA-256 of the bank reference; the reference itself stays off-chain.
#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Receipt {
    pub payment_id: String,
    pub digest: String,
    pub chain: String,
    pub amount: String,
    pub utr_hash: String,
    pub paid_at: u64,
    pub anchor: AccountId,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Contract {
    owner: AccountId,
    anchors: Vec<AccountId>,
    receipts: std::collections::HashMap<String, Receipt>,
    by_digest: std::collections::HashMap<String, String>,
}

const MAX_PAYMENT_ID: usize = 96;
const MAX_CHAIN: usize = 32;
const MAX_AMOUNT: usize = 40;
const MAX_ANCHORS: usize = 8;

fn is_hex_32(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit()) && !value.contains(char::is_uppercase)
}

fn is_hex_32_or_empty(value: &str) -> bool {
    value.is_empty() || is_hex_32(value)
}

#[near]
impl Contract {
    /// `owner` manages the anchor allow-list; it is the deployer's account.
    #[init]
    pub fn new(owner: AccountId) -> Self {
        Self { owner, anchors: Vec::new(), receipts: Default::default(), by_digest: Default::default() }
    }

    pub fn owner(&self) -> AccountId {
        self.owner.clone()
    }

    pub fn anchors(&self) -> Vec<AccountId> {
        self.anchors.clone()
    }

    /// Only the owner decides which accounts may anchor. An open anchor method would let anyone claim
    /// a payment id before the real backend got to it.
    pub fn add_anchor(&mut self, account: AccountId) {
        self.assert_owner();
        if self.anchors.iter().any(|a| a == &account) {
            env::panic_str("that account can already anchor");
        }
        assert!(self.anchors.len() < MAX_ANCHORS, "too many anchors");
        self.anchors.push(account);
    }

    pub fn remove_anchor(&mut self, account: AccountId) {
        self.assert_owner();
        let before = self.anchors.len();
        self.anchors.retain(|a| a != &account);
        assert!(self.anchors.len() < before, "that account was not an anchor");
    }

    /// Anchor one settled payment. The caller must be an anchor account.
    ///
    /// Re-anchoring the same digest under the same payment id is rejected rather than overwritten, so a
    /// second call can never replace the record of what was paid.
    pub fn anchor(
        &mut self,
        payment_id: String,
        digest: String,
        chain: String,
        amount: String,
        utr_hash: String,
        paid_at: u64,
    ) {
        let caller = env::predecessor_account_id();
        assert!(self.anchors.contains(&caller), "only an anchor account may anchor a receipt");
        assert!(!payment_id.is_empty() && payment_id.len() <= MAX_PAYMENT_ID, "bad payment id");
        assert!(is_hex_32(&digest), "digest must be 32 lowercase hex bytes");
        assert!(!chain.is_empty() && chain.len() <= MAX_CHAIN, "bad chain");
        assert!(!amount.is_empty() && amount.len() <= MAX_AMOUNT, "bad amount");
        assert!(is_hex_32_or_empty(&utr_hash), "utr hash must be empty or 32 lowercase hex bytes");
        assert!(paid_at > 0, "paid_at is required");
        assert!(self.receipts.get(&payment_id).is_none(), "that payment is already anchored");

        if let Some(other) = self.by_digest.get(&digest) {
            assert!(other == &payment_id, "that digest is already anchored under another payment");
        }

        let receipt = Receipt {
            payment_id: payment_id.clone(),
            digest: digest.clone(),
            chain,
            amount: amount.clone(),
            utr_hash,
            paid_at,
            anchor: caller.clone(),
        };

        // NEP-297, so an indexer can follow settlements without polling every payment id.
        let event = json!({
            "standard": "nep297",
            "version": "1.0.0",
            "event": "receipt_anchored",
            "data": [{
                "payment_id": payment_id.clone(),
                "digest": digest.clone(),
                "amount": amount,
                "paid_at": paid_at,
            }],
        });
        env::log_str(&format!("EVENT_JSON:{event}"));

        self.by_digest.insert(digest, payment_id.clone());
        self.receipts.insert(payment_id, receipt);
    }

    pub fn receipt(&self, payment_id: String) -> Option<Receipt> {
        self.receipts.get(&payment_id).cloned()
    }

    /// The check a merchant (or an auditor) makes: is this receipt body the one that was anchored?
    pub fn is_anchored(&self, digest: String) -> bool {
        self.by_digest.contains_key(&digest)
    }

    pub fn receipt_count(&self) -> u64 {
        self.receipts.len() as u64
    }
}

impl Contract {
    fn assert_owner(&self) {
        assert_eq!(env::predecessor_account_id(), self.owner, "only the owner may change the anchor list");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use near_sdk::test_utils::VMContextBuilder;
    use near_sdk::testing_env;

    const DIGEST: &str = "1111111111111111111111111111111111111111111111111111111111111111";

    fn context(caller: &str) {
        testing_env!(VMContextBuilder::new().predecessor_account_id(caller.parse().unwrap()).build());
    }

    fn contract() -> Contract {
        context("globalpay.near");
        Contract::new("globalpay.near".parse().unwrap())
    }

    fn anchor(contract: &mut Contract, id: &str, digest: &str) {
        contract.anchor(id.to_string(), digest.to_string(), "arc".into(), "12500".into(), String::new(), 1_700_000_000);
    }

    #[test]
    fn owner_is_the_deployer() {
        assert_eq!(contract().owner(), "globalpay.near".parse::<AccountId>().unwrap());
    }

    #[test]
    fn an_anchored_receipt_reads_back() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        anchor(&mut c, "pay-1", DIGEST);

        let r = c.receipt("pay-1".into()).unwrap();
        assert_eq!(r.digest, DIGEST);
        assert_eq!(r.anchor, "relayer.near".parse::<AccountId>().unwrap());
        assert!(c.is_anchored(DIGEST.into()));
        assert_eq!(c.receipt_count(), 1);
    }

    #[test]
    fn an_unknown_receipt_is_none() {
        assert!(contract().receipt("nope".into()).is_none());
    }

    #[test]
    #[should_panic(expected = "only an anchor account may anchor")]
    fn a_stranger_cannot_anchor() {
        let mut c = contract();
        context("mallory.near");
        anchor(&mut c, "pay-1", DIGEST);
    }

    #[test]
    #[should_panic(expected = "only the owner may change the anchor list")]
    fn a_stranger_cannot_add_an_anchor() {
        let mut c = contract();
        context("mallory.near");
        c.add_anchor("mallory.near".parse().unwrap());
    }

    #[test]
    fn the_owner_can_remove_an_anchor() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        c.remove_anchor("relayer.near".parse().unwrap());
        assert!(c.anchors().is_empty());
        context("relayer.near");
        // Removing an anchor takes its power away immediately.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| anchor(&mut c, "pay-1", DIGEST)));
        assert!(result.is_err());
    }

    #[test]
    #[should_panic(expected = "that payment is already anchored")]
    fn a_payment_is_anchored_once() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        anchor(&mut c, "pay-1", DIGEST);
        anchor(&mut c, "pay-1", "2222222222222222222222222222222222222222222222222222222222222222");
    }

    #[test]
    fn a_receipt_is_never_replaced() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        anchor(&mut c, "pay-1", DIGEST);
        let second = "2222222222222222222222222222222222222222222222222222222222222222";
        let held = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| anchor(&mut c, "pay-1", second)));
        assert!(held.is_err());
        // What was recorded first is what stays recorded.
        assert_eq!(c.receipt("pay-1".into()).unwrap().digest, DIGEST);
        assert!(!c.is_anchored(second.into()));
    }

    #[test]
    #[should_panic(expected = "that digest is already anchored under another payment")]
    fn one_digest_belongs_to_one_payment() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        anchor(&mut c, "pay-1", DIGEST);
        anchor(&mut c, "pay-2", DIGEST);
    }

    #[test]
    #[should_panic(expected = "digest must be 32 lowercase hex bytes")]
    fn a_digest_must_be_a_hash() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        anchor(&mut c, "pay-1", "not-a-digest");
    }

    #[test]
    #[should_panic(expected = "digest must be 32 lowercase hex bytes")]
    fn an_uppercase_digest_is_rejected() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        anchor(&mut c, "pay-1", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    }

    #[test]
    #[should_panic(expected = "utr hash must be empty or 32 lowercase hex bytes")]
    fn the_utr_itself_is_rejected() {
        // The bank reference must arrive hashed; storing "424242424242" would publish it.
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        c.anchor("pay-1".into(), DIGEST.into(), "arc".into(), "1".into(), "424242424242".into(), 1_700_000_000);
    }

    #[test]
    #[should_panic(expected = "paid_at is required")]
    fn a_receipt_needs_a_time() {
        let mut c = contract();
        c.add_anchor("relayer.near".parse().unwrap());
        context("relayer.near");
        c.anchor("pay-1".into(), DIGEST.into(), "arc".into(), "1".into(), String::new(), 0);
    }

    #[test]
    fn there_is_a_cap_on_anchors() {
        let mut c = contract();
        for i in 0..MAX_ANCHORS {
            c.add_anchor(format!("anchor{i}.near").parse().unwrap());
        }
        assert_eq!(c.anchors().len(), MAX_ANCHORS);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| c.add_anchor("one-more.near".parse().unwrap())));
        assert!(result.is_err());
    }
}

// Keeps the unused-import warning away when the storage deposit type is not referenced above.
#[allow(dead_code)]
fn _deposit_note() -> NearToken {
    NearToken::from_near(0)
}
