// One UPI payment, in full: what escrow holds, whether the merchant's payout is confirmed, and —
// when it is — the dispute window that lets the payer say "my merchant was not paid".
//
// The rule this screen exists to enforce: an onchain COMPLETED is not "paid". Only GlobalPay's
// payout state is, and a disputed or unknown payment says so plainly.
import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../phone_key.dart';
import '../ui.dart';

class ActivityDetailScreen extends StatefulWidget {
  const ActivityDetailScreen(
      {super.key, required this.api, required this.id, required this.wallet});

  final Api api;
  final String id;
  final String wallet;

  @override
  State<ActivityDetailScreen> createState() => _ActivityDetailScreenState();
}

class _ActivityDetailScreenState extends State<ActivityDetailScreen> {
  Map<String, dynamic>? _view;
  String _error = '';
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final view = await widget.api.offramp(widget.id);
      if (!mounted) return;
      setState(() {
        _view = view;
        _error = '';
      });
      final status = (view['status'] ?? '').toString();
      if (status == 'RELEASED' ||
          status == 'REFUNDED' ||
          status == 'REVERSED') {
        _poll?.cancel();
      }
    } on ApiError catch (e) {
      if (mounted && _view == null) setState(() => _error = e.message);
    }
  }

  Future<void> _dispute() async {
    final id = (_view?['id'] ?? widget.id).toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report merchant not paid'),
        content: const Text(
            'This disputes the payment onchain and starts the refund path. '
            'Only do this if the merchant really did not receive the rupees. '
            'It needs your fingerprint — a dispute can only return the money to your wallet.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Dispute')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final start =
          await widget.api.startDispute(wallet: widget.wallet, offrampId: id);
      final hash = (start['hash'] as String?) ?? '';
      if (hash.isEmpty) throw ApiError('The service did not return a digest.');

      final phone = PhoneKey();
      final assertion = await phone.sign(hash, title: 'Dispute this payment');
      await widget.api.finishDispute(start['id'] as String, assertion.toJson());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Disputed. GlobalPay will resolve it and refund you.')));
      await _load();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _title(String status) => switch (status) {
        'QUOTED' => 'Quote only — not locked',
        'SUBMITTED' => 'Submitted',
        'LOCKED' => 'Money locked, payout not confirmed',
        'COMPLETED' => 'Merchant payment confirmed',
        'DISPUTED' => 'Disputed',
        'REVERSED' => 'Refunded to you',
        'REFUNDED' => 'Refunded to you',
        'RELEASED' => 'Released to the liquidity pool',
        _ => status,
      };

  String _subtitle(String status) => switch (status) {
        'LOCKED' ||
        'COMPLETED' =>
          'Escrow holds the stablecoin until the payout rail confirms the merchant was paid.',
        'DISPUTED' =>
          'GlobalPay is resolving your report. The escrow stays locked meanwhile.',
        'REVERSED' || 'REFUNDED' => 'The stablecoin came back to this wallet.',
        'RELEASED' => 'The dispute window closed with no dispute.',
        _ => '',
      };

  Color _tone(String status) => switch (status) {
        'COMPLETED' || 'RELEASED' => Gp.green,
        'DISPUTED' => Gp.warning,
        'REVERSED' || 'REFUNDED' => Gp.red,
        _ => Gp.inkSoft,
      };

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (_error.isNotEmpty) ErrorLine(_error),
            if (view == null)
              const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(child: CircularProgressIndicator()))
            else
              ..._body(view),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(Map<String, dynamic> view) {
    final status = (view['status'] ?? '').toString();
    final payee = view['payee'] as Map?;
    final inrPaise = int.tryParse('${view['inrPaise'] ?? ''}') ?? 0;
    final amount = (view['amount'] ?? '').toString();
    final payout = (view['payout'] ?? 'NONE').toString();
    final timers = (view['timers'] as Map?) ?? const {};
    final txs = (view['txs'] as Map?) ?? const {};
    final explorer = (view['explorer'] ?? '').toString();
    final canDispute = view['canDispute'] == true;
    final refund = (view['refundReasonName'] ?? '').toString();

    return [
      Text(_title(status), style: displayText(26, color: _tone(status))),
      const SizedBox(height: 6),
      Text(_subtitle(status), style: bodyText(14, color: Gp.inkSoft)),
      const SizedBox(height: 20),
      Text('₹${(inrPaise / 100).toStringAsFixed(2)}', style: displayText(40)),
      if (amount.isNotEmpty)
        Text('$amount locked in escrow',
            style: bodyText(14, color: Gp.inkSoft)),
      const SizedBox(height: 20),
      Panel(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          children: [
            KeyValueRow(
                'Payee', (payee?['name'] ?? payee?['upiId'] ?? '—').toString()),
            KeyValueRow('UPI ID', (payee?['upiId'] ?? '—').toString()),
            const Divider(height: 16),
            KeyValueRow('Escrow', status),
            KeyValueRow('Payout rail', _payoutLabel(payout)),
            KeyValueRow('Payment id', shortAddress(widget.id)),
            if (refund.isNotEmpty) KeyValueRow('Refund reason', refund),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (payout == 'NEEDS_OPERATOR')
        Panel(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.report_problem_outlined, color: Gp.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    'The payout rail could not confirm the merchant result. This payment is held for review and will not be refunded automatically.',
                    style: bodyText(13)),
              ),
            ],
          ),
        ),
      if ((timers['releasableAt'] ?? '').toString().isNotEmpty &&
          status == 'COMPLETED' &&
          canDispute)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'Dispute window closes ${_when(timers['releasableAt'])}.',
            style: bodyText(13, color: Gp.inkSoft),
          ),
        ),
      if ((timers['disputeDeadline'] ?? '').toString().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'GlobalPay must resolve this dispute by ${_when(timers['disputeDeadline'])}.',
            style: bodyText(13, color: Gp.inkSoft),
          ),
        ),
      const SizedBox(height: 20),
      if (canDispute)
        OutlinedButton.icon(
          style: dangerOutlineStyle(),
          onPressed: _busy ? null : _dispute,
          icon: const Icon(Icons.gavel_outlined, size: 18),
          label: const Text('Report merchant not paid'),
        ),
      if (canDispute)
        const Fine(
            'Only use this if the merchant did not receive the rupees. It needs your fingerprint.'),
      const SizedBox(height: 20),
      Panel(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Onchain', style: displayText(16)),
            const SizedBox(height: 6),
            for (final entry in {
              'Lock': txs['lock'],
              'Complete': txs['complete'],
              'Dispute': txs['dispute'],
              'Final': txs['final'],
            }.entries)
              if ((entry.value ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      SizedBox(
                          width: 76,
                          child: Text(entry.key,
                              style: bodyText(12, color: Gp.inkSoft))),
                      Expanded(
                          child: Text(txShort(entry.value.toString()),
                              style: bodyText(12))),
                    ],
                  ),
                ),
            if (explorer.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(explorer, style: bodyText(11, color: Gp.inkSoft)),
            ],
          ],
        ),
      ),
    ];
  }

  String _payoutLabel(String state) => switch (state) {
        'NONE' => 'not started',
        'DISPATCHING' => 'handing to the rail',
        'DISPATCHED' => 'sent, awaiting completion',
        'FAILED' => 'failed — refunded',
        'SKIPPED' => 'not started',
        'NEEDS_OPERATOR' => 'needs review',
        _ => state,
      };

  String _when(dynamic seconds) {
    final s = int.tryParse('$seconds');
    if (s == null || s == 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(s * 1000);
    final diff = d.difference(DateTime.now());
    final when =
        '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (diff.isNegative) return when;
    if (diff.inMinutes < 60) return '$when (in ${diff.inMinutes}m)';
    if (diff.inHours < 24) return '$when (in ${diff.inHours}h)';
    return when;
  }
}
