// The wallet's own rules: what it may spend per payment and per day, whether tiny payments need only
// the card, which cards can spend, and the lost-phone recovery state.
//
// Everything here is an onchain action, so each change is one card tap plus one fingerprint — the
// same two factors as a payment. Nothing on this screen can be done by one factor alone.
import 'package:flutter/material.dart';

import '../api.dart';
import '../card.dart';
import '../phone_key.dart';
import '../ui.dart';
import 'add_money.dart';

class WalletSettingsScreen extends StatefulWidget {
  const WalletSettingsScreen(
      {super.key,
      required this.api,
      required this.view,
      required this.onChanged});

  final Api api;
  final Map<String, dynamic> view;
  final Future<void> Function() onChanged;

  @override
  State<WalletSettingsScreen> createState() => _WalletSettingsScreenState();
}

class _WalletSettingsScreenState extends State<WalletSettingsScreen> {
  late final _perTx =
      TextEditingController(text: (widget.view['perTxLimit'] ?? '').toString());
  late final _daily =
      TextEditingController(text: (widget.view['dailyLimit'] ?? '').toString());
  final _softAmount = TextEditingController();
  final _displayName = TextEditingController();
  final _phone = PhoneKey();

  bool _busy = false;
  String _error = '';
  String _status = '';
  bool _cardOnly = false;

  Map<String, dynamic> get _wallet => widget.view;
  String get _address => (_wallet['wallet'] ?? '').toString();
  String get _symbol =>
      ((_wallet['net'] as Map?)?['symbol'] ?? 'USDT').toString();
  bool get _frozen => _wallet['frozen'] == true;
  Map? get _recovery => _wallet['phoneRecovery'] as Map?;
  bool get _recoveryPending => _recovery?['pending'] == true;

  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    if (_address.isEmpty) return;
    try {
      final profile = await widget.api.profileName(_address);
      final name = (profile['name'] ?? '').toString();
      if (mounted && name.isNotEmpty) _displayName.text = name;
    } on ApiError {
      // A name is optional; not having one is not an error the screen should shout about.
    }
  }

  Future<void> _saveName() async {
    final name = _displayName.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter the name others should see.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _status = 'Saving your name';
    });
    try {
      await widget.api.setProfileName(wallet: _address, name: name);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name saved.')));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  @override
  void dispose() {
    _perTx.dispose();
    _daily.dispose();
    _softAmount.dispose();
    _displayName.dispose();
    super.dispose();
  }

  /// One action: start it, tap the card, confirm with the fingerprint, finish it.
  Future<void> _runAction({
    required String action,
    required Map<String, dynamic> params,
    required String title,
    bool needsCard = true,
    bool phoneOnly = false,
    String? Function()? newCardSig,
  }) async {
    setState(() {
      _busy = true;
      _error = '';
      _status = 'Starting…';
    });
    try {
      final Map<String, dynamic> start;
      if (phoneOnly) {
        start = await widget.api.startCancelRecovery(_address);
      } else {
        start = await widget.api
            .startAction(wallet: _address, action: action, params: params);
      }
      final hash = (start['hash'] as String?) ?? '';
      if (hash.isEmpty) throw ApiError('The service did not return a digest.');

      String? cardSig;
      String? cardModulus;
      if (needsCard) {
        setState(() => _status = 'Tap your card');
        final tap = await CardReader()
            .withCard(getChallenge: (key) async => hash.substring(2, 10));
        if (tap.signature == null) {
          throw const CardError('The card did not sign.');
        }
        cardSig = '0x${tap.signature}';
        cardModulus = tap.key.modulusHex;
      }

      final assertion = await _phone.sign(hash, title: title);

      setState(() => _status = 'Saving…');
      await widget.api.finishAction(
        start['id'] as String,
        cardSig: cardSig,
        cardModulus: cardModulus,
        phoneSig: assertion.toJson(),
        newCardSig: newCardSig?.call(),
      );
      await widget.onChanged();
      if (!mounted) return;
      setState(() => _status = '');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$title: done.')));
    } on CardError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveLimits() async {
    final perTx = _perTx.text.trim();
    final daily = _daily.text.trim();
    final p = double.tryParse(perTx);
    final d = double.tryParse(daily);
    if (p == null || p <= 0 || d == null || d <= 0) {
      setState(() => _error = 'Enter a per-payment and a daily limit above 0.');
      return;
    }
    if (p > d) {
      setState(() =>
          _error = 'The per-payment limit cannot exceed the daily limit.');
      return;
    }
    await _runAction(
      action: 'limits',
      params: {'perTx': perTx, 'daily': daily},
      title: 'Save spending limits',
    );
  }

  Future<void> _saveSoft() async {
    final amount = _softAmount.text.trim();
    if (amount.isNotEmpty && (double.tryParse(amount) ?? 0) <= 0) {
      setState(() => _error = 'Enter an amount above 0, or 0 to turn it off.');
      return;
    }
    await _runAction(
      action: 'soft',
      params: {'amount': amount.isEmpty ? '0' : amount, 'cardOnly': _cardOnly},
      title: 'Save small-payment rule',
    );
  }

  /// A second card needs three taps: read the new card's public key (the action commits to it),
  /// then have the current card approve and the new card prove it exists, then the fingerprint.
  Future<void> _addCard() async {
    setState(() {
      _busy = true;
      _error = '';
      _status = 'Tap the card you want to add';
    });
    try {
      final added =
          await CardReader().withCard(getChallenge: (key) async => null);

      setState(() => _status = 'Starting…');
      final start = await widget.api
          .startAction(wallet: _address, action: 'addCard', params: {
        'cardModulus': added.key.modulusHex,
        'cardExponent': added.key.exponentHex,
        'name': 'Added card',
      });
      final hash = (start['hash'] as String?) ?? '';
      if (hash.isEmpty) throw ApiError('The service did not return a digest.');
      final challenge = hash.substring(2, 10);

      setState(() => _status = 'Tap your current card to approve');
      final currentTap =
          await CardReader().withCard(getChallenge: (key) async => challenge);
      if (currentTap.signature == null) {
        throw const CardError('The current card did not sign.');
      }

      setState(() => _status = 'Tap the new card again to prove it');
      final addedTap =
          await CardReader().withCard(getChallenge: (key) async => challenge);
      if (addedTap.signature == null) {
        throw const CardError('The new card did not sign.');
      }

      setState(() => _status = 'Confirm with your fingerprint');
      final assertion = await _phone.sign(hash, title: 'Add a second card');
      await widget.api.finishAction(
        start['id'] as String,
        cardSig: '0x${currentTap.signature}',
        cardModulus: currentTap.key.modulusHex,
        phoneSig: assertion.toJson(),
        newCardSig: '0x${addedTap.signature}',
      );
      await widget.onChanged();
      if (!mounted) return;
      setState(() => _status = '');
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Card added to this wallet.')));
    } on CardError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Revoke a card. A remaining card approves it and the phone confirms, so revoking a lost card
  /// never needs the lost card. The contract refuses to fall below the wallet's threshold.
  Future<void> _revokeCard(Map card) async {
    final cards = (_wallet['cards'] as List?) ?? const [];
    if (cards.length <= 1) {
      setState(() => _error =
          'This is the wallet\'s only card. Add another card before revoking it, or the wallet would have nothing left to sign with.');
      return;
    }
    final name = (card['name'] ?? 'this card').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Revoke $name?'),
        content: const Text(
            'That card will stop being able to approve payments. You will tap a remaining card '
            'and then your fingerprint. A card you still have cannot be re-added on its own; '
            'it has to be added again from this screen.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _runAction(
      action: 'removeCard',
      params: {'signerId': card['id']},
      title: 'Revoke a card',
    );
  }

  Future<void> _cancelRecovery() async {
    setState(() {
      _busy = true;
      _error = '';
      _status = 'Starting…';
    });
    try {
      final start = await widget.api.startCancelRecovery(_address);
      final hash = (start['hash'] as String?) ?? '';
      if (hash.isEmpty) throw ApiError('The service did not return a digest.');
      final assertion =
          await _phone.sign(hash, title: 'Cancel the phone replacement');
      await widget.api
          .cancelRecovery(start['id'] as String, phoneSig: assertion.toJson());
      await widget.onChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Phone replacement cancelled.')));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  Future<void> _addMoney() async {
    final chain = ((_wallet['net'] as Map?)?['network'] ?? '').toString();
    if (chain.isEmpty) {
      setState(
          () => _error = 'The network is unknown; cannot create an order.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AddMoneyScreen(
          api: widget.api, wallet: _address, chain: chain, symbol: _symbol),
    ));
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cards = (_wallet['cards'] as List?) ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
        children: [
          if (_error.isNotEmpty) ErrorLine(_error),
          if (_status.isNotEmpty && _busy)
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
          Panel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('Money', style: displayText(18)),
                  const Spacer(),
                  StateTag(_frozen ? 'Frozen' : 'Active', frozen: _frozen),
                ]),
                const SizedBox(height: 8),
                Text(
                    '${_wallet['balance'] ?? '0'} $_symbol · ${_wallet['spentToday'] ?? '0'} spent today',
                    style: bodyText(14, color: Gp.inkSoft)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _addMoney,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add money'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const SectionTitle('Your name'),
          TextField(
            controller: _displayName,
            enabled: !_busy,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Shown when you ask for money',
                helperText:
                    'Registered with GlobalPay, not a verified identity'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _saveName,
            child: const Text('Save name'),
          ),
          const SizedBox(height: 22),
          const SectionTitle('Spending limits'),
          TextField(
            controller: _perTx,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'Most per payment',
                suffixText: _symbol,
                helperText: 'The wall the contract enforces on every payment'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _daily,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                InputDecoration(labelText: 'Most per day', suffixText: _symbol),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _saveLimits,
            child: const Text('Save limits'),
          ),
          const SizedBox(height: 26),
          const SectionTitle('Small payments'),
          TextField(
            controller: _softAmount,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'Card-only limit',
                suffixText: _symbol,
                helperText: 'Up to this amount, one card tap is enough'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _cardOnly,
            onChanged: _busy ? null : (v) => setState(() => _cardOnly = v),
            title: const Text('Allow card-only payments under this amount'),
            subtitle: Text('Turn off to require the fingerprint every time',
                style: bodyText(13, color: Gp.inkSoft)),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _saveSoft,
            child: const Text('Save small-payment rule'),
          ),
          const SizedBox(height: 26),
          const SectionTitle('Cards'),
          Panel(
            child: Column(children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.credit_card, size: 20),
                  title: Text(((cards[i] as Map)['name'] ?? 'Card').toString()),
                  subtitle: const Text('A signer on this wallet'),
                  trailing: cards.length > 1
                      ? TextButton(
                          onPressed:
                              _busy ? null : () => _revokeCard(cards[i] as Map),
                          child: const Text('Revoke'),
                        )
                      : null,
                ),
              ],
              if (cards.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No cards listed.',
                      style: bodyText(14, color: Gp.inkSoft)),
                ),
            ]),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _addCard,
            icon: const Icon(Icons.add_card, size: 18),
            label: const Text('Add a second card'),
          ),
          const Fine(
              'You will tap the new card, your current card, the new card again, then your fingerprint.'),
          const SizedBox(height: 26),
          const SectionTitle('Lost phone'),
          Panel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    _recoveryPending
                        ? 'A replacement phone is waiting out its delay. If this was not you, cancel it now.'
                        : 'No phone replacement is pending. Two cards start one if this phone is ever lost.',
                    style: bodyText(14, color: Gp.inkSoft)),
                if (_recoveryPending) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: dangerOutlineStyle(),
                    onPressed: _busy ? null : _cancelRecovery,
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: const Text('Cancel phone replacement'),
                  ),
                  const Fine(
                      'Only this phone can cancel it, with your fingerprint.'),
                ],
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text('Wallet ${shortAddress(_address)}',
              style: bodyText(12, color: Gp.inkSoft)),
        ],
      ),
    );
  }
}
