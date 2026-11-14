import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'base58.dart';

const nearNetworkId = 'testnet';
const nearDemoAccount = String.fromEnvironment(
  'NEAR_ACCOUNT_ID',
  defaultValue: 'demo.globalpay-receipts.testnet',
);

class NearKeyRecord {
  const NearKeyRecord({
    required this.accountId,
    required this.publicKey,
    required this.ciphertext,
    required this.iv,
    this.cardFingerprint = '',
  });

  final String accountId;
  final String publicKey;
  final Uint8List ciphertext;
  final Uint8List iv;

  /// First bytes of SHA-256(card public modulus), never PAN/cardholder/bank data.
  final String cardFingerprint;

  Map<String, Object> toJson() => {
        'accountId': accountId,
        'publicKey': publicKey,
        'ciphertext': base64Encode(ciphertext),
        'iv': base64Encode(iv),
        if (cardFingerprint.isNotEmpty) 'cardFingerprint': cardFingerprint,
      };

  factory NearKeyRecord.fromJson(Map<String, dynamic> value) => NearKeyRecord(
        accountId: value['accountId'] as String,
        publicKey: value['publicKey'] as String,
        ciphertext: base64Decode(value['ciphertext'] as String),
        iv: base64Decode(value['iv'] as String),
        cardFingerprint: (value['cardFingerprint'] ?? '').toString(),
      );
}

/// An Ed25519 NEAR key encrypted by a biometric-bound AES key in Android Keystore.
class NearSecureKey {
  NearSecureKey({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('globalpay/native');

  static const _preference = 'near_wallet_v1';
  static const _wrappingAlias = 'globalpay-near-wallet-wrap-v1';
  final MethodChannel _channel;
  final Ed25519 _algorithm = Ed25519();

  Future<NearKeyRecord?> record() async {
    final raw = (await SharedPreferences.getInstance()).getString(_preference);
    if (raw == null) return null;
    try {
      return NearKeyRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<NearKeyRecord> create({
    String accountId = nearDemoAccount,
    String cardFingerprint = '',
  }) async {
    final existing = await record();
    if (existing != null) return existing;
    final keyPair = await _algorithm.newKeyPair();
    final seed = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final public = await keyPair.extractPublicKey();
    try {
      final encrypted = await _channel.invokeMapMethod<String, dynamic>(
        'encryptNearSecret',
        {
          'alias': _wrappingAlias,
          'plaintext': seed,
          'title': 'Create your NEAR wallet',
        },
      );
      final ciphertext = encrypted?['ciphertext'] as Uint8List?;
      final iv = encrypted?['iv'] as Uint8List?;
      if (ciphertext == null || iv == null) {
        throw PlatformException(
            code: 'near_key', message: 'The secure key was not created.');
      }
      final result = NearKeyRecord(
        accountId: accountId,
        publicKey: 'ed25519:${base58Encode(public.bytes)}',
        ciphertext: ciphertext,
        iv: iv,
        cardFingerprint: cardFingerprint,
      );
      await (await SharedPreferences.getInstance())
          .setString(_preference, jsonEncode(result.toJson()));
      return result;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  Future<Uint8List> sign(
    List<int> message, {
    required String title,
    String subtitle = '',
  }) async {
    final saved = await record();
    if (saved == null) {
      throw PlatformException(
          code: 'no_near_key', message: 'Create the NEAR wallet key first.');
    }
    final decrypted =
        await _channel.invokeMethod<Uint8List>('decryptNearSecret', {
      'alias': _wrappingAlias,
      'ciphertext': saved.ciphertext,
      'iv': saved.iv,
      'title': title,
      'subtitle': subtitle,
    });
    if (decrypted == null || decrypted.length != 32) {
      throw PlatformException(
          code: 'near_key',
          message: 'The secure NEAR key could not be unlocked.');
    }
    // Platform message buffers may be unmodifiable; copy before signing and zeroizing.
    final seed = Uint8List.fromList(decrypted);
    final publicBytes =
        base58Decode(saved.publicKey.substring('ed25519:'.length));
    try {
      final keyPair = SimpleKeyPairData(
        seed,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
      final signature = await _algorithm.sign(message, keyPair: keyPair);
      return Uint8List.fromList(signature.bytes);
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  Future<void> clear() async {
    await _channel.invokeMethod<void>('deleteKey', {'alias': _wrappingAlias});
    await (await SharedPreferences.getInstance()).remove(_preference);
  }
}
