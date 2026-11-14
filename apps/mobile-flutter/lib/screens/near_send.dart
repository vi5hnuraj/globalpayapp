import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../near/rpc.dart';
import '../near/secure_key.dart';
import '../ui.dart';
import 'near_receive.dart';

class NearSendScreen extends StatefulWidget {
  const NearSendScreen({
    super.key,
    required this.keyStore,
    required this.keyRecord,
    required this.balance,
    required this.symbol,
    required this.decimals,
  });

  final NearSecureKey keyStore;
  final NearKeyRecord keyRecord;
  final BigInt balance;
  final String symbol;
  final int decimals;

  @override
  State<NearSendScreen> createState() => _NearSendScreenState();
}

class _NearSendScreenState extends State<NearSendScreen> {
  final _recipient = TextEditingController();
  final _amount = TextEditingController();
  final _rpc = NearRpc();
  bool _busy = false;
  String _error = '';
  String _txHash = '';

  @override
  void dispose() {
    _recipient.dispose();
    _amount.dispose();
    _rpc.close();
    super.dispose();
  }

  Future<void> _scan() async {
    final account = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _NearAccountScanner()),
    );
    if (account != null && mounted) {
      setState(() {
        _recipient.text = account;
        _error = '';
      });
    }
  }

  Future<void> _send() async {
    final receiver = nearRecipientOf(_recipient.text) ?? _recipient.text.trim();
    BigInt amount;
    try {
      if (!isNearAccountId(receiver)) {
        throw NearRpcError('Enter or scan a valid NEAR account.');
      }
      amount = parseNearUnits(_amount.text, widget.decimals);
      if (amount > widget.balance) {
        throw NearRpcError(
            'This wallet does not have enough ${widget.symbol}.');
      }
    } on NearRpcError catch (error) {
      setState(() => _error = error.message);
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await _rpc.viewAccount(receiver);
      final storage = await _rpc.tokenStorageBalance(receiver);
      if (storage == null) {
        throw NearRpcError(
            '$receiver is not registered to receive ${widget.symbol}.');
      }
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Review crypto transfer'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyValueRow('You send',
                  '${formatNearUnits(amount, widget.decimals)} ${widget.symbol}',
                  emphasis: true),
              const SizedBox(height: 8),
              Text(receiver, style: bodyText(13, color: Gp.inkSoft)),
              const Fine(
                  'This is a direct NEAR transfer. It does not create an INR payout.'),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.fingerprint, size: 18),
              label: const Text('Approve'),
            ),
          ],
        ),
      );
      if (approved != true) return;
      final execution = await _rpc.transferTokens(
        key: widget.keyStore,
        record: widget.keyRecord,
        receiverId: receiver,
        amount: amount,
        decimals: widget.decimals,
      );
      if (!execution.success || execution.finalStatus != 'FINAL') {
        throw NearRpcError('The NEAR transfer did not finalize successfully.');
      }
      if (mounted) setState(() => _txHash = execution.hash);
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
    if (_txHash.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Send')),
        body: ListView(
          padding: const EdgeInsets.all(28),
          children: [
            const Icon(Icons.check_circle, size: 62, color: Gp.green),
            const SizedBox(height: 16),
            Text('Crypto sent',
                textAlign: TextAlign.center, style: displayText(28)),
            const SizedBox(height: 8),
            const Fine('Finalized on NEAR testnet.', center: true),
            const SizedBox(height: 20),
            SelectableText(_txHash,
                textAlign: TextAlign.center, style: bodyText(12)),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Done')),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Send crypto')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const DisplayHeading('Pay another wallet', size: 26),
          const SizedBox(height: 8),
          const Lede(
              'Scan their GlobalPay Receive code or enter a NEAR account.'),
          const SizedBox(height: 22),
          TextField(
            controller: _recipient,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Recipient NEAR account',
              hintText: 'name.testnet',
              suffixIcon: IconButton(
                  onPressed: _busy ? null : _scan,
                  tooltip: 'Scan Receive code',
                  icon: const Icon(Icons.qr_code_scanner)),
            ),
            onChanged: (_) => setState(() => _error = ''),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Amount',
              suffixText: widget.symbol,
              helperText:
                  'Available ${formatNearUnits(widget.balance, widget.decimals)} ${widget.symbol}',
            ),
            onChanged: (_) => setState(() => _error = ''),
          ),
          if (_error.isNotEmpty) ErrorLine(_error),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.fingerprint),
            label: Text(_busy ? 'Checking recipient…' : 'Review and send'),
          ),
          const Fine(
              'The private Ed25519 key remains encrypted on this phone and is unlocked only for this transaction.'),
        ],
      ),
    );
  }
}

class _NearAccountScanner extends StatefulWidget {
  const _NearAccountScanner();

  @override
  State<_NearAccountScanner> createState() => _NearAccountScannerState();
}

class _NearAccountScannerState extends State<_NearAccountScanner> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan Receive code')),
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Scan the recipient’s GlobalPay NEAR code.'),
            ),
            Expanded(
              child: MobileScanner(onDetect: (capture) {
                if (_done) return;
                for (final barcode in capture.barcodes) {
                  final account = nearRecipientOf(barcode.rawValue ?? '');
                  if (account != null) {
                    _done = true;
                    Navigator.of(context).pop(account);
                    return;
                  }
                }
              }),
            ),
          ],
        ),
      );
}
