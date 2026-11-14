import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../card.dart';
import '../dev_card.dart';
import '../near/rpc.dart';
import '../near/secure_key.dart';
import '../store.dart';
import '../ui.dart';
import 'home.dart';
import 'near_pay_upi.dart';
import 'near_payment_details.dart';
import 'near_receive.dart';
import 'near_send.dart';
import 'signup.dart';

class NearHomeScreen extends StatefulWidget {
  const NearHomeScreen({super.key, required this.api});

  final Api api;

  @override
  State<NearHomeScreen> createState() => _NearHomeScreenState();
}

class _NearHomeScreenState extends State<NearHomeScreen> {
  final NearSecureKey _key = NearSecureKey();
  final NearRpc _rpc = NearRpc();
  final ScrollController _scroll = ScrollController();
  NearKeyRecord? _record;
  NearTokenMetadata? _metadata;
  BigInt _tokenBalance = BigInt.zero;
  BigInt _nearBalance = BigInt.zero;
  List<Map<String, dynamic>> _history = const [];
  Map<String, dynamic>? _config;
  String? _cardWallet;
  bool _keyOnChain = false;
  bool _busy = false;
  String _error = '';
  String _authentication = '';
  String _cardFingerprint = '';
  int _navIndex = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _rpc.close();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final record = await _key.record();
      if (record == null) {
        final cardWallet = await WalletStore.address();
        if (!mounted) return;
        setState(() {
          _record = null;
          _metadata = null;
          _tokenBalance = BigInt.zero;
          _nearBalance = BigInt.zero;
          _keyOnChain = false;
          _history = const [];
          _config = null;
          _cardWallet = cardWallet;
        });
        return;
      }
      final accountId = record.accountId;
      final core = await Future.wait<dynamic>([
        _rpc.status(),
        _rpc.viewAccount(accountId),
        _rpc.tokenMetadata(),
        _rpc.tokenBalance(accountId),
      ]);
      if ((core[0] as Map)['chain_id'] != nearNetworkId) {
        throw NearRpcError('The configured RPC is not NEAR testnet.');
      }
      var registered = false;
      try {
        await _rpc.accessKey(record.accountId, record.publicKey);
        registered = true;
      } catch (_) {
        registered = false;
      }
      List<Map<String, dynamic>> history = const [];
      Map<String, dynamic>? config;
      try {
        final apiData = await Future.wait<dynamic>([
          widget.api.nearHistory(accountId),
          widget.api.nearConfig(),
        ]);
        history = (apiData[0] as List).cast<Map<String, dynamic>>();
        config = apiData[1] as Map<String, dynamic>;
      } catch (_) {
        // The wallet still shows independently verified on-chain balances if the payout API is down.
      }
      final cardWallet = await WalletStore.address();
      if (!mounted) return;
      setState(() {
        _record = record;
        _metadata = core[2] as NearTokenMetadata;
        _tokenBalance = core[3] as BigInt;
        _nearBalance = BigInt.parse((core[1] as Map)['amount'].toString());
        _keyOnChain = registered;
        _history = history;
        _config = config;
        _cardWallet = cardWallet;
        if (record.cardFingerprint.isNotEmpty) {
          _cardFingerprint = _formatCardId(record.cardFingerprint);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createKey() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    var created = false;
    try {
      final cardFingerprint = await _verifyCardPossession();
      final record = await _key.create(cardFingerprint: cardFingerprint);
      created = true;
      if (mounted) {
        setState(() {
          _record = record;
          _cardFingerprint = _formatCardId(cardFingerprint);
          _authentication = DevCard.enabled
              ? 'Test card stand-in verified; biometric created and encrypted the real NEAR key.'
              : 'Contactless card verified; biometric created and encrypted the NEAR key.';
        });
      }
    } on CardError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted && error.code != 'cancelled') {
        setState(
            () => _error = error.message ?? 'Could not create the secure key.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (created) await _refresh();
  }

  Future<String> _verifyCardPossession() async {
    late String challenge;
    final card = await CardReader().withCard(getChallenge: (_) async {
      final random = Random.secure();
      challenge = List.generate(4, (_) => random.nextInt(256))
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      return challenge;
    });
    if (card.signature == null ||
        !verifyCardChallenge(card.key, challenge, card.signature!)) {
      throw const CardError('The card signature did not verify.');
    }
    return sha256.convert(utf8.encode(card.key.modulusHex)).toString();
  }

  String _formatCardId(String fingerprint) {
    if (fingerprint.length < 8) return fingerprint.toUpperCase();
    return '${fingerprint.substring(0, 4).toUpperCase()} ${fingerprint.substring(4, 8).toUpperCase()}';
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label copied')));
    }
  }

  Future<void> _authenticateCardAndWallet() async {
    final record = _record;
    if (record == null) return;
    setState(() {
      _busy = true;
      _error = '';
      _authentication = '';
    });
    try {
      final cardFingerprint = await _verifyCardPossession();
      final message = sha256.convert(utf8.encode(
          'GLOBALPAY_NEAR_LOCAL_AUTH:${record.accountId}:${DateTime.now().millisecondsSinceEpoch}'));
      final signature = await _key.sign(
        Uint8List.fromList(message.bytes),
        title: 'Unlock your GlobalPay wallet',
        subtitle: record.accountId,
      );
      if (signature.length != 64) {
        throw NearRpcError('The NEAR wallet signature was invalid.');
      }
      if (mounted) {
        setState(() {
          _cardFingerprint = _formatCardId(cardFingerprint);
          _authentication = DevCard.enabled
              ? 'Test card stand-in verified; biometric unlocked the real NEAR key.'
              : 'Contactless card verified; biometric unlocked the NEAR key.';
        });
      }
    } on CardError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted && error.code != 'cancelled') {
        setState(() => _error = error.message ?? 'Authentication failed.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _go(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    await _refresh();
  }

  Future<void> _payUpi() async {
    final record = _record;
    if (record == null || !_keyOnChain) return;
    await _go(
        NearPayUpiScreen(api: widget.api, keyStore: _key, keyRecord: record));
  }

  Future<void> _openCardWallet() async {
    var address = _cardWallet;
    if (address == null) {
      String? created;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (routeContext) => SignupScreen(
          api: widget.api,
          onReady: (wallet) {
            created = wallet;
            Navigator.of(routeContext).pop();
          },
        ),
      ));
      address = created ?? await WalletStore.address();
      if (!mounted || address == null) return;
      setState(() => _cardWallet = address);
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (cardContext) => HomeScreen(
        api: widget.api,
        onCreateWallet: (_) {
          if (cardContext.mounted) Navigator.of(cardContext).pop();
          if (mounted) setState(() => _cardWallet = null);
        },
      ),
    ));
    await _refresh();
  }

  Future<void> _restartWalletOnboarding() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out and add another wallet?'),
        content: const Text(
          'This deletes only this phone’s encrypted NEAR key and returns to card + fingerprint onboarding. It does not move funds or remove the old public key from the demo account. The new public key must be provisioned on-chain before payments work.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep wallet')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Log out')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _key.clear();
      if (!mounted) return;
      setState(() {
        _record = null;
        _keyOnChain = false;
        _cardFingerprint = '';
        _authentication = '';
        _navIndex = 0;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
            () => _error = error.message ?? 'Could not reset the demo key.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showWalletDetails() {
    final record = _record;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/branding/globalpay-logo-original.png',
                    width: 260,
                    height: 260,
                    fit: BoxFit.cover,
                    cacheWidth: 520,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const DisplayHeading('Wallet details', size: 26),
              const SizedBox(height: 18),
              const Fine('NEAR ACCOUNT'),
              SelectableText(record?.accountId ?? nearDemoAccount,
                  style: bodyText(14)),
              TextButton.icon(
                onPressed: () =>
                    _copy(record?.accountId ?? nearDemoAccount, 'Account'),
                icon: const Icon(Icons.copy, size: 17),
                label: const Text('Copy account'),
              ),
              const Divider(),
              const KeyValueRow('Network', 'NEAR testnet'),
              const KeyValueRow('Token', 'USDC.e · permissionless test asset'),
              KeyValueRow('Vault', nearVaultAccount),
              if (_config?['treasuryAccountId'] != null)
                KeyValueRow(
                    'Treasury', _config!['treasuryAccountId'].toString()),
              if (record != null) ...[
                const Divider(),
                const Fine('BIOMETRIC-PROTECTED PUBLIC KEY'),
                SelectableText(record.publicKey,
                    style: bodyText(11, color: Gp.inkSoft)),
                TextButton.icon(
                  onPressed: () => _copy(record.publicKey, 'Public key'),
                  icon: const Icon(Icons.copy, size: 17),
                  label: const Text('Copy public key'),
                ),
                const Divider(height: 28),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Future<void>.delayed(
                        Duration.zero, _restartWalletOnboarding);
                  },
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Log out / add another wallet'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _navigate(int index) async {
    if (index == 1) {
      if (_record == null || !_keyOnChain) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Finish wallet setup before paying.')));
      } else {
        await _payUpi();
      }
      if (mounted) setState(() => _navIndex = 0);
      return;
    }
    setState(() => _navIndex = index);
    if (index == 0) {
      if (_scroll.hasClients) {
        await _scroll.animateTo(0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_record == null) return _onboardingGate();
    if (!_keyOnChain) return _activationGate(_record!);
    final metadata = _metadata;
    final accountId = _record?.accountId ?? nearDemoAccount;
    final symbol = metadata?.symbol ?? 'USDC.e';
    final decimals = metadata?.decimals ?? 6;
    final ready = _record != null && _keyOnChain;
    return Scaffold(
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: _navigate,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.qr_code_scanner), label: 'Pay UPI'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Activity'),
          NavigationDestination(
              icon: Icon(Icons.credit_card_outlined),
              selectedIcon: Icon(Icons.credit_card),
              label: 'Cards'),
        ],
      ),
      body: SafeArea(
        child: switch (_navIndex) {
          2 => _activityTab(symbol, decimals),
          3 => _cardsTab(accountId, symbol),
          _ => _homeTab(accountId, symbol, decimals, ready),
        },
      ),
    );
  }

  Widget _onboardingGate() => Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
            children: [
              Center(
                child: Image.asset(
                  'assets/branding/globalpay-logo-original.png',
                  width: 210,
                  height: 210,
                  fit: BoxFit.cover,
                  cacheWidth: 420,
                ),
              ),
              const SizedBox(height: 12),
              const DisplayHeading(
                  'Your card. Your fingerprint. Your crypto wallet.',
                  size: 32),
              const SizedBox(height: 10),
              const Lede(
                  'Create the phone-held wallet only after both possession and biometric checks pass.'),
              const SizedBox(height: 26),
              Panel(
                padding: const EdgeInsets.all(18),
                border: Border.all(color: Gp.line),
                child: const Column(
                  children: [
                    _OnboardingStep(
                      number: '1',
                      icon: Icons.contactless,
                      title: 'Tap a compatible card',
                      detail:
                          'The card signs a random challenge. GlobalPay stores no PAN, cardholder name or bank account.',
                    ),
                    Divider(height: 28),
                    _OnboardingStep(
                      number: '2',
                      icon: Icons.fingerprint,
                      title: 'Confirm your fingerprint',
                      detail:
                          'Android Keystore encrypts a new Ed25519 seed; the private key never leaves this phone.',
                    ),
                    Divider(height: 28),
                    _OnboardingStep(
                      number: '3',
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'Activate the public key',
                      detail:
                          'The demo operator adds only the public key to the NEAR testnet account before the wallet opens.',
                    ),
                  ],
                ),
              ),
              if (_error.isNotEmpty) ErrorLine(_error),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _busy ? null : _createKey,
                icon: Icon(DevCard.enabled
                    ? Icons.science_outlined
                    : Icons.contactless),
                label: Text(_busy
                    ? 'Creating secure wallet…'
                    : DevCard.enabled
                        ? 'Use test card, then fingerprint'
                        : 'Tap card, then fingerprint'),
              ),
              if (DevCard.enabled)
                const Fine(
                  'POCO test build: the physical NFC field is bypassed by a compile-time RSA test card. Fingerprint, Keystore encryption and NEAR key generation remain real.',
                  center: true,
                )
              else
                const Fine(
                  'Requires a compatible contactless EMV card and an NFC Android phone.',
                  center: true,
                ),
            ],
          ),
        ),
      );

  Widget _activationGate(NearKeyRecord record) => Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
            children: [
              const Icon(Icons.key, size: 62, color: Gp.action),
              const SizedBox(height: 18),
              const DisplayHeading('Secure key created', size: 30),
              const SizedBox(height: 8),
              const Lede(
                  'The card and fingerprint steps passed. Add this public key to the hackathon demo account; the encrypted private key stays on this phone.'),
              const SizedBox(height: 24),
              Panel(
                padding: const EdgeInsets.all(18),
                border: Border.all(color: Gp.line),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Fine('DEMO ACCOUNT'),
                    SelectableText(record.accountId, style: bodyText(14)),
                    const Divider(height: 28),
                    const Fine('NEW ED25519 PUBLIC KEY'),
                    const SizedBox(height: 6),
                    SelectableText(record.publicKey,
                        style: bodyText(12, color: Gp.inkSoft)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _copy(record.publicKey, 'Public key'),
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy public key'),
                    ),
                    if (record.cardFingerprint.isNotEmpty) ...[
                      const Divider(height: 28),
                      KeyValueRow('Card ID',
                          'GP ${_formatCardId(record.cardFingerprint)}'),
                    ],
                  ],
                ),
              ),
              if (_error.isNotEmpty) ErrorLine(_error),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('I provisioned it · check again'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _restartWalletOnboarding,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Start over with another card'),
              ),
            ],
          ),
        ),
      );

  Widget _homeTab(String accountId, String symbol, int decimals, bool ready) =>
      RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
          children: [
            _header(ready),
            const SizedBox(height: 4),
            WalletCard(
              label: 'NEAR TESTNET · BIOMETRIC WALLET',
              address: accountId,
              frozen: false,
              network: 'NEAR TESTNET',
              symbol: symbol,
            ),
            _balance(symbol, decimals),
            if (_error.isNotEmpty) ErrorLine(_error),
            if (_busy) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 22),
            if (!ready) _setupCard() else _actions(symbol, decimals),
            const SizedBox(height: 26),
            _holdings(symbol, decimals),
            const SizedBox(height: 26),
            _payoutRail(),
          ],
        ),
      );

  Widget _activityTab(String symbol, int decimals) => RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
          children: [
            _tabHeader('Activity', 'Escrow, payout and treasury status'),
            const SizedBox(height: 22),
            _activity(symbol, decimals, showTitle: false),
            const Fine(
                'UPI activity shows escrow and payout state without exposing the merchant’s private QR data.'),
          ],
        ),
      );

  Widget _cardsTab(String accountId, String symbol) => RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
          children: [
            _tabHeader(
                'Cards & security', 'Physical key and tap authorization'),
            const SizedBox(height: 18),
            WalletCard(
              label: 'GLOBALPAY PAYMENT KEY',
              address: accountId,
              network: 'CARD + BIOMETRIC',
              symbol: symbol,
            ),
            const SizedBox(height: 24),
            _security(showTitle: false),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _showWalletDetails,
              icon: const Icon(Icons.info_outline),
              label: const Text('View NEAR wallet details'),
            ),
            const SizedBox(height: 26),
            const SectionTitle('Existing card-wallet rail'),
            Panel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('EVM / local card wallet',
                      style: bodyText(15, weight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    'Preserved P2P tap, limits, freeze/recovery and multi-card features. This is a separate rail and does not show the NEAR balance above.',
                    style: bodyText(12, color: Gp.inkSoft),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _openCardWallet,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(_cardWallet == null
                        ? 'Set up EVM card wallet'
                        : 'Open EVM card wallet'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: _busy ? null : _restartWalletOnboarding,
              icon: const Icon(Icons.logout, size: 18),
              label: Text(DevCard.enabled
                  ? 'Log out / restart card + fingerprint demo'
                  : 'Log out / add another wallet'),
            ),
            const SizedBox(height: 26),
            _paymentRails(),
          ],
        ),
      );

  Widget _tabHeader(String title, String subtitle) => Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/branding/globalpay-icon-1024.png',
                width: 40, height: 40, cacheWidth: 80),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: displayText(25)),
                Text(subtitle, style: bodyText(12, color: Gp.inkSoft)),
              ],
            ),
          ),
          IconButton(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh'),
        ],
      );

  Widget _header(bool ready) => Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Image.asset('assets/branding/globalpay-icon-1024.png',
                width: 34, height: 34, cacheWidth: 80),
          ),
          const SizedBox(width: 9),
          Text('GlobalPay', style: displayText(20)),
          const SizedBox(width: 10),
          StateTag(ready ? 'Active' : 'Setup'),
          const Spacer(),
          IconButton(
              onPressed: _showWalletDetails,
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 20),
              tooltip: 'Wallet details'),
          IconButton(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Refresh balances'),
        ],
      );

  Widget _balance(String symbol, int decimals) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Stablecoin balance', style: bodyText(13, color: Gp.inkSoft)),
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(formatNearUnits(_tokenBalance, decimals),
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: displayText(46, height: 1)),
                ),
                const SizedBox(width: 8),
                Text(symbol,
                    style: bodyText(17,
                        weight: FontWeight.w600, color: Gp.inkSoft)),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  border: Border.all(color: Gp.line),
                  borderRadius: BorderRadius.circular(999)),
              child: Text(
                '$symbol on NEAR testnet · test asset, not production Circle USDC',
                style: bodyText(12, color: Gp.inkSoft),
              ),
            ),
            const SizedBox(height: 7),
            Text(
                '${formatNearUnitsCompact(_nearBalance, 24)} NEAR for network fees',
                style: bodyText(12, color: Gp.inkSoft)),
          ],
        ),
      );

  Widget _holdings(String symbol, int decimals) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('Holdings'),
          Panel(
            child: Column(
              children: [
                _holdingRow(
                  icon: Icons.attach_money,
                  name: 'Bridged USDC',
                  subtitle: 'USDC.e · NEAR testnet asset',
                  value: formatNearUnitsCompact(_tokenBalance, decimals),
                  symbol: symbol,
                  accent: Gp.action,
                ),
                const Divider(indent: 16, endIndent: 16),
                _holdingRow(
                  icon: Icons.hexagon_outlined,
                  name: 'NEAR',
                  subtitle: 'Network-fee balance',
                  value: formatNearUnitsCompact(_nearBalance, 24),
                  symbol: 'NEAR',
                  accent: Gp.ink,
                ),
              ],
            ),
          ),
        ],
      );

  Widget _holdingRow({
    required IconData icon,
    required String name,
    required String subtitle,
    required String value,
    required String symbol,
    required Color accent,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle),
              child: Icon(icon, color: accent, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: bodyText(15, weight: FontWeight.w700)),
                  Text(subtitle, style: bodyText(12, color: Gp.inkSoft)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 112,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: displayText(17, weight: FontWeight.w700)),
                  Text(symbol,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: bodyText(11, color: Gp.inkSoft)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _setupCard() => Panel(
        padding: const EdgeInsets.all(18),
        border: Border.all(color: Gp.line),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _record == null
                  ? 'Secure this wallet'
                  : 'Activate this phone key',
              style: bodyText(17, weight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _record == null
                  ? 'Tap your compatible contactless card, then use your fingerprint to create an Ed25519 wallet key encrypted by Android Keystore.'
                  : 'The public key must be added to this NEAR account. The private key never leaves the phone.',
              style: bodyText(13, color: Gp.inkSoft),
            ),
            const SizedBox(height: 14),
            if (_record == null)
              FilledButton.icon(
                onPressed: _busy ? null : _createKey,
                icon: const Icon(Icons.contactless),
                label: Text(DevCard.enabled
                    ? 'Use test card, then fingerprint'
                    : 'Tap card, then fingerprint'),
              )
            else ...[
              SelectableText(_record!.publicKey,
                  style: bodyText(11, color: Gp.inkSoft)),
              OutlinedButton.icon(
                onPressed: () => _copy(_record!.publicKey, 'Public key'),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy public key'),
              ),
            ],
          ],
        ),
      );

  Widget _actions(String symbol, int decimals) => Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _quickAction(
                  Icons.south_west_rounded,
                  'Receive',
                  () => _go(NearReceiveScreen(
                    accountId: _record!.accountId,
                    api: widget.api,
                    cardWallet: _cardWallet,
                  )),
                ),
              ),
              Expanded(
                child: _quickAction(
                  Icons.north_east_rounded,
                  'Send',
                  () => _go(NearSendScreen(
                    keyStore: _key,
                    keyRecord: _record!,
                    balance: _tokenBalance,
                    symbol: symbol,
                    decimals: decimals,
                  )),
                ),
              ),
              Expanded(
                child: _quickAction(Icons.wallet_outlined, 'Details',
                    () => setState(() => _navIndex = 3)),
              ),
              Expanded(
                child: _quickAction(Icons.qr_code_scanner_rounded, 'Scan UPI',
                    () => _navigate(1)),
              ),
            ],
          ),
        ],
      );

  Widget _quickAction(IconData icon, String label, VoidCallback action) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        child: Column(
          children: [
            SizedBox(
              width: 58,
              height: 58,
              child: IconButton(
                tooltip: label,
                onPressed: _busy ? null : action,
                style: IconButton.styleFrom(
                  backgroundColor: Gp.surface,
                  foregroundColor: Gp.dark ? Gp.action : Gp.ink,
                  disabledBackgroundColor: Gp.surface,
                  side: const BorderSide(color: Gp.line),
                  shape: const CircleBorder(),
                ),
                icon: Icon(icon, size: 23),
              ),
            ),
            const SizedBox(height: 8),
            Text(label,
                maxLines: 1, style: bodyText(11, weight: FontWeight.w600)),
          ],
        ),
      );

  Widget _payoutRail() {
    final capabilities = _config?['capabilities'] as Map?;
    final live = capabilities?['merchantPayout'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Crypto in · recipient chooses crypto or INR'),
        Panel(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              _flowRow(Icons.currency_exchange, 'Crypto recipient',
                  'Direct NEP-141 transfer to their NEAR account.'),
              const Divider(height: 24),
              _flowRow(
                  Icons.currency_rupee,
                  'INR recipient',
                  live
                      ? 'UPI payout is enabled through RazorpayX; paid escrow settles to treasury.'
                      : 'RazorpayX code is integrated but disabled here. No INR payout is claimed.'),
              const Divider(height: 24),
              _flowRow(
                  Icons.account_balance,
                  'Crypto treasury',
                  (_config?['treasuryAccountId'] ??
                          'treasury.globalpay-receipts.testnet')
                      .toString()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _flowRow(IconData icon, String title, String detail) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 21, color: Gp.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: bodyText(15, weight: FontWeight.w700)),
                Text(detail, style: bodyText(13, color: Gp.inkSoft)),
              ],
            ),
          ),
        ],
      );

  Widget _security({bool showTitle = true}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) const SectionTitle('Your payment key'),
          Panel(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const ChipGlyph(scale: 0.85),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Compatible contactless bank card',
                              style: bodyText(15, weight: FontWeight.w700)),
                          Text(
                              'Possession factor for onboarding and NFC/card-reader flows.',
                              style: bodyText(13, color: Gp.inkSoft)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Gp.dark ? const Color(0xFF0B120F) : Gp.paper,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Gp.line),
                  ),
                  child: Column(
                    children: [
                      KeyValueRow('Role', 'Physical possession key'),
                      const KeyValueRow('Card data stored', 'Public key only'),
                      KeyValueRow(
                          'Card ID',
                          _cardFingerprint.isEmpty
                              ? 'Tap to verify'
                              : 'GP $_cardFingerprint'),
                      KeyValueRow(
                          'Mode',
                          DevCard.enabled
                              ? 'Debug stand-in'
                              : 'EMV contactless DDA'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _record == null || _busy
                      ? null
                      : _authenticateCardAndWallet,
                  icon: const Icon(Icons.contactless, size: 19),
                  label: Text(DevCard.enabled
                      ? 'Run test card + biometric check'
                      : 'Verify card + biometric'),
                ),
                const Fine(
                    'UPI QR approval uses biometric only. A card tap is not required for each QR payment.'),
                if (DevCard.enabled)
                  const Fine(
                      'Debug stand-in enabled on this build because this phone has no NFC. This is not physical-card proof.'),
                if (_authentication.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.verified, color: Gp.green, size: 20),
                      const SizedBox(width: 9),
                      Expanded(
                          child: Text(_authentication, style: bodyText(13))),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      );

  Widget _activity(String symbol, int decimals, {bool showTitle = true}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) const SectionTitle('Activity'),
          Panel(
            child: _history.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                        'No UPI escrow activity yet. Send and receive are available above.',
                        style: bodyText(14, color: Gp.inkSoft)),
                  )
                : Column(
                    children: [
                      for (var index = 0;
                          index < _history.length && index < 12;
                          index++) ...[
                        if (index > 0) const Divider(indent: 16, endIndent: 16),
                        _activityRow(_history[index], symbol, decimals),
                      ],
                    ],
                  ),
          ),
        ],
      );

  Widget _activityRow(Map<String, dynamic> item, String symbol, int decimals) {
    final status = (item['status'] ?? 'Unknown').toString();
    final payout = (item['merchantPayout'] ?? 'NOT_STARTED').toString();
    final amount =
        BigInt.tryParse((item['amount'] ?? '0').toString()) ?? BigInt.zero;
    final terminal = status == 'Settled' || status == 'Refunded';
    final lockedAt = ((item['lock'] as Map?)?['locked_at'] as num?)?.toInt();
    return InkWell(
      onTap: _record == null
          ? null
          : () => _go(NearPaymentDetailsScreen(
                payment: item,
                keyStore: _key,
                keyRecord: _record!,
                symbol: symbol,
                decimals: decimals,
              )),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(
              status == 'Refunded'
                  ? Icons.replay
                  : terminal
                      ? Icons.check_circle_outline
                      : Icons.schedule,
              color: terminal ? Gp.green : Gp.warning,
              size: 21,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('UPI · $status',
                      style: bodyText(15, weight: FontWeight.w600)),
                  Text(
                      '${_payoutText(payout)}${lockedAt == null ? '' : ' · ${_ago(lockedAt)}'}',
                      style: bodyText(12, color: Gp.inkSoft)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${formatNearUnits(amount, decimals)} $symbol',
                    style: displayText(16)),
                const SizedBox(height: 4),
                const Icon(Icons.chevron_right, size: 17, color: Gp.inkSoft),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _payoutText(String value) =>
      {
        'NOT_STARTED': 'INR payout not started',
        'STARTING': 'Freezing escrow',
        'PROCESSING': 'INR payout processing',
        'REVIEW_REQUIRED': 'Payout needs review',
        'FAILED': 'Payout failed',
        'FAILED_REFUNDING': 'Payout failed · refunding',
        'FAILED_REFUNDED': 'Payout failed · refunded',
        'PAID_SETTLEMENT_PENDING': 'Merchant paid · treasury pending',
        'PAID_SETTLING': 'Merchant paid · settling treasury',
        'PAID_AND_SETTLED': 'Merchant paid · treasury settled',
      }[value] ??
      value;

  String _ago(int seconds) {
    final difference = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
    if (difference.inMinutes < 1) return 'now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m';
    if (difference.inHours < 24) return '${difference.inHours}h';
    return '${difference.inDays}d';
  }

  Widget _paymentRails() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('NFC and payment rails'),
          Panel(
            child: Column(
              children: [
                _railRow(Icons.credit_card, 'Card → phone',
                    'Working on compatible NFC Android', true),
                const Divider(indent: 16, endIndent: 16),
                _railRow(Icons.phonelink_ring, 'Card → GlobalPay phone/reader',
                    'Existing card-wallet/P2P rail; open it above', true),
                const Divider(indent: 16, endIndent: 16),
                _railRow(
                    Icons.point_of_sale,
                    'Phone → ordinary bank POS',
                    'Roadmap · needs HCE, acquirer and payment-network integration',
                    false),
                const Divider(indent: 16, endIndent: 16),
                _railRow(Icons.watch, 'Smartwatch → POS',
                    'Roadmap · not implemented', false),
              ],
            ),
          ),
        ],
      );

  Widget _railRow(IconData icon, String title, String detail, bool available) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 21, color: available ? Gp.green : Gp.inkSoft),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: bodyText(14, weight: FontWeight.w600)),
                  Text(detail, style: bodyText(12, color: Gp.inkSoft)),
                ],
              ),
            ),
            Text(available ? 'Available' : 'Roadmap',
                style: bodyText(11,
                    weight: FontWeight.w600,
                    color: available ? Gp.green : Gp.inkSoft)),
          ],
        ),
      );
}

class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.number,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final String number;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
                color: Gp.greenTint, shape: BoxShape.circle),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, size: 21, color: Gp.action),
                Positioned(
                  right: 1,
                  bottom: 0,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                        color: Gp.action, shape: BoxShape.circle),
                    child: Center(
                      child: Text(number,
                          style: bodyText(9,
                              weight: FontWeight.w800, color: Gp.onAction)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: bodyText(15, weight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(detail, style: bodyText(12, color: Gp.inkSoft)),
              ],
            ),
          ),
        ],
      );
}
