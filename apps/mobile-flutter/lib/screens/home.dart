// The wallet's home: the card, the balance, what it is allowed to spend, and what it has paid.
// Every number here comes from the relayer's read of the chain, not from local state.
// The layout follows the GlobalPay PWA's home: brand and state pill, card, balance, meter, activity.
import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../card.dart';
import '../phone_key.dart';
import '../store.dart';
import '../ui.dart';
import 'pay_upi.dart';
import 'payment_approval.dart';
import 'receive.dart';
import 'send.dart';
import 'upi_payments.dart';
import 'wallet_settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key, required this.api, required this.onCreateWallet});

  final Api api;
  final ValueChanged<String> onCreateWallet;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Map<String, dynamic>? _view;
  String _error = '';
  bool _busy = false;
  String _symbol = 'USDT';
  String _network = '';
  Timer? _pollTimer;
  bool _loadingView = false;
  String? _approvalId;
  final Set<String> _handledApprovals = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
      _startPolling();
    } else {
      _pollTimer?.cancel();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  Future<void> _load() async {
    if (_loadingView) return;
    _loadingView = true;
    final address = await WalletStore.address();
    if (address == null) {
      _loadingView = false;
      return;
    }
    try {
      final view = await widget.api.wallet(address);
      if (!mounted) return;
      setState(() {
        _view = view;
        _symbol = ((view['net'] as Map?)?['symbol'] ?? 'USDT').toString();
        _network = ((view['net'] as Map?)?['network'] ?? '').toString();
        _error = '';
      });
      final pending = (view['pending'] as List?)
          ?.whereType<Map>()
          .cast<Map<String, dynamic>>();
      if (pending != null) {
        for (final payment in pending) {
          final id = (payment['id'] ?? '').toString();
          if (id.isNotEmpty &&
              id != _approvalId &&
              !_handledApprovals.contains(id)) {
            _approvalId = id;
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _showApproval(payment));
            break;
          }
        }
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      _loadingView = false;
    }
  }

  Future<void> _showApproval(Map<String, dynamic> payment) async {
    if (!mounted) return;
    final id = (payment['id'] ?? '').toString();
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => PaymentApprovalSheet(api: widget.api, payment: payment),
    );
    _handledApprovals.add(id);
    _approvalId = null;
    if (!mounted) return;
    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result == 'paid'
            ? 'Payment sent. Wallet balance updated.'
            : 'Payment declined.'),
      ));
    }
    await _load();
  }

  Future<void> _go(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    await _load();
  }

  Future<void> _toggleFreeze(bool freeze) async {
    final address = await WalletStore.address();
    if (address == null) return;
    setState(() => _busy = true);
    try {
      final start =
          await widget.api.startFreezeChange(wallet: address, freeze: freeze);
      final hash = (start['hash'] as String?) ?? '';
      final challenge = (start['challenge'] as String?) ?? '';

      final tap =
          await CardReader().withCard(getChallenge: (key) async => challenge);
      if (tap.signature == null)
        throw const CardError('The card did not sign.');

      final phone = PhoneKey();
      final assertion = await phone.sign(hash,
          title: freeze ? 'Freeze your wallet' : 'Unfreeze your wallet');

      await widget.api.finishAction(
        start['id'] as String,
        cardSig: '0x${tap.signature}',
        phoneSig: assertion.toJson(),
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(freeze
                  ? 'Wallet frozen. Nothing can be paid until you unfreeze it.'
                  : 'Wallet unfrozen.')),
        );
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
    final view = _view;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
          children: [
            if (_error.isNotEmpty) ErrorLine(_error),
            if (view == null)
              const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(child: CircularProgressIndicator()))
            else ...[
              _header(view),
              const SizedBox(height: 4),
              _card(view),
              _balance(view),
              const SizedBox(height: 20),
              _limits(view),
              const SizedBox(height: 26),
              _actions(view),
              const SizedBox(height: 26),
              _history(view),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(Map<String, dynamic> view) {
    final frozen = view['frozen'] == true;
    return Row(
      children: [
        Text('GlobalPay', style: displayText(20)),
        const SizedBox(width: 10),
        StateTag(frozen ? 'Frozen' : 'Active', frozen: frozen),
        const Spacer(),
        IconButton(
            onPressed: () => _go(WalletSettingsScreen(
                api: widget.api, view: view, onChanged: _load)),
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: 'Wallet settings'),
        IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Refresh'),
      ],
    );
  }

  Widget _card(Map<String, dynamic> view) => WalletCard(
        label: 'Linked bank card',
        address: (view['wallet'] ?? '').toString(),
        frozen: view['frozen'] == true,
      );

  Widget _balance(Map<String, dynamic> view) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${view['balance'] ?? '0'}',
                  style: displayText(46, height: 1)),
              const SizedBox(width: 8),
              Text(_symbol,
                  style:
                      bodyText(17, weight: FontWeight.w600, color: Gp.inkSoft)),
            ],
          ),
          // A balance on a throwaway chain must never look like a real one. The relayer reports which
          // network it is on, so say it on the same screen as the number.
          if (_network == 'local') ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                border: Border.all(color: Gp.line),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('$_symbol on a local test chain — not real money',
                  style: bodyText(12, color: Gp.inkSoft)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _limits(Map<String, dynamic> view) {
    final spent = double.tryParse((view['spentToday'] ?? '0').toString()) ?? 0;
    final daily = double.tryParse((view['dailyLimit'] ?? '0').toString()) ?? 0;
    final ratio = daily <= 0 ? 0.0 : (spent / daily).clamp(0.0, 1.0);
    final perTx = view['perTxLimit'] ?? '0';
    return MeterBar(
      value: ratio,
      label:
          '${view['spentToday']} of ${view['dailyLimit']} $_symbol spent today · up to $perTx $_symbol per payment',
    );
  }

  Widget _actions(Map<String, dynamic> view) {
    final frozen = view['frozen'] == true;
    return Column(
      children: [
        FilledButton.icon(
          onPressed: () =>
              _go(PayUpiScreen(api: widget.api, onPaid: (_) => _load())),
          icon: const Icon(Icons.qr_code_scanner, size: 20),
          label: const Text('Pay UPI QR'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _go(SendScreen(api: widget.api)),
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: const Text('Send'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _go(ReceiveScreen(
                  address: (view['wallet'] ?? '').toString(),
                  api: widget.api,
                  symbol: _symbol,
                )),
                icon: const Icon(Icons.arrow_downward, size: 18),
                label: const Text('Receive'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _go(WalletSettingsScreen(
                    api: widget.api, view: view, onChanged: _load)),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add money'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _go(UpiPaymentsScreen(
                    api: widget.api,
                    wallet: (view['wallet'] ?? '').toString())),
                icon: const Icon(Icons.receipt_long, size: 18),
                label: const Text('UPI payments'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          style: dangerOutlineStyle(),
          onPressed: _busy ? null : () => _toggleFreeze(!frozen),
          icon: Icon(frozen ? Icons.lock_open : Icons.lock_outline, size: 18),
          label: Text(frozen ? 'Unfreeze wallet' : 'Freeze wallet'),
        ),
        if (frozen)
          const Fine(
              'Payments are blocked. To unfreeze you\'ll need both this phone and your card.'),
        TextButton(
          style: linkButtonStyle(),
          onPressed: () async {
            await WalletStore.clear();
            widget.onCreateWallet('');
          },
          child: const Text('Remove wallet from this phone'),
        ),
      ],
    );
  }

  Widget _history(Map<String, dynamic> view) {
    final items = (view['history'] as List?) ?? const [];
    final cards = (view['cards'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cards.isNotEmpty) ...[
          const SectionTitle('Your cards'),
          Panel(
            child: Column(
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.credit_card, size: 20),
                    title:
                        Text(((cards[i] as Map)['name'] ?? 'Card').toString()),
                    subtitle:
                        const Text('Touch to pay, limit-checked on-chain'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        const SectionTitle('Activity'),
        Panel(
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                      'Nothing yet. Tap your card at a terminal or pay a UPI QR to start.',
                      style: bodyText(14, color: Gp.inkSoft)),
                )
              : Column(
                  children: [
                    for (var i = 0; i < items.length && i < 12; i++) ...[
                      if (i > 0) const Divider(indent: 16, endIndent: 16),
                      _activityRow(items[i] as Map),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _activityRow(Map item) {
    final failed = (item['status'] ?? '').toString() == 'failed';
    final to = (item['to'] ?? item['recipient'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.check_circle_outline,
            size: 20,
            color: failed ? Gp.red : Gp.green,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    [
                      (item['kind'] ?? 'payment').toString(),
                      if (to.isNotEmpty) shortAddress(to)
                    ].join(' · '),
                    style: bodyText(15, weight: FontWeight.w600, height: 1.3)),
                Text(_ago(item['time']),
                    style: bodyText(13, color: Gp.inkSoft)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            failed ? 'failed' : '${item['amount'] ?? ''} $_symbol',
            style: failed
                ? bodyText(14, weight: FontWeight.w500, color: Gp.red)
                : displayText(17, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  String _ago(dynamic time) {
    final ms = int.tryParse('$time');
    if (ms == null || ms == 0) return '';
    final d =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}
