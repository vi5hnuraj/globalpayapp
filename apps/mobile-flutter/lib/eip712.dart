// The digest the vault checks, computed on the phone instead of trusted from the server.
//
// GlobalPay's ScanPayVault signs a typed `OfframpIntent`; the card signs its first 4 bytes and the
// phone signs all 32. If this file drifts from the contract, every payment fails on-chain, so
// test/eip712_test.dart pins it to a digest produced by ethers and by the deployed vault.
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/keccak.dart';

/// keccak256 (Ethereum's variant, not NIST SHA3-256).
Uint8List keccak256(Uint8List input) {
  final d = KeccakDigest(256);
  return d.process(input);
}

Uint8List _hexToBytes(String hex) {
  final h = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (h.length.isOdd) throw ArgumentError('odd-length hex: $hex');
  return Uint8List.fromList(List.generate(h.length ~/ 2,
      (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));
}

String bytesToHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// One 32-byte ABI word, big-endian. Every field of these structs is static, so no head/tail.
Uint8List _word(dynamic value) {
  final out = Uint8List(32);
  final BigInt n;
  if (value is Uint8List) {
    // An already-hashed value (bytes32): right-aligned like any other 32-byte word.
    if (value.length > 32) throw ArgumentError('value wider than 32 bytes');
    out.setRange(32 - value.length, 32, value);
    return out;
  }
  if (value is BigInt) {
    n = value;
  } else if (value is int) {
    n = BigInt.from(value);
  } else if (value is String && value.startsWith('0x')) {
    final bytes = _hexToBytes(value);
    if (bytes.length > 32) throw ArgumentError('value wider than 32 bytes');
    out.setRange(32 - bytes.length, 32, bytes);
    return out;
  } else if (value is String) {
    n = BigInt.parse(value);
  } else {
    throw ArgumentError('cannot encode ${value.runtimeType}');
  }
  if (n.isNegative || n >= (BigInt.one << 256))
    throw ArgumentError('value out of uint256 range');
  var x = n;
  for (var i = 31; i >= 0 && x > BigInt.zero; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}

Uint8List _encode(List<dynamic> values) {
  final out = Uint8List(32 * values.length);
  for (var i = 0; i < values.length; i++) {
    out.setRange(i * 32, i * 32 + 32, _word(values[i]));
  }
  return out;
}

/// The exact type strings from contracts/src/ScanPayVault.sol. Change them only with the contract.
const String offrampIntentType =
    'OfframpIntent(bytes32 id,address user,uint256 amount,uint64 inrPaise,uint64 rateE6,bytes32 qrCommitment,uint64 deadline)';
const String disputeIntentType =
    'DisputeIntent(bytes32 id,address user,uint64 deadline)';

Uint8List _typeHash(String type) =>
    keccak256(Uint8List.fromList(utf8.encode(type)));

/// EIP-712 domain of one vault: name "ScanPayVault", version "1", the chain and the vault address.
class VaultDomain {
  const VaultDomain(
      {required this.chainId,
      required this.verifyingContract,
      this.name = 'ScanPayVault',
      this.version = '1'});

  final int chainId;
  final String verifyingContract;
  final String name;
  final String version;

  factory VaultDomain.fromJson(Map<String, dynamic> json) => VaultDomain(
        chainId: int.parse(json['chainId'].toString()),
        verifyingContract: json['verifyingContract'] as String,
        name: (json['name'] as String?) ?? 'ScanPayVault',
        version: (json['version'] as String?) ?? '1',
      );

  Uint8List get separator {
    final typeHash = _typeHash(
        'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
    final nameHash = keccak256(Uint8List.fromList(utf8.encode(name)));
    final versionHash = keccak256(Uint8List.fromList(utf8.encode(version)));
    return keccak256(_concat([
      typeHash,
      nameHash,
      versionHash,
      _word(chainId),
      _word(verifyingContract)
    ]));
  }
}

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

/// A signed off-ramp intent, as GlobalPay's /quote returns it.
class OfframpIntent {
  const OfframpIntent({
    required this.id,
    required this.user,
    required this.amount,
    required this.inrPaise,
    required this.rateE6,
    required this.qrCommitment,
    required this.deadline,
  });

  final String id;
  final String user;
  final BigInt amount;
  final BigInt inrPaise;
  final BigInt rateE6;
  final String qrCommitment;
  final BigInt deadline;

  factory OfframpIntent.fromJson(Map<String, dynamic> json) => OfframpIntent(
        id: json['id'] as String,
        user: json['user'] as String,
        amount: BigInt.parse(json['amount'].toString()),
        inrPaise: BigInt.parse(json['inrPaise'].toString()),
        rateE6: BigInt.parse(json['rateE6'].toString()),
        qrCommitment: json['qrCommitment'] as String,
        deadline: BigInt.parse(json['deadline'].toString()),
      );

  /// The USDT amount this intent actually locks, in the token's smallest unit.
  String get tokenAmount => _formatUnits(amount, 6);

  /// The rupee amount the merchant receives, for display next to the token amount.
  String get rupees {
    final whole = inrPaise ~/ BigInt.from(100);
    final paise = inrPaise % BigInt.from(100);
    return paise == BigInt.zero
        ? whole.toString()
        : '$whole.${paise.toString().padLeft(2, '0')}';
  }

  Uint8List hash(VaultDomain domain) {
    final structHash = keccak256(_encode([
      _typeHash(offrampIntentType),
      id,
      user,
      amount,
      inrPaise,
      rateE6,
      qrCommitment,
      deadline,
    ]));
    return keccak256(_concat([
      Uint8List.fromList([0x19, 0x01]),
      domain.separator,
      structHash
    ]));
  }
}

/// The digest a payer signs to dispute a completed payment.
Uint8List disputeHash(VaultDomain domain,
    {required String id, required String user, required BigInt deadline}) {
  final structHash =
      keccak256(_encode([_typeHash(disputeIntentType), id, user, deadline]));
  return keccak256(_concat([
    Uint8List.fromList([0x19, 0x01]),
    domain.separator,
    structHash
  ]));
}

String _formatUnits(BigInt value, int decimals) {
  final base = BigInt.from(10).pow(decimals);
  final whole = value ~/ base;
  final frac = (value % base)
      .toString()
      .padLeft(decimals, '0')
      .replaceAll(RegExp(r'0+$'), '');
  return frac.isEmpty ? whole.toString() : '$whole.$frac';
}

/// Lowercase hex with 0x, the form the relayer and the contracts expect.
String hexOf(Uint8List bytes) => '0x${bytesToHex(bytes)}';
