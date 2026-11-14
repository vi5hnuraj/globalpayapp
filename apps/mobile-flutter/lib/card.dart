// Talks to a contactless bank card over NFC (ISO-DEP), rebuilds the card's RSA public key from its
// certificate chain, and has the card sign a 4-byte challenge (DDA).
//
// Port of mobile/lib/emv.js. PANs and certificates stay in memory; only the public key and the
// signature leave this file. The CAPK table is the same file the JavaScript app ships.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import 'dev_card.dart';

Uint8List _fromHex(String h) {
  final s = h.startsWith('0x') ? h.substring(2) : h;
  return Uint8List.fromList(List.generate(s.length ~/ 2,
      (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));
}

String _hex(Uint8List u8) =>
    u8.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _concat(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (n, p) => n + p.length);
  final out = Uint8List(total);
  var at = 0;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}

BigInt _big(Uint8List u8) =>
    u8.isEmpty ? BigInt.zero : BigInt.parse(_hex(u8), radix: 16);

Uint8List _toBytes(BigInt x, int len) {
  final s = x.toRadixString(16).padLeft(len * 2, '0');
  return _fromHex(s.substring(s.length - len * 2));
}

BigInt _modPow(BigInt b, BigInt e, BigInt m) {
  var r = BigInt.one;
  var base = b % m;
  var exp = e;
  while (exp > BigInt.zero) {
    if (exp & BigInt.one == BigInt.one) r = (r * base) % m;
    base = (base * base) % m;
    exp = exp >> 1;
  }
  return r;
}

Uint8List _rsa(Uint8List data, BigInt e, BigInt n, int len) =>
    _toBytes(_modPow(_big(data), e, n), len);

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------- TLV

Iterable<(int, Uint8List)> _tlv(Uint8List d) sync* {
  var i = 0;
  while (i < d.length) {
    if (d[i] == 0x00 || d[i] == 0xff) {
      i++;
      continue;
    }
    var tag = d[i];
    final constructed = d[i] & 0x20 != 0;
    if (d[i] & 0x1f == 0x1f) {
      do {
        i++;
        if (i >= d.length) return;
        tag = (tag << 8) | d[i];
      } while (d[i] & 0x80 != 0);
    }
    i++;
    if (i >= d.length) return;
    var len = d[i++];
    if (len & 0x80 != 0) {
      final nb = len & 0x7f;
      len = 0;
      for (var k = 0; k < nb && i < d.length; k++) {
        len = (len << 8) | d[i++];
      }
    }
    if (i + len > d.length) return;
    final v = Uint8List.sublistView(d, i, i + len);
    i += len;
    yield (tag & 0xffffffff, v);
    if (constructed) yield* _tlv(v);
  }
}

Uint8List? _find(Uint8List d, int tag) {
  for (final (t, v) in _tlv(d)) {
    if (t == tag) return v;
  }
  return null;
}

// ---------------------------------------------------------------- card

class CardKey {
  const CardKey({required this.modulusHex, required this.exponentHex});
  final String modulusHex;
  final String exponentHex;
}

/// Verifies the EMV DDA signature over one four-byte challenge using the public key recovered from
/// the card's certificate chain. The NEAR MVP performs this check locally; it does not claim that the
/// NEAR escrow contract authenticates a bank card.
bool verifyCardChallenge(
    CardKey key, String challengeHex, String signatureHex) {
  final challenge = _fromHex(challengeHex);
  final modulus = _fromHex(key.modulusHex);
  final exponent = _fromHex(key.exponentHex);
  final signature = _fromHex(signatureHex);
  if (challenge.length != 4 ||
      modulus.length < 64 ||
      exponent.isEmpty ||
      signature.length != modulus.length) {
    return false;
  }
  final recovered =
      _rsa(signature, _big(exponent), _big(modulus), modulus.length);
  final length = recovered.length;
  if (recovered[0] != 0x6a ||
      recovered[1] != 0x05 ||
      recovered[length - 1] != 0xbc) {
    return false;
  }
  final body = Uint8List.sublistView(recovered, 1, length - 21);
  final expected = Uint8List.sublistView(recovered, length - 21, length - 1);
  return _eq(crypto.sha1.convert(_concat([body, challenge])).bytes, expected);
}

class CardResult {
  const CardResult({required this.key, this.signature});
  final CardKey key;

  /// Hex of the card's signature over the challenge, without 0x.
  final String? signature;
}

class _Apdu {
  _Apdu(this.data, this.sw);
  final Uint8List data;
  final int sw;
}

class CardRecord {
  CardRecord(this.sfi, this.rec, this.data);
  final int sfi;
  final int rec;
  final Uint8List data;
}

/// What one read of the card returned: the payment app, its start data, and the records behind it.
class CardData {
  CardData(this.aid, this.gpo, this.afl, this.recs);

  final Uint8List aid;
  final Uint8List gpo;
  final Uint8List afl;
  final List<CardRecord> recs;

  Uint8List get all => _concat(recs.map((r) => r.data).toList());
}

class EmvCard {
  EmvCard(this._iso, this._capk);

  final dynamic _iso;
  final Map<String, dynamic> _capk;

  Future<_Apdu> _apdu(List<int> bytes) async {
    final res = Uint8List.fromList(
        await _iso.transceive(Uint8List.fromList(bytes)) as List<int>);
    if (res.length < 2) return _Apdu(res, -1);
    final sw = (res[res.length - 2] << 8) | res[res.length - 1];
    return _Apdu(Uint8List.sublistView(res, 0, res.length - 2), sw);
  }

  Future<_Apdu> _select(Uint8List aid) =>
      _apdu([0x00, 0xa4, 0x04, 0x00, aid.length, ...aid, 0x00]);

  /// Terminal data a card may ask for in its PDOL: zero amount, India, a random number.
  Uint8List _dolData(Uint8List dol, Uint8List un) {
    final val = <int, List<int>>{
      0x9f66: [0x27, 0x80, 0, 0],
      0x9f02: [0, 0, 0, 0, 0, 0],
      0x9f03: [0, 0, 0, 0, 0, 0],
      0x9f1a: [0x03, 0x56],
      0x5f2a: [0x03, 0x56],
      0x9a: [0x26, 0x11, 0x06],
      0x9c: [0],
      0x9f37: un.toList(),
      0x9f35: [0x22],
      0x9f33: [0xe0, 0xf0, 0xc8],
      0x9f40: [0x60, 0, 0xf0, 0xa0, 0x01],
    };
    final out = <int>[];
    var i = 0;
    while (i < dol.length) {
      var tag = dol[i];
      if (dol[i] & 0x1f == 0x1f) {
        do {
          i++;
          tag = (tag << 8) | dol[i];
        } while (dol[i] & 0x80 != 0);
      }
      i++;
      if (i >= dol.length) break;
      final len = dol[i++];
      final v = val[tag & 0xffffffff] ?? const <int>[];
      for (var k = 0; k < len; k++) {
        out.add(k < v.length ? v[k] : 0);
      }
    }
    return Uint8List.fromList(out);
  }

  Future<CardData> read() async {
    final ppse =
        await _select(Uint8List.fromList(utf8.encode('2PAY.SYS.DDF01')));
    if (ppse.sw != 0x9000)
      throw const CardError("This doesn't look like a bank card.");
    final aid = _find(ppse.data, 0x4f);
    if (aid == null)
      throw const CardError("This card isn't a contactless payment card.");
    final sel = await _select(aid);
    if (sel.sw != 0x9000)
      throw const CardError("The card's payment app didn't open.");
    final pdol = _find(sel.data, 0x9f38);
    final rnd = Random.secure();
    final pd = pdol != null
        ? _dolData(
            pdol, Uint8List.fromList(List.generate(4, (_) => rnd.nextInt(256))))
        : Uint8List(0);
    final gpo = await _apdu(
        [0x80, 0xa8, 0x00, 0x00, pd.length + 2, 0x83, pd.length, ...pd, 0x00]);
    if (gpo.sw != 0x9000)
      throw const CardError('The card refused to start (GPO).');
    final g = gpo.data;
    final afl = (g.isNotEmpty && g[0] == 0x80)
        ? Uint8List.sublistView(g, 4, 2 + g[1])
        : (_find(g, 0x94) ?? Uint8List(0));
    final recs = <CardRecord>[];
    for (var i = 0; i + 4 <= afl.length; i += 4) {
      final sfi = afl[i] >> 3;
      for (var rec = afl[i + 1]; rec <= afl[i + 2]; rec++) {
        final r = await _apdu([0x00, 0xb2, rec, (sfi << 3) | 4, 0x00]);
        if (r.sw == 0x9000) recs.add(CardRecord(sfi, rec, r.data));
      }
    }
    if (recs.isEmpty) throw const CardError('The card returned no records.');
    return CardData(aid, g, afl, recs);
  }

  /// CA key -> issuer key -> card key. Throws if any certificate in the chain doesn't verify.
  CardKey publicKey(CardData card) {
    final all = card.all;
    final rid =
        _hex(Uint8List.sublistView(card.aid, 0, min(5, card.aid.length)));
    final idx = _find(all, 0x8f);
    final ca = idx == null
        ? null
        : _capk['$rid:${_hex(idx)}'] as Map<String, dynamic>?;
    if (ca == null)
      throw const CardError(
          "This card's network isn't supported yet (Visa and Mastercard only).");
    final caN = BigInt.parse('0x${ca['n']}');
    final caE = BigInt.parse('0x${ca['e']}');
    final caLen = (ca['n'] as String).length ~/ 2;

    final issuerCertData = _find(all, 0x90);
    if (issuerCertData == null)
      throw const CardError('The card is missing its issuer certificate.');
    final x = _rsa(issuerCertData, caE, caN, caLen);
    final rem = _find(all, 0x92) ?? Uint8List(0);
    final eIss = _find(all, 0x9f32);
    if (x[0] != 0x6a ||
        x[1] != 0x02 ||
        x[caLen - 1] != 0xbc ||
        eIss == null ||
        !_eq(
            crypto.sha1
                .convert(_concat([
                  Uint8List.sublistView(x, 1, caLen - 21),
                  rem,
                  eIss,
                ]))
                .bytes,
            Uint8List.sublistView(x, caLen - 21, caLen - 1))) {
      throw const CardError(
          "The bank's certificate on this card didn't check out.");
    }
    final ni = x[13];
    final nIss = _big(Uint8List.sublistView(
        _concat([Uint8List.sublistView(x, 15, 15 + caLen - 36), rem]), 0, ni));

    // Static data the card's own certificate signs over (ODA).
    var oda = Uint8List(0);
    for (var i = 0; i + 4 <= card.afl.length; i += 4) {
      final sfi = card.afl[i] >> 3;
      for (var rec = card.afl[i + 1];
          rec < card.afl[i + 1] + card.afl[i + 3];
          rec++) {
        for (final r in card.recs) {
          if (r.sfi == sfi && r.rec == rec) {
            oda = _concat(
                [oda, sfi <= 10 ? (_find(r.data, 0x70) ?? r.data) : r.data]);
            break;
          }
        }
      }
    }
    final tagList = _find(all, 0x9f4a);
    if (tagList != null && tagList.length == 1 && tagList[0] == 0x82) {
      final g = card.gpo;
      oda = _concat([
        oda,
        g.isNotEmpty && g[0] == 0x80
            ? Uint8List.sublistView(g, 2, 4)
            : (_find(g, 0x82) ?? Uint8List(0))
      ]);
    }

    final iccCertData = _find(all, 0x9f46);
    if (iccCertData == null)
      throw const CardError('The card is missing its certificate.');
    final y = _rsa(iccCertData, _big(eIss), nIss, ni);
    final rem2 = _find(all, 0x9f48) ?? Uint8List(0);
    final eIcc = _find(all, 0x9f47);
    if (y[0] != 0x6a ||
        y[1] != 0x04 ||
        y[ni - 1] != 0xbc ||
        eIcc == null ||
        !_eq(
            crypto.sha1
                .convert(_concat([
                  Uint8List.sublistView(y, 1, ni - 21),
                  rem2,
                  eIcc,
                  oda,
                ]))
                .bytes,
            Uint8List.sublistView(y, ni - 21, ni - 1))) {
      throw const CardError("The card's certificate didn't check out.");
    }
    final nic = y[19];
    final modulus = Uint8List.sublistView(
        _concat([Uint8List.sublistView(y, 21, 21 + ni - 42), rem2]), 0, nic);
    return CardKey(modulusHex: _hex(modulus), exponentHex: _hex(eIcc));
  }

  /// INTERNAL AUTHENTICATE: the card signs our 4-byte challenge with its private key.
  Future<String> sign(String challengeHex) async {
    final r = await _apdu(
        [0x00, 0x88, 0x00, 0x00, 0x04, ..._fromHex(challengeHex), 0x00]);
    if (r.sw != 0x9000) throw const CardError('The card refused to sign.');
    final d = r.data;
    final sdad = (d.isNotEmpty && d[0] == 0x80)
        ? (d.length > 1 && d[1] == 0x81
            ? Uint8List.sublistView(d, 3)
            : Uint8List.sublistView(d, 2))
        : _find(d, 0x9f4b);
    if (sdad == null)
      throw const CardError('The card signed, but sent nothing back.');
    return _hex(sdad);
  }
}

class CardError implements Exception {
  const CardError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Where the card is in the tap, for the on-screen banner.
enum CardPhase { idle, waiting, detected, almost, done, moved }

/// One tap: read the card, rebuild its key, then ask it to sign whatever [getChallenge] returns.
///
/// [getChallenge] runs while the card is still on the phone, which is what lets the quote arrive
/// before the tap ends instead of asking for a second tap.
class CardReader {
  CardReader({this.onPhase});

  final void Function(CardPhase)? onPhase;

  static const MethodChannel _nfc = MethodChannel('globalpay/native');

  Future<CardResult> withCard({
    required Future<String?> Function(CardKey key) getChallenge,
  }) async {
    // No NFC on this phone, and the build asked for the stand-in: answer from the local key and
    // skip the field entirely. Every caller goes through here, so signup, payment, send and freeze
    // are all covered by the one flag.
    if (DevCard.enabled) {
      onPhase?.call(CardPhase.waiting);
      try {
        final card = await DevCard.load();
        final challenge = await getChallenge(card.key);
        if (challenge == null)
          return CardResult(key: card.key); // the existing-wallet path
        onPhase?.call(CardPhase.done);
        return CardResult(key: card.key, signature: card.sign(challenge));
      } finally {
        onPhase?.call(CardPhase.idle);
      }
    }

    final available = (await _nfc.invokeMethod<bool>('nfcSupported')) ?? false;
    if (!available)
      throw const CardError('This phone cannot read contactless cards.');
    final enabled = (await _nfc.invokeMethod<bool>('nfcEnabled')) ?? true;
    if (!enabled)
      throw const CardError("Turn on NFC in your phone's settings.");

    final capk = jsonDecode(await rootBundle.loadString('assets/capk.json'))
        as Map<String, dynamic>;
    final done = Completer<CardResult>();
    var moved = false;

    onPhase?.call(CardPhase.waiting);
    await NfcManager.instance.startSession(
      pollingOptions: const {NfcPollingOption.iso14443},
      onDiscovered: (NfcTag tag) async {
        onPhase?.call(CardPhase.detected);
        final iso = IsoDepAndroid.from(tag);
        if (iso == null) {
          if (!done.isCompleted) {
            done.completeError(const CardError(
                'Hold the card flat against the back of the phone.'));
          }
          await NfcManager.instance.stopSession();
          return;
        }
        final card = EmvCard(iso, capk);
        try {
          final data = await card.read();
          final key = card.publicKey(data);
          final challenge = await getChallenge(key);
          final signature =
              challenge == null ? null : await card.sign(challenge);
          onPhase?.call(CardPhase.done);
          if (!done.isCompleted)
            done.complete(CardResult(key: key, signature: signature));
        } catch (e, st) {
          // Anything that isn't our own explanation is most likely the card leaving the field.
          moved = e is! CardError;
          if (!done.isCompleted) done.completeError(e, st);
        } finally {
          await NfcManager.instance.stopSession();
        }
      },
    );

    try {
      return await done.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      await NfcManager.instance.stopSession();
      throw const CardError('The card took too long. Try the tap again.');
    } finally {
      onPhase?.call(moved ? CardPhase.moved : CardPhase.idle);
    }
  }
}
