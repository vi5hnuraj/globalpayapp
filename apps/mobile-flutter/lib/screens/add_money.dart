// Add money: pay rupees on Razorpay's page, receive stablecoin in this wallet.
//
// A production wallet starts at zero, so this screen is the way in. GlobalPay creates a payment
// link for the amount; the browser pays it; GlobalPay verifies the payment with Razorpay and only
// then pays the stablecoin out of the vault's pool. We poll the order and never call it done until
// the order says PAID.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../ui.dart';

class AddMoneyScreen extends StatefulWidget {
  const AddMoneyScreen({
    super.key,
    required this.api,
    required this.wallet,
    required this.chain,
    required this.symbol,
  });

  final Api api;
  final String wallet;

  /// Legacy EVM chain key (`arc`, `whitechain`, `local`) from the wallet view. The NEAR build does
  /// not use this screen; it is kept only for the preserved EVM wallet.
  final String chain;
  final String symbol;

  @override
  State<AddMoneyScreen> createState() => _AddMoneyScreenState();
}

enum _Stage { amount, pay, done }

class _AddMoneyScreenState extends State<AddMoneyScreen> {
  final _amount = TextEditingController();
  Timer? _poll;

  _Stage _stage = _Stage.amount;
  bool _busy = false;
  String _error = '';
  Map<String, dynamic>? _order;

  @override
  void dispose() {
    _poll?.cancel();
    _amount.dispose();
    super.dispose();
  }

  String get _orderId => (_order?['orderId'] ?? '').toString();
  String get _status => (_order?['status'] ?? '').toString();
  String? get _checkoutUrl =>
      ((_order?['checkout'] as Map?)?['url'] ?? '').toString();
  Map? get _payTo => _order?['payTo'] as Map?;

  Future<void> _create() async {
    final inr = _amount.text.trim();
    if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(inr) ||
        (double.tryParse(inr) ?? 0) < 1) {
      setState(() => _error = 'Enter an amount in rupees, like 500.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final order = await widget.api
          .createOnramp(chain: widget.chain, wallet: widget.wallet, inr: inr);
      if (!mounted) return;
      setState(() {
        _order = order;
        _stage = _Stage.pay;
      });
      _startPolling();
      _copy();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_orderId.isEmpty || _stage == _Stage.done) return;
    try {
      final order = await widget.api.onrampStatus(_orderId);
      if (!mounted) return;
      setState(() => _order = order);
      final status = (order['status'] ?? '').toString();
      if (status == 'PAID') {
        _poll?.cancel();
        setState(() => _stage = _Stage.done);
      } else if (status == 'EXPIRED') {
        _poll?.cancel();
      }
    } on ApiError {
      // A blip is not a verdict: the next tick asks again.
    }
  }

  Future<void> _copy() async {
    final url = _checkoutUrl;
    final upi = (_payTo?['upiId'] ?? '').toString();
    final text = (url != null && url.isNotEmpty) ? url : upi;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text((url != null && url.isNotEmpty)
            ? 'Payment link copied. Open it in your browser to pay.'
            : 'UPI ID copied.')));
  }

  String get _statusLabel => switch (_status) {
        'AWAITING_FIAT' => 'Waiting for your rupee payment',
        'PAYING' => 'Payment received — sending your ${widget.symbol}',
        'PAID' => 'Done',
        'EXPIRED' => 'This order expired. Start again.',
        _ => _status.isEmpty ? 'Creating the order' : _status,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add money')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (_stage == _Stage.amount) ..._amountStep(),
          if (_stage == _Stage.pay) ..._payStep(),
          if (_stage == _Stage.done) ..._doneStep(),
          if (_error.isNotEmpty) ErrorLine(_error),
        ],
      ),
    );
  }

  List<Widget> _amountStep() => [
        const DisplayHeading('Add money'),
        const SizedBox(height: 6),
        const Lede(
            'Pay in rupees and this wallet receives the stablecoin. Your bank card is not involved in this step.'),
        const SizedBox(height: 24),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: displayText(34, height: 1.15),
          decoration: const InputDecoration(
            labelText: 'Amount in rupees',
            prefixText: '₹ ',
          ),
        ),
        const Fine(
            'GlobalPay prices the stablecoin at the moment your payment is confirmed. '
            'You will see the exact amount before paying.'),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create payment link'),
        ),
      ];

  List<Widget> _payStep() {
    final inr = (_order?['inrPaise'] ?? '');
    final rupees = int.tryParse(inr.toString());
    final url = _checkoutUrl ?? '';
    final payTo = _payTo;
    return [
      const DisplayHeading('Pay ₹', size: 22),
      Text(
        rupees == null ? '' : '₹${(rupees / 100).toStringAsFixed(2)}',
        style: displayText(44),
      ),
      const SizedBox(height: 4),
      Text(_statusLabel, style: bodyText(15, color: Gp.inkSoft)),
      const SizedBox(height: 20),
      Panel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (url.isNotEmpty) ...[
              Text('Payment link', style: bodyText(13, color: Gp.inkSoft)),
              const SizedBox(height: 6),
              SelectableText(url, style: bodyText(13)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy link'),
              ),
              const Fine(
                  'This app cannot open a browser itself. Open the link on this phone to pay with UPI or a card.'),
            ] else if (payTo != null) ...[
              Text('Pay to', style: bodyText(13, color: Gp.inkSoft)),
              const SizedBox(height: 6),
              SelectableText((payTo['upiId'] ?? '').toString(),
                  style: displayText(18)),
              const SizedBox(height: 6),
              Text(
                  'Use the note ${payTo['note'] ?? ''} so the payment is matched.',
                  style: bodyText(13, color: Gp.inkSoft)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy UPI ID'),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Watching for the payment…',
                style: bodyText(14, color: Gp.inkSoft)),
          ),
        ],
      ),
      if (_status == 'EXPIRED') ...[
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => setState(() {
            _stage = _Stage.amount;
            _order = null;
          }),
          child: const Text('Start again'),
        ),
      ],
    ];
  }

  List<Widget> _doneStep() {
    final amount = (_order?['amount'] ?? '').toString();
    final symbol = (_order?['symbol'] ?? widget.symbol).toString();
    final tx = (_order?['paidTx'] ?? '').toString();
    final explorer = (_order?['explorer'] ?? '').toString();
    return [
      const SizedBox(height: 40),
      const Icon(Icons.check_circle, size: 56, color: Gp.green),
      const SizedBox(height: 18),
      Center(
        child: Text('Added $amount $symbol',
            textAlign: TextAlign.center, style: displayText(24)),
      ),
      const SizedBox(height: 8),
      Center(
        child: Text('Your wallet balance has been updated.',
            textAlign: TextAlign.center,
            style: bodyText(15, color: Gp.inkSoft)),
      ),
      if (tx.isNotEmpty) ...[
        const SizedBox(height: 14),
        Center(
            child: Text(txShort(tx), style: bodyText(12, color: Gp.inkSoft))),
      ],
      if (explorer.isNotEmpty) ...[
        const SizedBox(height: 4),
        Center(
          child:
              SelectableText(explorer, style: bodyText(12, color: Gp.inkSoft)),
        ),
      ],
      const SizedBox(height: 28),
      FilledButton(
        onPressed: () => Navigator.of(context).maybePop(true),
        child: const Text('Done'),
      ),
    ];
  }
}
