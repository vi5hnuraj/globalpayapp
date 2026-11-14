// A card was tapped on another phone/terminal. The card half is already signed; this sheet shows the
// exact amount and bound destination on the card owner's registered phone before it asks for the
// second factor. A model, merchant or receiving phone cannot approve this sheet.
import 'package:flutter/material.dart';

import '../api.dart';
import '../phone_key.dart';
import '../ui.dart';

class PaymentApprovalSheet extends StatefulWidget {
  const PaymentApprovalSheet(
      {super.key, required this.api, required this.payment});

  final Api api;
  final Map<String, dynamic> payment;

  @override
  State<PaymentApprovalSheet> createState() => _PaymentApprovalSheetState();
}

class _PaymentApprovalSheetState extends State<PaymentApprovalSheet> {
  bool _busy = false;
  String _error = '';

  Future<void> _approve() async {
    final payment = widget.payment;
    final hash = (payment['hash'] ?? '').toString();
    final id = (payment['id'] ?? '').toString();
    final amount = (payment['amount'] ?? '').toString();
    final symbol = (payment['symbol'] ?? 'USDT').toString();
    final destination = (payment['to'] ?? payment['merchant'] ?? '').toString();
    if (!RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(hash) || id.isEmpty) {
      setState(() => _error =
          'This approval request is incomplete. Decline it and ask for another tap.');
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final signature = await PhoneKey().sign(
        hash,
        title: 'Pay $amount $symbol',
        subtitle: destination.isEmpty
            ? 'Card payment'
            : 'to ${shortAddress(destination)}',
      );
      final result =
          await widget.api.sendPhoneSignature(id, signature.toJson());
      final status = (result['status'] ?? '').toString();
      if (status != 'paid')
        throw ApiError(
            (result['error'] ?? 'The payment did not go through.').toString());
      if (mounted) Navigator.of(context).pop('paid');
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted && !e.toString().toLowerCase().contains('cancel')) {
        setState(() => _error =
            'Fingerprint approval did not complete. Try again or decline.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.api.rejectPayment((widget.payment['id'] ?? '').toString());
      if (mounted) Navigator.of(context).pop('declined');
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payment = widget.payment;
    final amount = (payment['amount'] ?? '').toString();
    final symbol = (payment['symbol'] ?? 'USDT').toString();
    final name = (payment['merchantName'] ?? 'Card payment').toString();
    final destination = (payment['to'] ?? payment['merchant'] ?? '').toString();
    final p2p = payment['kind'] == 'p2p';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p2p ? 'Your card was tapped' : 'Card payment request',
                style: displayText(26)),
            const SizedBox(height: 6),
            Text(
                p2p
                    ? (name.startsWith('GlobalPay wallet')
                        ? 'Another GlobalPay phone is waiting.'
                        : 'A name GlobalPay registered for this wallet')
                    : name,
                style: bodyText(16, color: Gp.inkSoft)),
            const SizedBox(height: 22),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Fine('YOU PAY'),
                  Text('$amount $symbol', style: displayText(38)),
                  const Divider(height: 28),
                  Text(name, style: bodyText(15, weight: FontWeight.w700)),
                  Text(p2p ? 'Recipient wallet' : 'Payment to',
                      style: bodyText(12, color: Gp.inkSoft)),
                  if (destination.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    SelectableText(destination,
                        style: bodyText(12, color: Gp.inkSoft)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Fine(
                'Approve only if you just tapped your card. Your fingerprint signs this exact amount and recipient.'),
            if (_error.isNotEmpty) ErrorLine(_error),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _busy ? null : _approve,
              icon: const Icon(Icons.fingerprint),
              label: Text(_busy ? 'Waiting…' : 'Confirm with fingerprint'),
            ),
            TextButton(
              onPressed: _busy ? null : _decline,
              child: const Text('Decline'),
            ),
          ],
        ),
      ),
    );
  }
}
