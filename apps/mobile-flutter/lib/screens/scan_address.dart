// Tap-to-send: read the other person's Receive code (their address as a QR) so the sender types an
// amount instead of forty-two characters. This only returns an address — it never sends anything,
// and the caller still validates it before a single coin moves.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanAddressScreen extends StatefulWidget {
  const ScanAddressScreen({super.key});

  @override
  State<ScanAddressScreen> createState() => _ScanAddressScreenState();
}

class _ScanAddressScreenState extends State<ScanAddressScreen> {
  bool _resolved = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan their code')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
            child: Text('Point the camera at the other person\'s Receive code',
                textAlign: TextAlign.center),
          ),
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                if (_resolved) return;
                final bars = capture.barcodes;
                final raw = bars.isEmpty ? null : bars.first.rawValue;
                if (raw == null) return;
                final address = recipientAddressOf(raw);
                if (address == null) return;
                _resolved = true;
                Navigator.of(context).pop(address);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The address inside a scanned payload, or null when the code is not one of ours.
///
/// A Receive code is the bare address, but a code pasted into a message is often a link, so accept
/// an address anywhere in the text. A UPI QR never contains `0x`, so the two can't be confused.
String? recipientAddressOf(String raw) =>
    RegExp(r'0x[0-9a-fA-F]{40}').firstMatch(raw.trim())?.group(0);
