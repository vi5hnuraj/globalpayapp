// Receive: this wallet's address as a QR, so a payer can send USDT to it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api.dart';
import '../ui.dart';
import 'receive_tap.dart';

class ReceiveScreen extends StatelessWidget {
  const ReceiveScreen(
      {super.key,
      required this.address,
      required this.api,
      required this.symbol});

  final String address;
  final Api api;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const DisplayHeading('Your wallet address', size: 24),
              const SizedBox(height: 6),
              const Lede(
                  'Let another GlobalPay user tap their card. No address needs to be copied.'),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ReceiveTapScreen(
                      api: api, recipient: address, symbol: symbol),
                )),
                icon: const Icon(Icons.contactless),
                label: const Text('Receive by card tap'),
              ),
              const SizedBox(height: 24),
              const Fine('Or let the sender scan your Receive code',
                  center: true),
              const SizedBox(height: 22),
              Panel(
                padding: const EdgeInsets.all(16),
                border: Border.all(color: Gp.line, width: 1.5),
                child: QrImageView(data: address, size: 220),
              ),
              const SizedBox(height: 20),
              SelectableText(address,
                  textAlign: TextAlign.center,
                  style: bodyText(13, color: Gp.inkSoft)),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: address));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Address copied')));
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy address'),
              ),
              Fine('Send only $symbol on this network to this address.',
                  center: true),
            ],
          ),
        ),
      ),
    );
  }
}
