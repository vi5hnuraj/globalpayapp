import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../near/rpc.dart';
import '../near/secure_key.dart';
import '../ui.dart';

class NearPaymentDetailsScreen extends StatefulWidget {
  const NearPaymentDetailsScreen({
    super.key,
    required this.payment,
    required this.keyStore,
    required this.keyRecord,
    required this.symbol,
    required this.decimals,
  });

  final Map<String, dynamic> payment;
  final NearSecureKey keyStore;
  final NearKeyRecord keyRecord;
  final String symbol;
  final int decimals;

  @override
  State<NearPaymentDetailsScreen> createState() =>
      _NearPaymentDetailsScreenState();
}

class _NearPaymentDetailsScreenState extends State<NearPaymentDetailsScreen> {
  final NearRpc _rpc = NearRpc();
  late Map<String, dynamic> _payment;
  bool _busy = false;
  String _error = '';
  String _refundHash = '';

  @override
  void initState() {
    super.initState();
    _payment = Map<String, dynamic>.from(widget.payment);
  }

  @override
  void dispose() {
    _rpc.close();
    super.dispose();
  }

  Future<void> _cancel() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final execution = await _rpc.refund(
        key: widget.keyStore,
        record: widget.keyRecord,
        id: _payment['id'].toString(),
      );
      if (!execution.success || execution.finalStatus != 'FINAL') {
        throw NearRpcError('The refund did not finalize successfully.');
      }
      final lock = await _rpc.lock(_payment['id'].toString());
      if (lock?['status'] != 'Refunded') {
        throw NearRpcError('The vault has not finalized this refund.');
      }
      if (!mounted) return;
      setState(() {
        _refundHash = execution.hash;
        _payment = {
          ..._payment,
          'status': 'Refunded',
          'merchantPayout': 'FAILED_REFUNDED',
          'canRefund': false,
          'lock': lock,
        };
      });
    } on PlatformException catch (error) {
      if (mounted && error.code != 'cancelled') {
        setState(() => _error = error.message ?? 'Biometric approval failed.');
      }
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('NearRpcError: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final amount =
        BigInt.tryParse((_payment['amount'] ?? '0').toString()) ?? BigInt.zero;
    final paise = int.tryParse((_payment['inrPaise'] ?? '0').toString()) ?? 0;
    final status = (_payment['status'] ?? 'Unknown').toString();
    final payout = (_payment['merchantPayout'] ?? 'NOT_STARTED').toString();
    final canRefund = _payment['canRefund'] == true;
    final terminal = status == 'Refunded' || status == 'Settled';
    return Scaffold(
      appBar: AppBar(title: const Text('Payment details')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            status == 'Refunded'
                ? Icons.replay_circle_filled
                : terminal
                    ? Icons.check_circle
                    : Icons.lock_clock,
            size: 58,
            color: terminal ? Gp.green : Gp.action,
          ),
          const SizedBox(height: 14),
          Text(status == 'Refunded' ? 'Escrow refunded' : 'UPI escrow',
              textAlign: TextAlign.center, style: displayText(28)),
          const SizedBox(height: 22),
          Panel(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                KeyValueRow('Escrow', status),
                KeyValueRow('INR payout', _payoutText(payout)),
                KeyValueRow('Merchant request', _formatRupees(paise)),
                KeyValueRow(
                  'Stablecoin',
                  '${formatNearUnits(amount, widget.decimals)} ${widget.symbol}',
                  emphasis: true,
                ),
                const KeyValueRow('Network', 'NEAR testnet'),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text('ESCROW ID', style: bodyText(11, color: Gp.inkSoft)),
          const SizedBox(height: 5),
          SelectableText(_payment['id'].toString(), style: bodyText(12)),
          const SizedBox(height: 14),
          Text('LOCK TRANSACTION', style: bodyText(11, color: Gp.inkSoft)),
          const SizedBox(height: 5),
          SelectableText((_payment['txHash'] ?? '').toString(),
              style: bodyText(12)),
          if (_refundHash.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('REFUND TRANSACTION', style: bodyText(11, color: Gp.inkSoft)),
            const SizedBox(height: 5),
            SelectableText(_refundHash, style: bodyText(12)),
          ],
          if (_error.isNotEmpty) ErrorLine(_error),
          const SizedBox(height: 24),
          if (canRefund)
            FilledButton.icon(
              onPressed: _busy ? null : _cancel,
              icon: const Icon(Icons.fingerprint),
              label: Text(
                  _busy ? 'Requesting refund…' : 'Cancel before payout starts'),
            ),
          if (canRefund)
            const Fine(
                'This is available only because the INR payout has not started. It disappears once payout is frozen.'),
          if (!canRefund && !terminal)
            const Fine(
                'Refund is disabled because payout has started or needs operator review. This prevents a merchant payment and payer refund from both succeeding.'),
        ],
      ),
    );
  }

  String _formatRupees(int paise) {
    final rupees = paise ~/ 100;
    final fraction = (paise % 100).toString().padLeft(2, '0');
    return '₹$rupees.$fraction';
  }

  String _payoutText(String value) =>
      {
        'NOT_STARTED': 'Not started',
        'STARTING': 'Starting',
        'PROCESSING': 'Processing',
        'REVIEW_REQUIRED': 'Review required',
        'FAILED': 'Definitively failed',
        'FAILED_REFUNDING': 'Failed · refunding',
        'FAILED_REFUNDED': 'Failed · refunded',
        'PAID_SETTLEMENT_PENDING': 'Paid · treasury pending',
        'PAID_SETTLING': 'Paid · settling treasury',
        'PAID_AND_SETTLED': 'Paid and settled',
      }[value] ??
      value;
}
