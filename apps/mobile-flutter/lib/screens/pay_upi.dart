// Pay a UPI QR with a card tap and a fingerprint.
//
// The order matters: the card is read first, the quote comes from GlobalPay while the card is still
// on the phone, the card signs the first four bytes of the vault's digest, and only then does the
// fingerprint prompt appear showing the amount that digest actually locks.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api.dart';
import '../card.dart';
import '../phone_key.dart';
import '../ui.dart';

class PayUpiScreen extends StatefulWidget {
  const PayUpiScreen({super.key, required this.api, required this.onPaid});

  final Api api;
  final ValueChanged<String> onPaid;

  @override
  State<PayUpiScreen> createState() => _PayUpiScreenState();
}

enum _Stage { scan, amount, review, tap, sign, sending, done }

class _PayUpiScreenState extends State<PayUpiScreen> {
  final _amount = TextEditingController();
  final _phone = PhoneKey();

  _Stage _stage = _Stage.scan;
  String? _qr;
  String _payee = '';
  String _upiId = '';
  String _error = '';
  CardPhase _cardPhase = CardPhase.idle;
  ScanPayStart? _start;
  String _status = '';
  String _txHash = '';

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// UPI QR codes are `upi://pay?pa=<vpa>&pn=<name>&am=<amount>&cu=INR`. We only accept those,
  /// never a plain URL, so a random QR can't be mistaken for a payment request.
  void _onQr(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'upi') {
      setState(() => _error = 'That QR is not a UPI payment code.');
      return;
    }
    final q = uri.queryParameters;
    final pa = q['pa'];
    if (pa == null || pa.isEmpty) {
      setState(() => _error = 'This UPI QR has no payee.');
      return;
    }
    final am = q['am'];
    setState(() {
      _qr = raw.trim();
      _upiId = pa;
      _payee = (q['pn'] ?? pa).replaceAll('+', ' ').trim();
      _error = '';
      _amount.text =
          (am != null && am.isNotEmpty && double.tryParse(am) != null)
              ? am
              : '';
      _stage = _Stage.amount;
    });
  }

  Future<void> _toReview() async {
    final value = _amount.text.trim();
    final rupees =
        int.tryParse(value.contains('.') ? value.replaceAll('.', '') : value);
    if (rupees == null || rupees <= 0) {
      setState(() => _error = 'Enter the amount in rupees.');
      return;
    }
    setState(() {
      _error = '';
      _stage = _Stage.review;
    });
  }

  /// One tap does everything: read the card, fetch the quote, have the card sign, then ask for the
  /// fingerprint over the *quoted* amount.
  Future<void> _pay() async {
    setState(() {
      _stage = _Stage.tap;
      _error = '';
      _cardPhase = CardPhase.waiting;
    });
    try {
      final result = await CardReader(onPhase: (p) {
        if (mounted) setState(() => _cardPhase = p);
      }).withCard(
        getChallenge: (key) async {
          final s = await widget.api.startScanPay(
            cardModulusHex: key.modulusHex,
            inr: _amount.text.trim(),
            qrText: _qr!,
          );
          if (!s.verified) {
            // The server's digest doesn't match the intent it sent us. Never sign that.
            throw const CardError(
                'The payment service sent inconsistent details. Try again.');
          }
          if (mounted) setState(() => _start = s);
          return s.challenge;
        },
      );
      final s = _start;
      if (s == null)
        throw const CardError('The quote did not arrive. Try the tap again.');

      setState(() {
        _cardPhase = CardPhase.done;
        _stage = _Stage.sign;
      });

      await widget.api.cardSignature(s.id, '0x${result.signature}');

      final assertion = await _phone.sign(
        s.digest,
        title: 'Pay ₹${s.rupeeText}',
        subtitle: '${s.amountText} ${s.tokenSymbol} to ${s.payeeName}',
      );

      setState(() => _stage = _Stage.sending);
      final locked = await widget.api.phoneSignature(s.id, assertion.toJson());
      _txHash = (locked['txHash'] ?? '').toString();
      await _awaitPayout(s.id);
    } on CardError catch (e) {
      setState(() {
        _error = e.message;
        _stage = _Stage.review;
      });
    } on ApiError catch (e) {
      setState(() {
        _error = e.message;
        _stage = _Stage.review;
      });
    }
  }

  /// The lock is not a payment: the merchant is only paid once GlobalPay's settler completes it.
  Future<void> _awaitPayout(String id) async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final st = await widget.api.scanPayStatus(id);
        final payout = (st['payoutStatus'] ?? '').toString();
        final locked = (st['status'] ?? '').toString();
        if (mounted) {
          setState(() => _status =
              payout.isNotEmpty ? payout : 'Locked — paying the merchant…');
        }
        if (payout == 'COMPLETED') {
          if (mounted) setState(() => _stage = _Stage.done);
          widget.onPaid(id);
          return;
        }
        if (payout == 'FAILED') {
          if (mounted) {
            setState(() {
              _error =
                  'The payment was locked but the merchant could not be paid. It can be disputed from Activity.';
              _stage = _Stage.done;
            });
          }
          return;
        }
        if (locked == 'failed' || locked == 'expired') {
          if (mounted) {
            setState(() {
              _error =
                  'The payment did not go through. No money left your wallet.';
              _stage = _Stage.review;
            });
          }
          return;
        }
      } on ApiError {
        // Keep polling: a dropped poll says nothing about the payment itself.
      }
    }
    if (mounted) {
      setState(() {
        _status = 'Still settling. Check Activity in a moment.';
        _stage = _Stage.done;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pay a UPI QR')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.scan:
        return _scanner();
      case _Stage.amount:
        return _amountStep();
      case _Stage.review:
        return _reviewStep();
      case _Stage.tap:
      case _Stage.sign:
      case _Stage.sending:
        return _waitingStep();
      case _Stage.done:
        return _doneStep();
    }
  }

  Widget _scanner() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Text('Point the camera at a UPI QR code',
              textAlign: TextAlign.center),
        ),
        Expanded(
          child: MobileScanner(
            onDetect: (capture) {
              final raw = capture.barcodes.firstOrNull?.rawValue;
              if (raw != null && _stage == _Stage.scan) _onQr(raw);
            },
          ),
        ),
        if (_error.isNotEmpty) ErrorLine(_error),
      ],
    );
  }

  Widget _amountStep() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (_payee.isNotEmpty) PayeeCard(name: _payee, upi: _upiId),
        const SizedBox(height: 24),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: displayText(38, height: 1.15),
          decoration: InputDecoration(
            labelText: 'Amount in rupees',
            prefixText: '₹ ',
            prefixStyle: displayText(38, height: 1.15),
          ),
        ),
        const Fine(
            'The USDT you pay is fixed by GlobalPay\'s quote at the moment you tap your card.'),
        if (_error.isNotEmpty) ErrorLine(_error),
        const SizedBox(height: 24),
        FilledButton(onPressed: _toReview, child: const Text('Continue')),
      ],
    );
  }

  Widget _reviewStep() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PayeeCard(name: _payee, upi: _upiId),
        const SizedBox(height: 20),
        Panel(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            children: [
              KeyValueRow('You pay', '₹${_amount.text.trim()}', emphasis: true),
              if (_start != null) ...[
                const Divider(indent: 0, endIndent: 0),
                KeyValueRow(
                    'Quoted', '${_start!.amountText} ${_start!.tokenSymbol}'),
              ],
            ],
          ),
        ),
        if (_error.isNotEmpty) ErrorLine(_error),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: _pay,
          icon: const Icon(Icons.contactless, size: 20),
          label: const Text('Tap card, then fingerprint'),
        ),
        const Fine(
            'One tap reads your card, fetches GlobalPay\'s quote, then asks for your fingerprint over that amount.'),
      ],
    );
  }

  Widget _waitingStep() {
    final (title, hint) = switch ((_stage, _cardPhase)) {
      (_Stage.tap, CardPhase.waiting) => (
          'Hold your card to the back of the phone',
          'Keep it there until the phone buzzes'
        ),
      (_Stage.tap, CardPhase.detected) => (
          'Card found — keep it still',
          'Reading it now'
        ),
      (_Stage.tap, CardPhase.almost) => ('Almost done', 'Just a moment longer'),
      (_Stage.tap, _) => (
          'Tap your card',
          'Contactless, like a normal payment'
        ),
      (_Stage.sign, _) => (
          'Confirm with your fingerprint',
          _start == null ? '' : 'Paying ₹${_start!.rupeeText}'
        ),
      _ => ('Sending the payment', 'This takes a few seconds'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 28),
            Text(title, textAlign: TextAlign.center, style: displayText(24)),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(hint,
                  textAlign: TextAlign.center,
                  style: bodyText(15, color: Gp.inkSoft)),
            ],
            if (_stage == _Stage.sign && _start != null) ...[
              const SizedBox(height: 18),
              Text('${_start!.amountText} ${_start!.tokenSymbol}',
                  style: displayText(28, color: Gp.action)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _doneStep() {
    final failed = _error.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(failed ? Icons.error_outline : Icons.check_circle,
                size: 56, color: failed ? Gp.red : Gp.green),
            const SizedBox(height: 20),
            Text(
                failed
                    ? 'Money is locked, not paid'
                    : 'Paid ₹${_amount.text.trim()} to $_payee',
                textAlign: TextAlign.center,
                style: displayText(24)),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_status,
                  textAlign: TextAlign.center,
                  style: bodyText(15, color: Gp.inkSoft)),
            ],
            if (failed) ...[
              const SizedBox(height: 10),
              Text(_error,
                  textAlign: TextAlign.center,
                  style: bodyText(14, color: Gp.inkSoft)),
            ],
            if (_txHash.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(txShort(_txHash), style: bodyText(12, color: Gp.inkSoft)),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
