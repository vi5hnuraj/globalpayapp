// A stand-in for the bank card, for phones with no NFC: build with `--dart-define=DEV_FAKE_CARD=1`
// and CardReader skips the tap entirely, answering from a local RSA key instead.
//
// Without the define this is dead code — `enabled` is a compile-time false, so a normal build keeps
// talking to the real card over ISO-DEP and never touches this file's key.
//
// The key is generated once and remembered in SharedPreferences, because the wallet stores the
// card's modulus on-chain when it is created and verifies every later signature against it: a fresh
// key per launch would make the app's own payments fail verification.
//
// The signature is byte for byte what globalpay-main/contracts/test/helpers.js (makeCard) produces,
// which is the shape GlobalPayWallet._verifyRsa recovers:
//   6A | 05 | hashAlg | Ldd | dynamic data | BB.. | SHA-1(body ‖ challenge) | BC
// signed raw with RSA, over the 4-byte challenge the relayer hands out.
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';

import 'card.dart' show CardKey;

class DevCard {
  DevCard._(this._n, this._d);

  /// True only when the app was built with `--dart-define=DEV_FAKE_CARD=true` (or `=1`).
  static const bool enabled =
      String.fromEnvironment('DEV_FAKE_CARD') == 'true' ||
          String.fromEnvironment('DEV_FAKE_CARD') == '1';

  static const _nPref = 'dev_card_modulus';
  static const _dPref = 'dev_card_private';

  /// Public exponent, 65537 — what the chain uses to read the block back.
  static final BigInt _e = BigInt.from(65537);

  final BigInt _n;
  final BigInt _d;

  static DevCard? _cached;

  /// This install's card: the remembered key, or a new one made on first use.
  static Future<DevCard> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    BigInt? n;
    BigInt? d;
    final prefs = await SharedPreferences.getInstance();
    final nHex = prefs.getString(_nPref);
    final dHex = prefs.getString(_dPref);
    if (nHex != null && dHex != null) {
      try {
        final storedN = BigInt.parse(nHex, radix: 16);
        final storedD = BigInt.parse(dHex, radix: 16);
        if (_usable(storedN, storedD)) {
          n = storedN;
          d = storedD;
        }
      } on FormatException {
        // Unreadable: fall through and make a new one.
      }
    }
    if (n == null || d == null) {
      (n, d) = _generate();
      await prefs.setString(_nPref, n.toRadixString(16));
      await prefs.setString(_dPref, d.toRadixString(16));
    }
    return _cached = DevCard._(n, d);
  }

  /// The modulus is sent as the card's, 128 bytes of hex with no 0x — the length the chain's
  /// block layout is written for.
  String get modulusHex => _hexOf(_n, (_n.bitLength + 7) ~/ 8);

  String get exponentHex => _hexOf(_e, (_e.bitLength + 7) ~/ 8);

  CardKey get key => CardKey(modulusHex: modulusHex, exponentHex: exponentHex);

  /// Sign a 4-byte challenge the way the card would after INTERNAL AUTHENTICATE.
  String sign(String challengeHex) {
    final challenge = _fromHex(challengeHex);
    if (challenge.length != 4) {
      throw FormatException(
          'the card challenge is 4 bytes, got ${challenge.length}');
    }
    final len = (_n.bitLength + 7) ~/ 8;
    final m = _block(len, challenge, Random.secure());
    return _hexOf(m.modPow(_d, _n), len);
  }

  /// Two 512-bit primes whose product is a full 1024 bits: the recovered block starts 0x6A, so the
  /// modulus has to be larger than any block we sign, or the chain reads back a different message.
  static (BigInt, BigInt) _generate() {
    final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    final rng = pc.FortunaRandom()..seed(pc.KeyParameter(seed));
    for (var attempt = 0; attempt < 8; attempt++) {
      final p = pc.generateProbablePrime(512, 16, rng);
      final q = pc.generateProbablePrime(512, 16, rng);
      if (p == q) continue;
      final n = p * q;
      if (n.bitLength != 1024) continue;
      final d = _modInverse(_e, (p - BigInt.one) * (q - BigInt.one));
      if (d == null || !_usable(n, d)) continue;
      return (n, d);
    }
    throw StateError('could not make the dev card key');
  }

  /// Sign a block and read it back, which is exactly what the chain does before it accepts one.
  static bool _usable(BigInt n, BigInt d) {
    final len = (n.bitLength + 7) ~/ 8;
    if (len < 64) return false; // the contract refuses anything shorter
    final m = _block(len, const [0, 0, 0, 0], Random.secure());
    if (m >= n) return false;
    return m.modPow(d, n).modPow(_e, n) == m;
  }

  /// The signed dynamic authentication data block: header, 9 bytes of the card's own randomness,
  /// BB padding to length, then SHA-1 over everything except the trailing 0xBC and the challenge.
  static BigInt _block(int len, List<int> challenge, Random rnd) {
    final dyn = List<int>.generate(9, (_) => rnd.nextInt(256));
    final body = <int>[0x05, 0x01, dyn.length, ...dyn];
    body.addAll(List<int>.filled(len - 22 - body.length, 0xbb));
    final hash = crypto.sha1.convert([...body, ...challenge]).bytes;
    final block = <int>[0x6a, ...body, ...hash, 0xbc];
    if (block.length != len)
      throw StateError('dev card block is ${block.length}, wanted $len');
    return BigInt.parse(
        block.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);
  }

  /// d such that e·d ≡ 1 (mod φ), by the extended Euclidean algorithm; null when e shares a factor
  /// with φ (vanishingly rare, but then the key is simply not usable).
  static BigInt? _modInverse(BigInt a, BigInt m) {
    var oldR = a % m;
    var r = m;
    var oldS = BigInt.one;
    var s = BigInt.zero;
    while (r != BigInt.zero) {
      final q = oldR ~/ r;
      final (newR, newS) = (oldR - q * r, oldS - q * s);
      oldR = r;
      r = newR;
      oldS = s;
      s = newS;
    }
    if (oldR != BigInt.one) return null;
    return oldS % m;
  }

  static String _hexOf(BigInt v, int bytes) =>
      v.toRadixString(16).padLeft(bytes * 2, '0');

  static Uint8List _fromHex(String h) {
    final s = h.startsWith('0x') ? h.substring(2) : h;
    return Uint8List.fromList(List.generate(s.length ~/ 2,
        (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));
  }
}
