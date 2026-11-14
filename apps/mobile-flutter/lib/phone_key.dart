// The phone's half of the second factor: a P-256 key in the Android keystore, unlocked by the
// fingerprint, packaged as a WebAuthn assertion exactly as mobile/lib/phone.js does it. The wallet
// verifies these bytes, so the JSON, its offsets and the low-s normalisation all have to match.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

const String rpId = 'globalpay.app';
const String _channel = 'globalpay/native';
const String _alias = 'globalpay-phone-key';

/// Order of the group; signatures with s above half of it are flipped, as WebAuthn requires.
final BigInt _p256n = BigInt.parse(
    'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
    radix: 16);

String _hex(Uint8List u8) =>
    u8.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String h) {
  final s = h.startsWith('0x') ? h.substring(2) : h;
  return Uint8List.fromList(List.generate(s.length ~/ 2,
      (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));
}

String _b64url(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// What the wallet's verifyPhone expects, one struct.
class PhoneAssertion {
  const PhoneAssertion({
    required this.authenticatorData,
    required this.clientDataJSON,
    required this.challengeIndex,
    required this.typeIndex,
    required this.r,
    required this.s,
  });

  final String authenticatorData; // hex, with 0x
  final String clientDataJSON;
  final int challengeIndex;
  final int typeIndex;
  final String r; // 0x + 32 bytes
  final String s;

  /// The JSON shape the relayer's withPhone() expects (it encodes the tuple itself).
  Map<String, dynamic> toJson() => {
        'authenticatorData': authenticatorData,
        'clientDataJSON': clientDataJSON,
        'challengeIndex': challengeIndex,
        'typeIndex': typeIndex,
        'r': r,
        's': s,
      };

  /// The ABI tuple, for callers that need the encoded form.
  String encode() {
    final cd = utf8.encode(clientDataJSON);
    // tuple(bytes, string, uint256, uint256, bytes32, bytes32): three words of head, then the tail.
    final heading = <Uint8List>[
      _word(BigInt.from(0x20)), // offset of bytes
      _word(BigInt.from(
          0x20 + 32 + ((cd.length + 31) ~/ 32) * 32)), // offset of string
      _word(BigInt.from(challengeIndex)),
      _word(BigInt.from(typeIndex)),
      _wordBytes(_fromHex(r)),
      _wordBytes(_fromHex(s)),
    ];
    final authData = _fromHex(authenticatorData);
    final bytesPart = <Uint8List>[
      _word(BigInt.from(authData.length)),
      _pad(authData),
    ];
    final stringPart = <Uint8List>[
      _word(BigInt.from(cd.length)),
      _pad(Uint8List.fromList(cd)),
    ];
    final out = <int>[];
    for (final w in [...heading, ...bytesPart, ...stringPart]) {
      out.addAll(w);
    }
    return '0x${_hex(Uint8List.fromList(out))}';
  }

  static Uint8List _pad(Uint8List data) {
    final padded = ((data.length + 31) ~/ 32) * 32;
    final out = Uint8List(padded);
    out.setRange(0, data.length, data);
    return out;
  }

  static Uint8List _wordBytes(Uint8List value) {
    if (value.length > 32) throw ArgumentError('value wider than 32 bytes');
    return (Uint8List(32)..setRange(32 - value.length, 32, value));
  }

  static Uint8List _word(BigInt value) {
    final out = Uint8List(32);
    var x = value;
    for (var i = 31; i >= 0 && x > BigInt.zero; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }
}

/// The `clientDataJSON` for [hashHex] and the two offsets the wallet re-reads it from.
///
/// GlobalPayWalletV2.verifyWebAuthn does `_contains(cd, challengeIndex, '"challenge":"<b64url>"')` —
/// an exact match from that byte, so the index has to be the field name, not the value. Both are
/// derived with `indexOf` so they can never drift from the string they point into.
({String json, int challengeIndex, int typeIndex}) webAuthnClientData(
    String hashHex) {
  const prefix = '{"type":"webauthn.get","challenge":"';
  final challenge = _b64url(_fromHex(hashHex));
  final json = '$prefix$challenge","origin":"android:app:globalpay"}';
  return (
    json: json,
    challengeIndex: json.indexOf('"challenge":"'),
    typeIndex: json.indexOf('"type":"')
  );
}

class PhoneKey {
  PhoneKey({MethodChannel? channel})
      : _ch = channel ?? const MethodChannel(_channel);

  final MethodChannel _ch;

  Future<bool> get exists async =>
      (await _ch.invokeMethod<bool>('hasKey', {'alias': _alias})) ?? false;

  Future<bool> get biometricsAvailable async =>
      (await _ch.invokeMethod<bool>('biometricsAvailable')) ?? false;

  /// Creates the key on first use and returns its public point, which signup puts on-chain.
  Future<({String x, String y})> create() async {
    final spki =
        await _ch.invokeMethod<Uint8List>('createKey', {'alias': _alias});
    if (spki == null || spki.length < 64) {
      throw PlatformException(
          code: 'keygen', message: 'Could not create the phone key');
    }
    final xy = Uint8List.sublistView(spki, spki.length - 64);
    return (
      x: '0x${_hex(Uint8List.sublistView(xy, 0, 32))}',
      y: '0x${_hex(Uint8List.sublistView(xy, 32))}'
    );
  }

  Future<void> forget() => _ch.invokeMethod('deleteKey', {'alias': _alias});

  /// Fingerprint, then sign [hashHex]. [title] is the first line of the system prompt, so the amount
  /// the user is approving is on the same screen as the fingerprint.
  Future<PhoneAssertion> sign(String hashHex,
      {required String title, String? subtitle}) async {
    final rpIdHash = sha256.convert(utf8.encode(rpId)).bytes;
    final authenticatorData =
        Uint8List.fromList([...rpIdHash, 0x05, 0, 0, 0, 0]);
    final (
      json: clientDataJSON,
      challengeIndex: challengeIndex,
      typeIndex: typeIndex
    ) = webAuthnClientData(hashHex);
    final clientDataHash = sha256.convert(utf8.encode(clientDataJSON)).bytes;
    final message =
        Uint8List.fromList([...authenticatorData, ...clientDataHash]);

    final der = await _ch.invokeMethod<Uint8List>('sign', {
      'alias': _alias,
      'message': message,
      'title': title,
      'subtitle': subtitle ?? '',
    });
    if (der == null)
      throw PlatformException(
          code: 'cancelled', message: 'Fingerprint cancelled');
    final (r, s) = _derToRS(der);

    return PhoneAssertion(
      authenticatorData: '0x${_hex(authenticatorData)}',
      clientDataJSON: clientDataJSON,
      challengeIndex: challengeIndex,
      typeIndex: typeIndex,
      r: r,
      s: s,
    );
  }

  (String, String) _derToRS(Uint8List der) {
    if (der.length == 64) {
      return (
        '0x${_hex(Uint8List.sublistView(der, 0, 32))}',
        '0x${_hex(Uint8List.sublistView(der, 32))}'
      );
    }
    var i = 0;
    if (der[i++] != 0x30) throw const FormatException('not a DER signature');
    var len = der[i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | der[i++];
      }
    }
    if (der[i++] != 0x02) throw const FormatException('not a DER signature');
    final rLen = der[i++];
    final r = der.sublist(i, i + rLen);
    i += rLen;
    if (der[i++] != 0x02) throw const FormatException('not a DER signature');
    final sLen = der[i++];
    var s = der.sublist(i, i + sLen);

    var sInt = BigInt.parse(_hex(Uint8List.fromList(s)), radix: 16);
    final rInt = BigInt.parse(_hex(Uint8List.fromList(r)), radix: 16);
    if (sInt > _p256n ~/ BigInt.two) sInt = _p256n - sInt;
    s = _fromHex(sInt.toRadixString(16).padLeft(64, '0'));

    return (
      '0x${rInt.toRadixString(16).padLeft(64, '0')}',
      '0x${_hex(Uint8List.fromList(s))}',
    );
  }
}
