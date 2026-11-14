// GlobalPay — the phone app for the merged product: a GlobalPay card-and-fingerprint wallet that pays
// any UPI QR through GlobalPay.
//
// The phone holds no keys beyond its own P-256 keystore key; the card holds the other half. Every
// payment is one card tap plus one fingerprint, checked against on-chain limits.
//
// Point it at a relayer with:
//   flutter run --dart-define=RELAYER_URL=http://10.0.2.2:8787   (Android emulator)
//   flutter run --dart-define=RELAYER_URL=http://192.168.1.10:8787 (a phone on your Wi-Fi)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'screens/home.dart';
import 'screens/near_home.dart';
import 'screens/signup.dart';
import 'store.dart';
import 'theme.dart';

const String relayerUrl =
    String.fromEnvironment('RELAYER_URL', defaultValue: 'http://10.0.2.2:8787');

/// GlobalPay's own API: onramp orders and UPI payout detail do not live on the relayer.
const String globalPayUrl = String.fromEnvironment('GLOBALPAY_URL',
    defaultValue: 'http://10.0.2.2:8788');

/// The hackathon build opens the modular NEAR wallet without replacing the existing EVM wallet.
const bool nearMvp = bool.fromEnvironment('NEAR_MVP', defaultValue: false);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (nearMvp) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Color(0xFF050A08),
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xFF0C120F),
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }
  runApp(
      GlobalPayApp(api: Api(baseUrl: relayerUrl, globalPayUrl: globalPayUrl)));
}

class GlobalPayApp extends StatefulWidget {
  const GlobalPayApp({super.key, required this.api});

  final Api api;

  @override
  State<GlobalPayApp> createState() => _GlobalPayAppState();
}

class _GlobalPayAppState extends State<GlobalPayApp> {
  String? _address;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final address = await WalletStore.address();
    if (mounted) {
      setState(() {
        _address = address;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GlobalPay',
      debugShowCheckedModeBanner: false,
      theme: nearMvp ? globalPayDarkTheme() : globalPayTheme(),
      home: nearMvp
          ? NearHomeScreen(api: widget.api)
          : _loading
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : _address == null
                  ? SignupScreen(
                      api: widget.api,
                      onReady: (wallet) => setState(() => _address = wallet))
                  : HomeScreen(
                      key: ValueKey(_address),
                      api: widget.api,
                      onCreateWallet: (_) => setState(() => _address = null),
                    ),
    );
  }
}
