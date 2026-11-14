// Send USDT to another address: same two-factor rule as a payment — the card signs, the fingerprint
// signs, and the wallet's on-chain limits apply.
import 'package:flutter/material.dart';

import '../api.dart';
import '../card.dart';
import '../phone_key.dart';
import '../ui.dart';
import 'scan_address.dart';

class SendScreen extends StatefulWidget {
  const SendScreen({super.key, required this.api});

  final Api api;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _to = TextEditingController();
  final _amount = TextEditingController();
  final _phone = PhoneKey();

  String _error = '';
  bool _busy = false;
  bool _manualAddress = false;

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// Reads the recipient's Receive code and fills the address, so a send is an amount plus two
  /// confirmations rather than a string nobody wants to type or check by eye.
  Future<void> _scanRecipient() async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanAddressScreen()),
    );
    if (address == null || !mounted) return;
    setState(() {
      _to.text = address;
      _manualAddress = false;
      _error = '';
    });
  }

  bool get _hasRecipient =>
      RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(_to.text.trim());

  Widget _recipient() {
    if (_hasRecipient && !_manualAddress) {
      return Panel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              const CircleAvatar(child: Icon(Icons.person_outline, size: 20)),
          title: const Text('Recipient ready'),
          subtitle: Text(shortAddress(_to.text.trim())),
          trailing: TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _to.clear();
                      _manualAddress = false;
                    }),
            child: const Text('Change'),
          ),
        ),
      );
    }

    if (_manualAddress) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _to,
            decoration: InputDecoration(
              labelText: 'Paste wallet address',
              hintText: '0x…',
              suffixIcon: IconButton(
                tooltip: 'Scan their Receive code',
                icon: const Icon(Icons.qr_code_scanner, size: 20),
                onPressed: _busy ? null : _scanRecipient,
              ),
            ),
            maxLines: 1,
            onChanged: (_) => setState(() => _error = ''),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _scanRecipient,
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: const Text('Scan instead'),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _scanRecipient,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan their Receive code'),
        ),
        const Fine(
            'Their wallet is filled automatically. No address to type or compare.',
            center: true),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _manualAddress = true),
          child: const Text('Paste an address instead'),
        ),
      ],
    );
  }

  Future<void> _send() async {
    final to = _to.text.trim();
    final amount = _amount.text.trim();
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(to)) {
      setState(() => _error = 'That does not look like a wallet address.');
      return;
    }
    final parsed = double.tryParse(amount);
    if (parsed == null || parsed <= 0) {
      setState(() => _error = 'Enter an amount.');
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      String? paymentId;
      String? hash;
      final tap = await CardReader().withCard(getChallenge: (card) async {
        final start = await widget.api
            .startSend(cardModulusHex: card.modulusHex, amount: amount, to: to);
        paymentId = start['id'] as String;
        hash = start['hash'] as String;
        return start['challenge'] as String;
      });
      if (paymentId == null || hash == null)
        throw const CardError('The request did not arrive.');
      if (tap.signature == null)
        throw const CardError('The card did not sign.');

      await widget.api.sendCardSignature(paymentId!, '0x${tap.signature}');

      final assertion = await _phone.sign(hash!,
          title: 'Send $amount', subtitle: 'to ${shortAddress(to)}');
      final done =
          await widget.api.sendPhoneSignature(paymentId!, assertion.toJson());

      if (mounted) {
        final failed = (done['status'] ?? '').toString() == 'failed';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failed
              ? ((done['error'] ?? 'The payment failed.').toString())
              : 'Sent $amount. Wallet balance updated.'),
        ));
        if (!failed) Navigator.of(context).maybePop();
      }
    } on CardError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const DisplayHeading('Who are you paying?', size: 24),
          const SizedBox(height: 14),
          _recipient(),
          const SizedBox(height: 20),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(labelText: 'Amount', suffixText: 'USDT'),
          ),
          if (_error.isNotEmpty) ErrorLine(_error),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.contactless),
            label: Text(_busy ? 'Waiting…' : 'Tap card, then fingerprint'),
          ),
          const SizedBox(height: 12),
          const Fine(
              'Sends are checked against your per-payment and daily limits on-chain, exactly like a card payment.'),
        ],
      ),
    );
  }
}
