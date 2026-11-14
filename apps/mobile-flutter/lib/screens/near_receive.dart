import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api.dart';
import '../near/rpc.dart';
import '../near/secure_key.dart';
import '../ui.dart';
import 'receive_tap.dart';

String nearReceivePayload(String accountId) => Uri(
      scheme: 'globalpay',
      host: 'near',
      path: '/receive',
      queryParameters: {
        'network': nearNetworkId,
        'account': accountId,
        'token': nearTokenAccount,
      },
    ).toString();

String? nearRecipientOf(String raw) {
  final text = raw.trim();
  if (isNearAccountId(text)) return text;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'globalpay' || uri.host != 'near') {
    return null;
  }
  final account = uri.queryParameters['account'] ?? '';
  final network = uri.queryParameters['network'];
  final token = uri.queryParameters['token'];
  if (!isNearAccountId(account) ||
      (network != null && network != nearNetworkId) ||
      (token != null && token != nearTokenAccount)) {
    return null;
  }
  return account;
}

class NearReceiveScreen extends StatelessWidget {
  const NearReceiveScreen({
    super.key,
    required this.accountId,
    required this.api,
    this.cardWallet,
  });

  final String accountId;
  final Api api;
  final String? cardWallet;

  @override
  Widget build(BuildContext context) {
    final payload = nearReceivePayload(accountId);
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const DisplayHeading('How should they pay you?', size: 26),
          const SizedBox(height: 8),
          const Lede(
              'Choose crypto here, or use your ordinary UPI QR to receive INR.'),
          const SizedBox(height: 22),
          Panel(
            padding: const EdgeInsets.all(18),
            border: Border.all(color: Gp.line, width: 1.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.contactless, color: Gp.action),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Request crypto by card tap',
                          style: bodyText(16, weight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter the amount, then the sender taps their registered card on this receiver phone. Their own phone shows your wallet and amount before fingerprint approval.',
                  style: bodyText(13, color: Gp.inkSoft),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: cardWallet == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ReceiveTapScreen(
                              api: api,
                              recipient: cardWallet!,
                              symbol: 'USDT',
                            ),
                          )),
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Enter amount · wait for sender card'),
                ),
                Fine(
                  cardWallet == null
                      ? 'Set up the existing EVM card wallet under Cards before using this rail.'
                      : 'Existing GlobalPay EVM/local P2P rail. It is separate from the NEAR balance below.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Panel(
            padding: const EdgeInsets.all(20),
            border: Border.all(color: Gp.line, width: 1.5),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.currency_exchange, color: Gp.green),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Receive USDC.e on NEAR',
                          style: bodyText(16, weight: FontWeight.w700)),
                    ),
                    const StateTag('Crypto'),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: payload, size: 210),
                ),
                const SizedBox(height: 16),
                SelectableText(accountId,
                    textAlign: TextAlign.center,
                    style: bodyText(13, color: Gp.inkSoft)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: accountId));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('NEAR account copied')));
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy account'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Panel(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.currency_rupee, color: Gp.action),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Receive INR',
                          style: bodyText(16, weight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        'Show your normal UPI QR. The payer scans it in GlobalPay; their stablecoin is escrowed and a configured fiat treasury pays your UPI account through RazorpayX.',
                        style: bodyText(13, color: Gp.inkSoft),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Fine(
            'USDC.e on this screen is a permissionless NEAR testnet asset. Do not send mainnet assets to this account.',
            center: true,
          ),
        ],
      ),
    );
  }
}
