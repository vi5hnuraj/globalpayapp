// The receiver's phone becomes a GlobalPay terminal. It knows its own wallet address, reads the
// sender's linked bank card, and waits while the sender approves the bound amount + recipient on
// their registered phone. No wallet address is copied and the receiver never sees a card number.
import 'package:flutter/material.dart';

import '../api.dart';
import '../card.dart';
import '../ui.dart';

enum _Stage { amount, card, approval, paid }

class ReceiveTapScreen extends StatefulWidget {
  const ReceiveTapScreen({
    super.key,
    required this.api,
    required this.recipient,
    required this.symbol,
  });

  final Api api;
  final String recipient;
  final String symbol;

  @override
  State<ReceiveTapScreen> createState() => _ReceiveTapScreenState();
}

class _ReceiveTapScreenState extends State<ReceiveTapScreen> {
  final _amount = TextEditingController();
  _Stage _stage = _Stage.amount;
  CardPhase _cardPhase = CardPhase.idle;
  String _error = '';
  String _status = '';
  String _sender = '';

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final amount = _amount.text.trim();
    final value = double.tryParse(amount);
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter an amount above 0.');
      return;
    }

    setState(() {
      _stage = _Stage.card;
      _cardPhase = CardPhase.waiting;
      _status = 'Ask the sender to hold their linked card to this phone.';
      _error = '';
    });

    try {
      Map<String, dynamic>? request;
      final tap = await CardReader(onPhase: (phase) {
        if (!mounted) return;
        setState(() {
          _cardPhase = phase;
          if (phase == CardPhase.detected)
            _status = 'Card found. Keep it still…';
          if (phase == CardPhase.done)
            _status = 'Card approved. The sender must confirm on their phone.';
          if (phase == CardPhase.moved)
            _status = 'The card moved. Try the tap again.';
        });
      }).withCard(getChallenge: (card) async {
        request = await widget.api.startP2pTap(
          cardModulusHex: card.modulusHex,
          amount: amount,
          recipient: widget.recipient,
        );
        final returnedRecipient = (request!['recipient'] ?? '').toString();
        if (returnedRecipient.toLowerCase() != widget.recipient.toLowerCase()) {
          throw const CardError(
              'The payment service returned a different recipient. Nothing was signed.');
        }
        _sender = (request!['wallet'] ?? '').toString();
        return request!['challenge'] as String;
      });

      if (request == null || tap.signature == null)
        throw const CardError('The sender card did not sign.');
      final id = request!['id'] as String;
      await widget.api.sendCardSignature(id, '0x${tap.signature}');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.approval;
        _status = 'Waiting for the sender’s fingerprint…';
      });
      await _waitForApproval(id, (request!['expiry'] as num?)?.toInt());
    } on CardError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _stage = _Stage.amount;
        });
      }
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _stage = _Stage.amount;
        });
      }
    }
  }

  Future<void> _waitForApproval(String id, int? expiry) async {
    while (mounted) {
      if (expiry != null &&
          DateTime.now().millisecondsSinceEpoch ~/ 1000 > expiry + 2) {
        setState(() {
          _error = 'The request expired. Ask the sender to tap again.';
          _stage = _Stage.amount;
        });
        return;
      }
      try {
        final payment = await widget.api.paymentStatus(id);
        final status = (payment['status'] ?? '').toString();
        if (!mounted) return;
        if (status == 'paid') {
          setState(() {
            _stage = _Stage.paid;
            _status = 'Payment received.';
          });
          return;
        }
        if (const {'failed', 'rejected', 'superseded'}.contains(status)) {
          setState(() {
            _error = status == 'rejected'
                ? 'The sender declined this payment.'
                : (payment['error'] ?? 'The payment did not go through.')
                    .toString();
            _stage = _Stage.amount;
          });
          return;
        }
        setState(() => _status = status == 'submitting'
            ? 'Fingerprint approved. Recording the payment…'
            : 'Waiting for the sender’s fingerprint…');
      } on ApiError {
        // A dropped status poll says nothing about a payment. Retry until its signed expiry.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive by card tap')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_stage == _Stage.paid) ...[
              const SizedBox(height: 48),
              const Icon(Icons.check_circle, size: 76, color: Gp.green),
              const SizedBox(height: 20),
              Center(
                  child: DisplayHeading(
                      '${_amount.text.trim()} ${widget.symbol}',
                      size: 40)),
              const SizedBox(height: 8),
              const Center(
                  child: Lede('Received from the sender’s card wallet.')),
              if (_sender.isNotEmpty) Fine(shortAddress(_sender), center: true),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Done'),
              ),
            ] else ...[
              const DisplayHeading('No address to type', size: 28),
              const SizedBox(height: 8),
              const Lede(
                  'Enter the amount, then the sender taps their linked bank card on this phone.'),
              const SizedBox(height: 22),
              TextField(
                controller: _amount,
                enabled: _stage == _Stage.amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Amount', suffixText: widget.symbol),
              ),
              if (_error.isNotEmpty) ErrorLine(_error),
              const SizedBox(height: 22),
              if (_stage == _Stage.amount)
                FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.contactless),
                  label: const Text('Wait for sender’s card'),
                )
              else
                Panel(
                  child: Column(
                    children: [
                      Icon(
                          _stage == _Stage.card
                              ? Icons.contactless
                              : Icons.fingerprint,
                          size: 42),
                      const SizedBox(height: 12),
                      Text(_status,
                          textAlign: TextAlign.center, style: bodyText(17)),
                      if (_sender.isNotEmpty)
                        Fine('Sender ${shortAddress(_sender)}', center: true),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              const Fine(
                'The sender’s own phone shows this amount and your wallet before asking for their fingerprint.',
                center: true,
              ),
              if (_stage == _Stage.card && _cardPhase == CardPhase.waiting)
                const Fine('Hold the card flat against the NFC area.',
                    center: true),
            ],
          ],
        ),
      ),
    );
  }
}
