// Replacing a lost phone: the new phone asks to become a signer, two of the wallet's cards approve it,
// and the wallet only accepts the change after its recovery delay. In the meantime either side can
// cancel — the old phone from Wallet → Lost phone, or anyone with a card.
//
// No card number, PIN or seed phrase is involved: the cards prove they are the wallet's cards with
// the same 4-byte EMV challenge a payment uses, and this phone proves it holds a new P-256 key.
import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../card.dart';
import '../phone_key.dart';
import '../store.dart';
import '../ui.dart';

class RecoverScreen extends StatefulWidget {
  const RecoverScreen({super.key, required this.api, required this.onReady});

  final Api api;
  final ValueChanged<String> onReady;

  @override
  State<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends State<RecoverScreen> {
  final _phone = PhoneKey();

  String _error = '';
  String _status = '';
  bool _busy = false;

  String _wallet = '';
  String? _requestId;
  String? _hash;
  int _delay = 0;
  int _readyAt = 0;

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = '';
      _status = 'Reading this phone’s key';
    });
    try {
      final key = await _phone.create();
      setState(() => _status = 'Tap any card of your wallet');
      final tap = await CardReader().withCard(getChallenge: (k) async => null);

      setState(() => _status = 'Looking for your wallet');
      final start = await widget.api.startRecovery(
        cardModulus: tap.key.modulusHex,
        phoneX: key.x,
        phoneY: key.y,
      );

      if (start['existing'] == true) {
        // This phone is already a signer: no recovery is needed at all.
        final wallet = (start['wallet'] ?? '').toString();
        await WalletStore.setAddress(wallet);
        if (mounted) widget.onReady(wallet);
        return;
      }
      if (start['pending'] == true) {
        setState(() {
          _wallet = (start['wallet'] ?? '').toString();
          _readyAt = (start['readyAt'] as num?)?.toInt() ?? 0;
          _status = '';
        });
        return;
      }

      setState(() {
        _wallet = (start['wallet'] ?? '').toString();
        _requestId = (start['id'] ?? '').toString();
        _hash = (start['hash'] ?? '').toString();
        _delay = (start['delay'] as num?)?.toInt() ?? 0;
        _status = '';
      });
    } on CardError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Two different cards sign the same 4-byte challenge, then this phone signs the full hash.
  Future<void> _submit() async {
    final id = _requestId;
    final hash = _hash;
    if (id == null || hash == null) return;
    final challenge = hash.substring(2, 10);

    setState(() {
      _busy = true;
      _error = '';
      _status = 'Tap your two cards, one after the other';
    });
    try {
      final cards = <Map<String, String>>[];
      for (var i = 0; i < 2; i++) {
        setState(() => _status = 'Tap card ${i + 1} of 2');
        final tap =
            await CardReader().withCard(getChallenge: (k) async => challenge);
        if (tap.signature == null) {
          throw const CardError('That card did not sign.');
        }
        cards.add({
          'cardModulus': tap.key.modulusHex,
          'cardSig': '0x${tap.signature}',
        });
      }

      setState(() => _status = 'Confirm with your fingerprint');
      final assertion =
          await _phone.sign(hash, title: 'Replace the phone on this wallet');

      setState(() => _status = 'Sending');
      final done = await widget.api.submitRecovery(
        id,
        cards: cards,
        phoneSig: assertion.toJson(),
      );
      setState(() {
        _readyAt = (done['readyAt'] as num?)?.toInt() ?? 0;
        _requestId = null;
        _status = '';
      });
    } on CardError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Once the delay has passed, the replacement can be executed by anyone.
  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _error = '';
      _status = 'Finishing';
    });
    try {
      await widget.api.executeRecovery(_wallet);
      await WalletStore.setAddress(_wallet);
      if (mounted) widget.onReady(_wallet);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _waiting => _readyAt > 0;
  bool get _readyNow =>
      _waiting && _readyAt * 1000 <= DateTime.now().millisecondsSinceEpoch;

  String _when(int seconds) {
    if (seconds <= 0) return 'now';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final diff = d.difference(DateTime.now());
    if (diff.isNegative) return 'now';
    if (diff.inMinutes < 60) return 'in ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'in ${diff.inHours} h';
    return 'in ${diff.inDays} days';
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _requestId != null && _hash != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Replace my phone')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: [
          const DisplayHeading('A new phone, the same wallet'),
          const SizedBox(height: 8),
          const Lede(
              'Your wallet needs two of its cards and a delay before it trusts a new phone. That delay is what stops someone who only has your cards from taking the wallet today.'),
          const SizedBox(height: 20),
          const FactList(facts: [
            (
              'Two cards',
              ' both have to be tapped, and they must be different cards.'
            ),
            ('A delay', ' is enforced by the wallet, not by this app.'),
            (
              'Your old phone',
              ' can cancel the replacement while it waits, with only a fingerprint.'
            ),
          ]),
          const SizedBox(height: 20),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(_status, style: bodyText(14, color: Gp.inkSoft)),
              ]),
            ),
          if (_error.isNotEmpty) ErrorLine(_error),
          if (_wallet.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Wallet ${shortAddress(_wallet)}',
                style: bodyText(13, color: Gp.inkSoft)),
          ],
          const SizedBox(height: 20),
          if (!_waiting && !canSubmit)
            FilledButton(
              onPressed: _busy ? null : _start,
              child: const Text('Start: tap a card'),
            ),
          if (canSubmit) ...[
            Text(
                'This wallet waits ${_delay >= 86400 ? '${(_delay / 86400).round()} day(s)' : '${(_delay / 3600).round()} hour(s)'} before it trusts a new phone, so the replacement only takes effect after that.',
                style: bodyText(13, color: Gp.inkSoft)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: const Text('Tap two cards and confirm'),
            ),
          ],
          if (_waiting) ...[
            Panel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      _readyNow
                          ? 'The delay has passed. Finish the replacement to use this phone.'
                          : 'The replacement was proposed. The wallet accepts it ${_when(_readyAt)}.',
                      style: bodyText(15)),
                  if (_readyNow) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _busy ? null : _finish,
                      child: const Text('Finish and use this phone'),
                    ),
                  ],
                ],
              ),
            ),
            if (!_readyNow)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: OutlinedButton(
                  onPressed: _busy ? null : () => setState(() => _readyAt = 0),
                  child: const Text('Check again later'),
                ),
              ),
          ],
          const SizedBox(height: 24),
          const Fine(
              'If you still have the old phone, cancel the replacement there: Wallet → Lost phone. A replacement nobody finishes never changes the wallet.'),
        ],
      ),
    );
  }
}
