// The dev card (the NFC stand-in behind DEV_FAKE_CARD) signs the block the chain recovers: read the
// signature back the way GlobalPayWallet._verifyRsa does — RSA over the stored modulus, then the
// 6A/05/BC framing and SHA-1 over the body plus the 4-byte challenge — and check every field.
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:globalpay/dev_card.dart';

void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  test('the dev card signs a block the chain would accept', () async {
    final card = await DevCard.load();

    // Only a `--dart-define=DEV_FAKE_CARD=1` build takes this path; a test build must not.
    expect(DevCard.enabled, isFalse);
    expect(card.modulusHex.length, 256, reason: 'a 1024-bit modulus, no 0x');
    expect(card.exponentHex, '010001');

    final n = BigInt.parse(card.modulusHex, radix: 16);
    final e = BigInt.parse(card.exponentHex, radix: 16);

    // The key is remembered, so tomorrow's payment still verifies against this wallet's card.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dev_card_modulus'), card.modulusHex);
    expect(prefs.getString('dev_card_private'), isNotNull);

    final sig = BigInt.parse(card.sign('01020304'), radix: 16);
    expect(sig, lessThan(n));

    // sig^e mod n — the staticcall the contract makes before it trusts anything else.
    final block = _bytes(sig.modPow(e, n), 128);
    expect(block[0], 0x6a, reason: 'Recovered block header');
    expect(block[1], 0x05, reason: 'hash algorithm id');
    expect(block[127], 0xbc, reason: 'Recovered block trailer');

    const bodyLen = 128 - 22;
    final body = block.sublist(1, 1 + bodyLen);
    expect(body[2], 9, reason: 'the length of the card dynamic data');
    expect(body.sublist(3 + 9).every((b) => b == 0xbb), isTrue,
        reason: 'BB padding');

    final hashInput = [...body, 0x01, 0x02, 0x03, 0x04];
    expect(block.sublist(128 - 21, 128 - 1), sha1.convert(hashInput).bytes);

    // Fresh randomness per signature, and the second one verifies the same way.
    final again = BigInt.parse(card.sign('01020304'), radix: 16);
    expect(again, isNot(sig));
    expect(_bytes(again.modPow(e, n), 128)[0], 0x6a);

    expect(() => card.sign('0102'), throwsFormatException,
        reason: 'the challenge is 4 bytes');
  });
}

List<int> _bytes(BigInt v, int len) {
  final hex = v.toRadixString(16).padLeft(len * 2, '0');
  return List.generate(
      len, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
}
