// First run: make the phone's key, then link it to a bank card as a new wallet.
//
// The wallet is created in one transaction on the relayer's factory; the card and the phone both
// sign the factory's create hash, so neither alone can create or later change this wallet.
import 'package:flutter/material.dart';

import '../api.dart';
import '../card.dart';
import '../phone_key.dart';
import '../store.dart';
import '../ui.dart';
import 'recover.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen(
      {super.key, required this.api, required this.onReady, this.message = ''});

  final Api api;
  final ValueChanged<String> onReady;
  final String message;

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _phone = PhoneKey();
  String _error = '';
  bool _busy = false;
  CardPhase _phase = CardPhase.idle;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = '';
      _phase = CardPhase.waiting;
    });
    try {
      final key = await _phone.create();

      final tap = await CardReader(onPhase: (p) {
        if (mounted) setState(() => _phase = p);
      }).withCard(
        getChallenge: (card) async {
          final start = await widget.api.startSignup(
            cardModulusHex: card.modulusHex,
            cardExponentHex: card.exponentHex,
            phoneX: key.x,
            phoneY: key.y,
          );
          // The card is already linked to this phone: nothing to create, just open it.
          if (start['existing'] == true) {
            final wallet = (start['wallet'] as String?) ?? '';
            await WalletStore.setAddress(wallet);
            if (mounted) widget.onReady(wallet);
            return null;
          }
          _signupId = start['id'] as String;
          _signupHash = start['hash'] as String;
          return start['challenge'] as String;
        },
      );

      final id = _signupId;
      final hash = _signupHash;
      if (id == null || hash == null)
        return; // the existing-wallet path already finished
      if (tap.signature == null)
        throw const CardError('The card did not sign.');

      final assertion = await _phone.sign(hash,
          title: 'Create your wallet',
          subtitle: 'Card ending ${_last4(tap.key.modulusHex)}');
      final done = await widget.api.finishSignup(
        id,
        cardSigHex: '0x${tap.signature}',
        phoneSig: assertion.toJson(),
      );
      final wallet = (done['wallet'] as String?) ?? '';
      if (wallet.isEmpty)
        throw ApiError('The wallet was not created. Try again.');

      await WalletStore.setAddress(wallet);
      if (mounted) widget.onReady(wallet);
    } on CardError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = CardPhase.idle;
        });
      }
    }
  }

  String? _signupId;
  String? _signupHash;

  /// The card number never leaves the phone, so even this is only derived from the public key.
  String _last4(String modulusHex) => modulusHex.length < 4
      ? '••••'
      : modulusHex.substring(modulusHex.length - 4);

  @override
  Widget build(BuildContext context) {
    final (title, hint) = switch (_phase) {
      CardPhase.waiting => (
          'Hold your card to the back of the phone',
          'Keep it there until the phone buzzes'
        ),
      CardPhase.detected => ('Card found — keep it still', 'Reading it now'),
      CardPhase.almost => ('Almost done', 'Just a moment longer'),
      CardPhase.done => ('Card read', 'Confirm with your fingerprint'),
      CardPhase.moved => ('The card moved', 'Hold it flat against the phone'),
      _ => (
          'Your card is your wallet',
          'Your card and your fingerprint together are the wallet. No seed phrase, nothing to write down.'
        ),
    };
    final idle = _phase == CardPhase.idle;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (idle) ...[
                const HeroArt(),
                const SizedBox(height: 26),
              ],
              Text(title, style: displayText(28)),
              const SizedBox(height: 10),
              Text(hint, style: bodyText(17, color: Gp.inkSoft)),
              if (!idle) ...[
                const SizedBox(height: 18),
                StatusSpinner(
                    label: _busy ? 'Waiting for your card' : 'Getting ready'),
              ],
              if (idle) ...[
                const SizedBox(height: 22),
                const FactList(facts: [
                  (
                    'Tap your card',
                    ' to the back of the phone to start a payment.'
                  ),
                  (
                    'Confirm with your fingerprint',
                    ' on this phone to send it.'
                  ),
                  (
                    'Neither works alone. ',
                    'A lost card or a lost phone can\'t spend your money.'
                  ),
                ]),
              ],
              if (widget.message.isNotEmpty) ErrorLine(widget.message),
              if (_error.isNotEmpty) ErrorLine(_error),
              const SizedBox(height: 26),
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.contactless, size: 20),
                label:
                    Text(_busy ? 'Waiting for the card…' : 'Tap card to start'),
              ),
              const Fine(
                'Your card number and PIN never leave the phone. The wallet can spend only within the limits you set.',
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => RecoverScreen(
                              api: widget.api, onReady: widget.onReady),
                        )),
                icon: const Icon(Icons.phone_iphone, size: 18),
                label: const Text('I lost my phone'),
              ),
              const Fine(
                  'Replaces the registered phone on an existing wallet. It needs two of the wallet\'s cards and the wallet\'s recovery delay.'),
            ],
          ),
        ),
      ),
    );
  }
}
