// One client for everything the phone talks to: the relayer (which talks to GlobalPay and the chain)
// and GlobalPay's own quote endpoint for the payout status shown after a payment.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'eip712.dart';

class ApiError implements Exception {
  ApiError(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class Api {
  Api(
      {required this.baseUrl,
      String? globalPayUrl,
      this.timeout = const Duration(seconds: 20)})
      : globalPayUrl = globalPayUrl ?? baseUrl;

  /// The relayer: this phone's wallet, cards, payments and signatures.
  final String baseUrl;

  /// GlobalPay's own API: quotes, escrow, onramp orders and payout detail. In development the
  /// relayer proxies quotes, but onramp and offramp detail only exist here.
  final String globalPayUrl;

  final Duration timeout;

  Future<Map<String, dynamic>> _send(String method, String path,
          [Map<String, dynamic>? body]) =>
      _sendTo(baseUrl, method, path, body);

  Future<Map<String, dynamic>> _sendTo(String base, String method, String path,
      [Map<String, dynamic>? body, Map<String, String>? extraHeaders]) async {
    final uri = Uri.parse('$base$path');
    late http.Response res;
    try {
      res = await (method == 'GET'
              ? http.get(uri,
                  headers: {'accept': 'application/json', ...?extraHeaders})
              : http.post(uri,
                  headers: {
                    'content-type': 'application/json',
                    'accept': 'application/json',
                    ...?extraHeaders,
                  },
                  body: jsonEncode(body ?? {})))
          .timeout(timeout);
    } on Exception {
      // The phone is offline or the relayer is down; the caller decides what that means.
      throw ApiError(
          'Cannot reach the payment service. Check your connection.');
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiError(
          'The payment service sent an unexpected reply (${res.statusCode}).',
          status: res.statusCode);
    }
    if (res.statusCode >= 400) {
      throw ApiError(
          (json['error'] ?? 'Request failed (${res.statusCode})').toString(),
          status: res.statusCode);
    }
    return json;
  }

  Future<Map<String, dynamic>> health() => _send('GET', '/api/health');

  /// Everything the Home and Activity screens show: balance, limits, spend, cards, history.
  Future<Map<String, dynamic>> wallet(String address) =>
      _send('GET', '/api/wallet/$address');

  // --- pay a UPI QR ---------------------------------------------------------------------------

  /// Step 1: the card is tapped, the relayer quotes GlobalPay, and we get the digest to sign.
  Future<ScanPayStart> startScanPay(
      {required String cardModulusHex,
      required String inr,
      required String qrText}) async {
    final json = await _send('POST', '/api/scanpay/start', {
      'cardModulus': cardModulusHex,
      'inr': inr,
      'qrText': qrText,
    });
    return ScanPayStart.fromJson(json);
  }

  /// Step 2: the card's signature over the first four bytes of the digest.
  Future<Map<String, dynamic>> cardSignature(String id, String cardSigHex) =>
      _send('POST', '/api/scanpay/$id/card', {'cardSig': cardSigHex});

  /// Step 3: the fingerprint. The relayer submits scanPay and this returns the lock.
  Future<Map<String, dynamic>> phoneSignature(
          String id, Map<String, dynamic> phoneSig) =>
      _send('POST', '/api/scanpay/$id/phone', {'phoneSig': phoneSig});

  /// Step 4: poll until GlobalPay pays the merchant. Never treat "locked" as paid.
  Future<Map<String, dynamic>> scanPayStatus(String id) =>
      _send('GET', '/api/scanpay/$id');

  // --- send to an address ---------------------------------------------------------------------

  Future<Map<String, dynamic>> startSend(
          {required String cardModulusHex,
          required String amount,
          required String to}) =>
      _send('POST', '/api/send/start',
          {'cardModulus': cardModulusHex, 'amount': amount, 'to': to});

  Future<Map<String, dynamic>> paymentStatus(String id) =>
      _send('GET', '/api/pay/$id');

  Future<Map<String, dynamic>> sendCardSignature(
          String id, String cardSigHex) =>
      _send('POST', '/api/pay/$id/card', {'cardSig': cardSigHex});

  Future<Map<String, dynamic>> sendPhoneSignature(
          String id, Map<String, dynamic> phoneSig) =>
      _send('POST', '/api/pay/$id/phone', {'phoneSig': phoneSig});

  /// Receiver-as-terminal flow: the receiver phone supplies its own wallet, then reads the sender's
  /// linked card. The request appears on the sender's registered phone for fingerprint approval.
  Future<Map<String, dynamic>> startP2pTap({
    required String cardModulusHex,
    required String amount,
    required String recipient,
  }) =>
      _send('POST', '/api/p2p/start', {
        'cardModulus': cardModulusHex,
        'amount': amount,
        'recipient': recipient,
      });

  Future<Map<String, dynamic>> rejectPayment(String id) =>
      _send('POST', '/api/pay/$id/reject');

  // --- first run -------------------------------------------------------------------------------

  /// Returns `{existing: true, wallet}` when this card is already linked to this phone.
  Future<Map<String, dynamic>> startSignup({
    required String cardModulusHex,
    required String cardExponentHex,
    required String phoneX,
    required String phoneY,
  }) =>
      _send('POST', '/api/signup/start', {
        'cardModulus': cardModulusHex,
        'cardExponent': cardExponentHex,
        'phoneX': phoneX,
        'phoneY': phoneY,
      });

  Future<Map<String, dynamic>> finishSignup(String id,
          {required String cardSigHex,
          required Map<String, dynamic> phoneSig}) =>
      _send('POST', '/api/signup/$id',
          {'cardSig': cardSigHex, 'phoneSig': phoneSig});

  // --- wallet changes that need the card and the fingerprint ----------------------------------

  /// [action] is one of: limits, soft, addCard.
  Future<Map<String, dynamic>> startAction({
    required String wallet,
    required String action,
    required Map<String, dynamic> params,
  }) =>
      _send('POST', '/api/action/start',
          {'wallet': wallet, 'action': action, 'params': params});

  /// Freeze and unfreeze take only the card (and, for unfreeze, the fingerprint).
  Future<Map<String, dynamic>> startFreezeChange(
          {required String wallet, required bool freeze}) =>
      _send('POST', freeze ? '/api/freeze/start' : '/api/unfreeze/start',
          {'wallet': wallet});

  /// Finish any of the above with the two signatures.
  Future<Map<String, dynamic>> finishAction(String id,
          {String? cardSig,
          String? cardModulus,
          required Map<String, dynamic> phoneSig,
          String? newCardSig}) =>
      _send('POST', '/api/action/$id', {
        if (cardSig != null) 'cardSig': cardSig,
        // Which card actually signed. Without it the relayer assumes this wallet's first card,
        // which is wrong once there is more than one.
        if (cardModulus != null) 'cardModulus': cardModulus,
        'phoneSig': phoneSig,
        if (newCardSig != null) 'newCardSig': newCardSig,
      });

  // --- the display name others see when you ask for money ---------------------------------------

  /// A label this service keeps for the wallet. It is not proof of identity: the sender still signs
  /// the full address, and the app says the name was registered rather than verified.
  Future<Map<String, dynamic>> setProfileName(
          {required String wallet, required String name}) =>
      _send('POST', '/api/profile', {'wallet': wallet, 'name': name});

  Future<Map<String, dynamic>> profileName(String wallet) =>
      _send('GET', '/api/profile/$wallet');

  // --- replacing a lost phone ------------------------------------------------------------------

  /// Taps one card to find the wallet, then proposes this phone as its new signer.
  /// Returns `{existing: true, wallet}` when this phone is already a signer.
  Future<Map<String, dynamic>> startRecovery({
    required String cardModulus,
    required String phoneX,
    required String phoneY,
  }) =>
      _send('POST', '/api/recover/start', {
        'cardModulus': cardModulus,
        'phoneX': phoneX,
        'phoneY': phoneY,
      });

  /// Two different cards approve the new phone, and the new phone signs the proposal hash.
  Future<Map<String, dynamic>> submitRecovery(String id,
          {required List<Map<String, String>> cards,
          required Map<String, dynamic> phoneSig}) =>
      _send('POST', '/api/recover/$id', {'cards': cards, 'phoneSig': phoneSig});

  /// Once the wallet's recovery delay has passed, anyone can execute the replacement.
  Future<Map<String, dynamic>> executeRecovery(String wallet) =>
      _send('POST', '/api/recover/finish', {'wallet': wallet});

  /// Start cancelling a pending lost-phone recovery. Only the current phone signs this.
  Future<Map<String, dynamic>> startCancelRecovery(String wallet) =>
      _send('POST', '/api/recovery-cancel/start', {'wallet': wallet});

  /// A phone alone can cancel a pending lost-phone recovery.
  Future<Map<String, dynamic>> cancelRecovery(String id,
          {required Map<String, dynamic> phoneSig}) =>
      _send('POST', '/api/recovery-cancel/$id', {'phoneSig': phoneSig});

  // --- add money (GlobalPay onramp) -------------------------------------------------------------

  /// Creates an onramp order: the user pays INR on Razorpay's page, GlobalPay sends the stablecoin.
  Future<Map<String, dynamic>> createOnramp({
    required String chain,
    required String wallet,
    required String inr,
  }) =>
      _sendTo(globalPayUrl, 'POST', '/onramp',
          {'chain': chain, 'wallet': wallet, 'inr': inr});

  /// Poll an onramp order until it is PAID (or EXPIRED).
  Future<Map<String, dynamic>> onrampStatus(String orderId) =>
      _sendTo(globalPayUrl, 'GET', '/onramp/$orderId');

  // --- NEAR hackathon MVP ----------------------------------------------------------------------

  Future<Map<String, dynamic>> nearConfig() =>
      _sendTo(globalPayUrl, 'GET', '/near/config');

  Future<Map<String, dynamic>> nearAccount(String accountId) => _sendTo(
      globalPayUrl, 'GET', '/near/account/${Uri.encodeComponent(accountId)}');

  Future<Map<String, dynamic>> nearQuote({
    required String accountId,
    required String inr,
    required String qrText,
  }) =>
      _sendTo(globalPayUrl, 'POST', '/near/quote', {
        'accountId': accountId,
        'inr': inr,
        'qrText': qrText,
      });

  Future<Map<String, dynamic>> trackNearPayment({
    required String id,
    required String accountId,
    required String txHash,
  }) =>
      _sendTo(globalPayUrl, 'POST', '/near/track', {
        'id': id,
        'accountId': accountId,
        'txHash': txHash,
      });

  Future<Map<String, dynamic>> nearPayment(String id, {String? viewToken}) =>
      _sendTo(
        globalPayUrl,
        'GET',
        '/near/payment/${Uri.encodeComponent(id)}',
        null,
        viewToken == null ? null : {'x-view-token': viewToken},
      );

  Future<List<Map<String, dynamic>>> nearHistory(String accountId) async {
    final json = await _sendTo(
      globalPayUrl,
      'GET',
      '/near/history/${Uri.encodeComponent(accountId)}?limit=50',
    );
    return ((json['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  // --- UPI payout detail and disputes ------------------------------------------------------------

  /// Everything about one UPI payment: escrow state, payout reference, dispute deadline.
  Future<Map<String, dynamic>> offramp(String id) =>
      _sendTo(globalPayUrl, 'GET', '/offramp/$id');

  /// This wallet's UPI payments, newest first. The rows carry the offramp id and payout state.
  Future<List<Map<String, dynamic>>> offramps(String wallet) async {
    final json =
        await _sendTo(globalPayUrl, 'GET', '/offramps?user=$wallet&limit=50');
    return ((json['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Step 1 of a dispute: the wallet's vault digest for this offramp, which the fingerprint signs.
  /// A dispute is phone-only on-chain: it can only return funds to this wallet.
  Future<Map<String, dynamic>> startDispute({
    required String wallet,
    required String offrampId,
  }) =>
      _send('POST', '/api/scanpay/dispute/start',
          {'wallet': wallet, 'offrampId': offrampId});

  /// Step 2: the fingerprint. The relayer calls the wallet's `dispute`.
  Future<Map<String, dynamic>> finishDispute(
          String id, Map<String, dynamic> phoneSig) =>
      _send('POST', '/api/scanpay/dispute/$id', {'phoneSig': phoneSig});
}

/// What /api/scanpay/start returns, with the intent parsed so the amount shown is the signed one.
class ScanPayStart {
  ScanPayStart({
    required this.id,
    required this.digest,
    required this.challenge,
    required this.wallet,
    required this.intent,
    required this.domain,
    required this.payeeName,
    required this.payeeUpi,
    required this.tokenSymbol,
    required this.expiresAt,
  });

  final String id;
  final String digest;
  final String challenge;
  final String wallet;
  final OfframpIntent intent;
  final VaultDomain domain;
  final String payeeName;
  final String payeeUpi;
  final String tokenSymbol;
  final int expiresAt;

  /// True when the digest the server handed us is the digest of the intent it also handed us.
  ///
  /// Without this the relayer could show one amount and have the phone sign another; the card signs
  /// blind, so nothing else on the phone can catch that.
  bool get verified => hexOf(intent.hash(domain)) == digest.toLowerCase();

  String get amountText => intent.tokenAmount;
  String get rupeeText => intent.rupees;

  factory ScanPayStart.fromJson(Map<String, dynamic> json) {
    final intentJson = json['intent'] as Map<String, dynamic>?;
    if (intentJson == null) {
      throw ApiError('The payment service did not return the signed intent.');
    }
    final payee = (json['payee'] as Map<String, dynamic>?) ?? const {};
    return ScanPayStart(
      id: json['id'] as String,
      digest: json['digest'] as String,
      challenge: json['challenge'] as String,
      wallet: json['wallet'] as String,
      intent: OfframpIntent.fromJson(intentJson),
      domain: VaultDomain.fromJson(json['domain'] as Map<String, dynamic>),
      payeeName: (payee['name'] ?? payee['upiId'] ?? 'UPI merchant').toString(),
      payeeUpi: (payee['upiId'] ?? '').toString(),
      tokenSymbol: (json['token'] ?? 'USDT').toString(),
      expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 +
          ((json['expiresIn'] as num?)?.toInt() ?? 90),
    );
  }
}
