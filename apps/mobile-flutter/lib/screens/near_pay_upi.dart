import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api.dart';
import '../near/rpc.dart';
import '../near/secure_key.dart';
import '../ui.dart';

enum _NearPayStage { scan, amount, review, sending, locked, refunded }

class NearPayUpiScreen extends StatefulWidget {
  const NearPayUpiScreen({
    super.key,
    required this.api,
    required this.keyStore,
    required this.keyRecord,
  });

  final Api api;
  final NearSecureKey keyStore;
  final NearKeyRecord keyRecord;

  @override
  State<NearPayUpiScreen> createState() => _NearPayUpiScreenState();
}

class _NearPayUpiScreenState extends State<NearPayUpiScreen> {
  final _amount = TextEditingController();
  final _rpc = NearRpc();
  _NearPayStage _stage = _NearPayStage.scan;
  String _qrText = '';
  String _payee = '';
  String _upiId = '';
  String _error = '';
  String _status = '';
  String _txHash = '';
  Map<String, dynamic>? _quote;
  Map<String, dynamic>? _payment;
  Timer? _poller;
  bool _polling = false;

  @override
  void dispose() {
    _poller?.cancel();
    _amount.dispose();
    _rpc.close();
    super.dispose();
  }

  void _readQr(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'upi') {
      setState(() => _error = 'That is not a UPI payment QR.');
      return;
    }
    final upi = uri.queryParameters['pa'];
    if (upi == null || upi.isEmpty) {
      setState(() => _error = 'The UPI QR has no payee.');
      return;
    }
    setState(() {
      _qrText = raw.trim();
      _upiId = upi;
      _payee = uri.queryParameters['pn'] ?? upi;
      _amount.text = uri.queryParameters['am'] ?? '';
      _error = '';
      _stage = _NearPayStage.amount;
    });
  }

  Future<void> _getQuote() async {
    final amount = _amount.text.trim();
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(amount) ||
        (double.tryParse(amount) ?? 0) <= 0) {
      setState(() => _error = 'Enter a valid INR amount.');
      return;
    }
    setState(() {
      _error = '';
      _status = 'Getting the live USDC/INR quote…';
    });
    try {
      final quote = await widget.api.nearQuote(
        accountId: widget.keyRecord.accountId,
        inr: amount,
        qrText: _qrText,
      );
      if (!mounted) return;
      setState(() {
        _quote = quote;
        _status = '';
        _stage = _NearPayStage.review;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _pay() async {
    final quote = _quote;
    if (quote == null) return;
    setState(() {
      _stage = _NearPayStage.sending;
      _status = 'Confirm the exact amount with your fingerprint';
      _error = '';
    });
    try {
      final execution = await _rpc.lockTokens(
        key: widget.keyStore,
        record: widget.keyRecord,
        id: quote['id'] as String,
        amount: BigInt.parse(quote['amount'].toString()),
      );
      if (!execution.success || execution.finalStatus != 'FINAL') {
        throw NearRpcError(
            'NEAR did not finalize every payment receipt successfully.');
      }
      final tracked = await widget.api.trackNearPayment(
        id: quote['id'] as String,
        accountId: widget.keyRecord.accountId,
        txHash: execution.hash,
      );
      if (!mounted) return;
      setState(() {
        _txHash = execution.hash;
        _payment = tracked;
        _status = _payoutMessage(tracked);
        _stage = _NearPayStage.locked;
      });
      _startPolling();
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _stage = _NearPayStage.review;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('NearRpcError: ', '');
          _stage = _NearPayStage.review;
        });
      }
    }
  }

  Future<void> _refund() async {
    final quote = _quote;
    if (quote == null) return;
    setState(() {
      _status = 'Requesting the on-chain refund…';
      _error = '';
    });
    try {
      final execution = await _rpc.refund(
        key: widget.keyStore,
        record: widget.keyRecord,
        id: quote['id'] as String,
      );
      if (!execution.success) {
        throw NearRpcError('The refund transaction had a failed receipt.');
      }
      final lock = await _rpc.lock(quote['id'] as String);
      if (lock?['status'] != 'Refunded') {
        throw NearRpcError('The refund is not final on the vault.');
      }
      if (!mounted) return;
      setState(() {
        _txHash = execution.hash;
        _status = 'Refunded';
        _payment = {
          ...?_payment,
          'status': 'Refunded',
          'merchantPayout': 'FAILED_REFUNDED',
          'canRefund': false,
        };
        _stage = _NearPayStage.refunded;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _startPolling() {
    _poller?.cancel();
    if (_payment?['merchantPayoutConfigured'] != true) return;
    _poller =
        Timer.periodic(const Duration(seconds: 2), (_) => _refreshPayment());
  }

  Future<void> _refreshPayment() async {
    final quote = _quote;
    if (quote == null || _polling) return;
    _polling = true;
    try {
      final payment = await widget.api.nearPayment(
        quote['id'].toString(),
        viewToken: quote['viewToken']?.toString(),
      );
      if (!mounted) return;
      final payout = (payment['merchantPayout'] ?? '').toString();
      setState(() {
        _payment = payment;
        _status = _payoutMessage(payment);
        if ((payment['status'] ?? '').toString() == 'Refunded') {
          _stage = _NearPayStage.refunded;
        }
      });
      if ({'PAID_AND_SETTLED', 'FAILED_REFUNDED', 'REVIEW_REQUIRED'}
          .contains(payout)) {
        _poller?.cancel();
      }
    } catch (_) {
      // The finalized lock remains visible. A transient status-poll failure never changes money.
    } finally {
      _polling = false;
    }
  }

  String _payoutMessage(Map<String, dynamic> payment) {
    switch ((payment['merchantPayout'] ?? 'NOT_STARTED').toString()) {
      case 'STARTING':
        return 'Securing escrow before the INR payout starts…';
      case 'PROCESSING':
        return 'RazorpayX payout is processing. Refund is now disabled.';
      case 'REVIEW_REQUIRED':
        return 'Payout outcome is unclear. Funds remain frozen for operator review.';
      case 'FAILED':
      case 'FAILED_REFUNDING':
        return 'Payout definitively failed. Returning the escrow…';
      case 'FAILED_REFUNDED':
        return 'Payout failed and the escrow was returned.';
      case 'PAID_SETTLEMENT_PENDING':
        return 'Merchant payout is verified. Treasury settlement is pending.';
      case 'PAID_SETTLING':
        return 'Merchant payout is verified. Moving escrow to treasury…';
      case 'PAID_AND_SETTLED':
        return 'Merchant payout verified and escrow settled to treasury.';
      default:
        return payment['merchantPayoutConfigured'] == true
            ? 'Tokens locked. Waiting for the INR payout to begin.'
            : 'Tokens locked. INR payout is disabled in this build.';
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Pay UPI with NEAR')),
        body: SafeArea(child: _body()),
      );

  Widget _body() {
    if (_stage == _NearPayStage.scan) {
      return Column(children: [
        const Padding(
          padding: EdgeInsets.all(18),
          child: Text('Scan an ordinary UPI QR code'),
        ),
        Expanded(
          child: MobileScanner(onDetect: (capture) {
            final raw = capture.barcodes.firstOrNull?.rawValue;
            if (raw != null && _stage == _NearPayStage.scan) _readQr(raw);
          }),
        ),
        if (_error.isNotEmpty) ErrorLine(_error),
      ]);
    }
    if (_stage == _NearPayStage.amount) {
      return ListView(padding: const EdgeInsets.all(24), children: [
        PayeeCard(name: _payee, upi: _upiId),
        const SizedBox(height: 20),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
              labelText: 'Amount in INR', prefixText: '₹ '),
        ),
        if (_error.isNotEmpty) ErrorLine(_error),
        if (_status.isNotEmpty) Text(_status),
        const SizedBox(height: 20),
        FilledButton(onPressed: _getQuote, child: const Text('Get NEAR quote')),
      ]);
    }
    final quote = _quote!;
    if (_stage == _NearPayStage.review || _stage == _NearPayStage.sending) {
      final payout = (quote['payout'] as Map?) ?? const {};
      final payoutConfigured = payout['configured'] == true;
      final decisionSeconds = (payout['decisionTimeoutSec'] as num?)?.toInt();
      return ListView(padding: const EdgeInsets.all(24), children: [
        const DisplayHeading('Review payment', size: 28),
        const SizedBox(height: 10),
        PayeeCard(name: _payee, upi: _upiId),
        const SizedBox(height: 16),
        Panel(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              KeyValueRow('Merchant receives', '₹${_amount.text}'),
              KeyValueRow('You spend', '${quote['display']['amount']} USDC.e',
                  emphasis: true),
              const KeyValueRow('Network', 'NEAR testnet'),
              const KeyValueRow('Approval', 'Fingerprint'),
              KeyValueRow('INR payout',
                  payoutConfigured ? 'RazorpayX' : 'Disabled here'),
            ])),
        Fine(payoutConfigured
            ? 'Your test USDC.e enters escrow first. Cancellation is frozen before RazorpayX hand-off. The backend waits up to ${decisionSeconds ?? 30}s for a definitive provider result; unknown outcomes stay frozen for review.'
            : 'Your test USDC.e enters escrow, but this demo backend has no live RazorpayX rail. No merchant INR will be sent; you may cancel while payout has not started.'),
        if (_status.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_status),
        ],
        if (_error.isNotEmpty) ErrorLine(_error),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _stage == _NearPayStage.sending ? null : _pay,
          icon: const Icon(Icons.fingerprint),
          label: Text('Pay ₹${_amount.text} with fingerprint'),
        ),
      ]);
    }
    final payment = _payment ?? const <String, dynamic>{};
    final payout = (payment['merchantPayout'] ?? 'NOT_STARTED').toString();
    final refunded = _stage == _NearPayStage.refunded ||
        (payment['status'] ?? '').toString() == 'Refunded';
    final settled = payout == 'PAID_AND_SETTLED';
    final paid = payment['merchantPaid'] == true;
    final review = payout == 'REVIEW_REQUIRED';
    final canRefund = payment['canRefund'] == true;
    final icon = refunded
        ? Icons.replay_circle_filled
        : settled
            ? Icons.check_circle
            : review
                ? Icons.report_problem_outlined
                : paid
                    ? Icons.account_balance
                    : Icons.lock_clock;
    final color = refunded || settled || paid
        ? Gp.green
        : review
            ? Gp.warning
            : Gp.action;
    final title = refunded
        ? 'Escrow refunded'
        : settled
            ? 'Payment settled'
            : review
                ? 'Payment needs review'
                : paid
                    ? 'Merchant payout verified'
                    : 'Escrow locked';
    return ListView(padding: const EdgeInsets.all(24), children: [
      Icon(icon, size: 62, color: color),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: displayText(28)),
      const SizedBox(height: 8),
      Text(_status,
          textAlign: TextAlign.center, style: bodyText(14, color: Gp.inkSoft)),
      const SizedBox(height: 20),
      Panel(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            KeyValueRow('Escrow', (payment['status'] ?? 'Locked').toString()),
            KeyValueRow(
                'INR payout', payout.replaceAll('_', ' ').toLowerCase()),
            KeyValueRow('You spent', '${_quote!['display']['amount']} USDC.e'),
            KeyValueRow('Merchant request', '₹${_amount.text}'),
          ],
        ),
      ),
      const SizedBox(height: 16),
      SelectableText(txShort(_txHash),
          textAlign: TextAlign.center, style: bodyText(12, color: Gp.inkSoft)),
      if (_error.isNotEmpty) ErrorLine(_error),
      const SizedBox(height: 24),
      if (canRefund && !refunded)
        OutlinedButton.icon(
          onPressed: _refund,
          icon: const Icon(Icons.undo),
          label: const Text('Cancel before payout starts'),
        ),
      if (canRefund && !refunded)
        const Fine(
            'Cancellation is available only while the INR payout has not started. It disappears once payout is frozen.'),
      if (_payment?['merchantPayoutConfigured'] == true &&
          !refunded &&
          !settled &&
          !review) ...[
        const SizedBox(height: 18),
        const Center(child: CircularProgressIndicator()),
      ],
    ]);
  }
}
