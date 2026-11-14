// Every UPI payment this wallet made through GlobalPay, straight from GlobalPay rather than from the
// relayer's memory: escrow state, whether the payout rail confirmed the merchant, and the dispute
// window. Tapping a row opens the full detail and the dispute action.
import 'package:flutter/material.dart';

import '../api.dart';
import '../ui.dart';
import 'activity_detail.dart';

class UpiPaymentsScreen extends StatefulWidget {
  const UpiPaymentsScreen({super.key, required this.api, required this.wallet});

  final Api api;
  final String wallet;

  @override
  State<UpiPaymentsScreen> createState() => _UpiPaymentsScreenState();
}

class _UpiPaymentsScreenState extends State<UpiPaymentsScreen> {
  List<Map<String, dynamic>>? _items;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.offramps(widget.wallet);
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = '';
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _open(Map<String, dynamic> item) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ActivityDetailScreen(
          api: widget.api,
          id: (item['id'] ?? '').toString(),
          wallet: widget.wallet),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('UPI payments')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (_error.isNotEmpty) ErrorLine(_error),
            if (items == null)
              const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(child: CircularProgressIndicator()))
            else if (items.isEmpty)
              Panel(
                padding: const EdgeInsets.all(16),
                child: Text(
                    'No UPI payments yet. Pay a merchant QR from the home screen and it will appear here.',
                    style: bodyText(14, color: Gp.inkSoft)),
              )
            else
              Panel(
                child: Column(
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const Divider(indent: 16, endIndent: 16),
                      _row(items[i]),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 16),
            const Fine(
                'A payment is only "merchant paid" when the payout rail says so. '
                'Escrow alone is not proof the rupees arrived.'),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> item) {
    final status = (item['status'] ?? '').toString();
    final payout = (item['payout'] ?? 'NONE').toString();
    final payee = item['payee'] as Map?;
    final inrPaise = int.tryParse('${item['inrPaise'] ?? ''}') ?? 0;
    final (label, color) = _badge(status, payout);
    final needsReview = payout == 'NEEDS_OPERATOR';

    return InkWell(
      onTap: () => _open(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              needsReview
                  ? Icons.report_problem_outlined
                  : status == 'COMPLETED'
                      ? Icons.check_circle_outline
                      : status == 'DISPUTED' || status == 'REVERSED'
                          ? Icons.gavel_outlined
                          : Icons.lock_outline,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (payee?['name'] ?? payee?['upiId'] ?? 'UPI merchant')
                        .toString(),
                    style: bodyText(15, weight: FontWeight.w600, height: 1.3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(label, style: bodyText(12, color: Gp.inkSoft)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text('₹${(inrPaise / 100).toStringAsFixed(2)}',
                style: displayText(16, weight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  (String, Color) _badge(String status, String payout) {
    if (payout == 'NEEDS_OPERATOR') return ('Needs review', Gp.warning);
    return switch (status) {
      'COMPLETED' => ('Merchant payment confirmed', Gp.green),
      'LOCKED' => ('Locked — payout pending', Gp.inkSoft),
      'DISPUTED' => ('Disputed', Gp.warning),
      'REVERSED' || 'REFUNDED' => ('Refunded', Gp.red),
      'RELEASED' => ('Released', Gp.green),
      'QUOTED' || 'SUBMITTED' => ('Not locked', Gp.inkSoft),
      _ => (status, Gp.inkSoft),
    };
  }
}
