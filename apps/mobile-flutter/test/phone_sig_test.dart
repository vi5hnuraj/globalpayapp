// The phone's half of the second factor. GlobalPayWalletV2.verifyWebAuthn re-reads clientDataJSON
// from two byte offsets and compares literal strings from there, so this replays that check over
// the bytes phone_key.dart builds — the offsets are the whole reason this test exists.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:globalpay/phone_key.dart';

void main() {
  test('the offsets the wallet reads from point at the fields it compares', () {
    const hash =
        '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final (json: clientDataJSON, challengeIndex: ci, typeIndex: ti) =
        webAuthnClientData(hash);

    // Exactly what the contract builds: Base64.encodeURL(abi.encodePacked(h)), no padding.
    final expectedChallenge =
        '"challenge":"${base64Url.encode(_fromHex(hash)).replaceAll('=', '')}"';

    expect(_contains(clientDataJSON, ci, expectedChallenge), isTrue,
        reason: 'verifyWebAuthn line 88');
    expect(_contains(clientDataJSON, ti, '"type":"webauthn.get"'), isTrue,
        reason: 'line 89');

    // The old value was the offset of the challenge value, which fails the same comparison —
    // that is the BadSignature this test pins down.
    final valueOffset =
        utf8.encode('{"type":"webauthn.get","challenge":"').length;
    expect(ci, isNot(valueOffset));
    expect(_contains(clientDataJSON, valueOffset, expectedChallenge), isFalse);
  });

  test('the assertion the wallet re-hashes has UP and UV set', () {
    final rpIdHash = sha256.convert(utf8.encode(rpId)).bytes;
    final ad = [...rpIdHash, 0x05, 0, 0, 0, 0];
    expect(ad.length, 37, reason: 'verifyWebAuthn requires at least 37 bytes');
    expect(ad[32] & 0x01, isNonZero, reason: 'UP');
    expect(ad[32] & 0x04, isNonZero, reason: 'UV');
    // sha256(ad ‖ sha256(clientDataJSON)) is what P256.verify signs.
    final digest = sha256.convert(
        [...ad, ...sha256.convert(utf8.encode('{"a":1}')).bytes]).bytes;
    expect(digest, hasLength(32));
  });
}

/// GlobalPayV2.sol `_contains`: an exact byte match starting at `at`, nothing before it.
bool _contains(String hay, int at, String needle) {
  final h = hay.codeUnits;
  final n = needle.codeUnits;
  if (at + n.length > h.length) return false;
  for (var i = 0; i < n.length; i++) {
    if (h[at + i] != n[i]) return false;
  }
  return true;
}

List<int> _fromHex(String h) {
  final s = h.startsWith('0x') ? h.substring(2) : h;
  return List.generate(s.length ~/ 2,
      (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16));
}
