import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:http/http.dart' as http;

import 'base58.dart';
import 'secure_key.dart';

const nearRpcUrl = String.fromEnvironment(
  'NEAR_RPC_URL',
  defaultValue: 'https://rpc.testnet.near.org',
);
const nearTokenAccount = 'usdc.fakes.testnet';
const nearVaultAccount = 'vault.globalpay-receipts.testnet';

class NearRpcError implements Exception {
  NearRpcError(this.message);
  final String message;
  @override
  String toString() => message;
}

class NearTokenMetadata {
  const NearTokenMetadata(
      {required this.name,
      required this.symbol,
      required this.decimals,
      required this.spec});
  final String name;
  final String symbol;
  final int decimals;
  final String spec;

  factory NearTokenMetadata.fromJson(Map<String, dynamic> value) =>
      NearTokenMetadata(
        name: value['name'] as String,
        symbol: value['symbol'] as String,
        decimals: (value['decimals'] as num).toInt(),
        spec: value['spec'] as String,
      );
}

class NearExecution {
  const NearExecution(
      {required this.hash,
      required this.success,
      required this.finalStatus,
      required this.raw});
  final String hash;
  final bool success;
  final String finalStatus;
  final Map<String, dynamic> raw;
}

bool isNearAccountId(String value) {
  if (RegExp(r'^0x[0-9a-f]{40}$').hasMatch(value)) return false;
  if (RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) return true;
  if (value.length < 2 || value.length > 64) return false;
  return RegExp(r'^[a-z0-9]+(?:[._-][a-z0-9]+)*$').hasMatch(value);
}

String formatNearUnits(BigInt value, int decimals) {
  final base = BigInt.from(10).pow(decimals);
  final whole = value ~/ base;
  final fraction = (value % base)
      .toString()
      .padLeft(decimals, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}

/// A bounded wallet-display form for high-decimal balances. Signing and API values remain exact
/// integers; this truncates display-only fractional digits so a 24-decimal gas balance cannot break
/// a compact row.
String formatNearUnitsCompact(BigInt value, int decimals,
    {int maxFraction = 6}) {
  final exact = formatNearUnits(value, decimals);
  final dot = exact.indexOf('.');
  if (dot < 0) return exact;
  if (maxFraction <= 0) return exact.substring(0, dot);
  final whole = exact.substring(0, dot);
  var fraction = exact.substring(dot + 1);
  if (fraction.length > maxFraction) {
    fraction = fraction.substring(0, maxFraction);
  }
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}

BigInt parseNearUnits(String value, int decimals) {
  final text = value.trim();
  final match = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(text);
  if (match == null || decimals < 0) {
    throw NearRpcError('Enter a valid token amount.');
  }
  final fraction = match.group(2) ?? '';
  if (fraction.length > decimals) {
    throw NearRpcError('Use no more than $decimals decimal places.');
  }
  final base = BigInt.from(10).pow(decimals);
  final units = BigInt.parse(match.group(1)!) * base +
      BigInt.parse((fraction.padRight(decimals, '0')).isEmpty
          ? '0'
          : fraction.padRight(decimals, '0'));
  if (units <= BigInt.zero) throw NearRpcError('Amount must be positive.');
  return units;
}

class NearRpc {
  NearRpc({this.url = nearRpcUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String url;
  final http.Client _client;
  int _id = 0;
  final Map<String, NearTokenMetadata> _metadataCache = {};

  void close() => _client.close();

  Future<dynamic> _call(String method, dynamic params) async {
    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse(url),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 'globalpay-${_id++}',
          'method': method,
          'params': params,
        }),
      );
    } catch (_) {
      throw NearRpcError('Cannot reach NEAR testnet.');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw NearRpcError('NEAR RPC returned an unreadable response.');
    }
    if (response.statusCode >= 400 || body['error'] != null) {
      final error = body['error'];
      final message = error is Map
          ? (error['message'] ?? error['data'] ?? error).toString()
          : 'NEAR RPC request failed.';
      throw NearRpcError(message);
    }
    return body['result'];
  }

  Future<Map<String, dynamic>> status() async =>
      Map<String, dynamic>.from(await _call('status', const []));

  Future<Map<String, dynamic>> viewAccount(String accountId) async {
    if (!isNearAccountId(accountId)) {
      throw NearRpcError('Invalid NEAR account ID.');
    }
    final result = Map<String, dynamic>.from(await _call('query', {
      'request_type': 'view_account',
      'finality': 'final',
      'account_id': accountId,
    }));
    if (result['error'] != null) {
      throw NearRpcError(result['error'].toString());
    }
    return result;
  }

  Future<Map<String, dynamic>> accessKey(
      String accountId, String publicKey) async {
    final result = Map<String, dynamic>.from(await _call('query', {
      'request_type': 'view_access_key',
      'finality': 'final',
      'account_id': accountId,
      'public_key': publicKey,
    }));
    if (result['error'] != null) {
      throw NearRpcError(result['error'].toString());
    }
    return result;
  }

  Future<dynamic> viewFunction(
      String accountId, String method, Map<String, dynamic> args) async {
    final result = Map<String, dynamic>.from(await _call('query', {
      'request_type': 'call_function',
      'finality': 'final',
      'account_id': accountId,
      'method_name': method,
      'args_base64': base64Encode(utf8.encode(jsonEncode(args))),
    }));
    if (result['error'] != null) {
      throw NearRpcError(result['error'].toString());
    }
    final bytes = (result['result'] as List).cast<int>();
    if (bytes.isEmpty) return null;
    return jsonDecode(utf8.decode(bytes));
  }

  Future<NearTokenMetadata> tokenMetadata(
      {String token = nearTokenAccount}) async {
    final cached = _metadataCache[token];
    if (cached != null) return cached;
    final metadata = NearTokenMetadata.fromJson(Map<String, dynamic>.from(
        await viewFunction(token, 'ft_metadata', const {})));
    _metadataCache[token] = metadata;
    return metadata;
  }

  Future<BigInt> tokenBalance(String accountId,
          {String token = nearTokenAccount}) async =>
      BigInt.parse((await viewFunction(
              token, 'ft_balance_of', {'account_id': accountId}))
          .toString());

  Future<Map<String, dynamic>?> tokenStorageBalance(String accountId,
      {String token = nearTokenAccount}) async {
    final result = await viewFunction(
        token, 'storage_balance_of', {'account_id': accountId});
    return result == null ? null : Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>?> lock(String id,
      {String vault = nearVaultAccount}) async {
    final result = await viewFunction(vault, 'get_lock', {'id': id});
    return result == null ? null : Map<String, dynamic>.from(result as Map);
  }

  Future<BigInt> totalLocked({String vault = nearVaultAccount}) async =>
      BigInt.parse(
          (await viewFunction(vault, 'total_locked', const {})).toString());

  Future<NearExecution> lockTokens({
    required NearSecureKey key,
    required NearKeyRecord record,
    required String id,
    required BigInt amount,
    String token = nearTokenAccount,
    String vault = nearVaultAccount,
  }) {
    if (amount <= BigInt.zero) throw NearRpcError('Amount must be positive.');
    return functionCall(
      key: key,
      record: record,
      receiverId: token,
      method: 'ft_transfer_call',
      args: {
        'receiver_id': vault,
        'amount': amount.toString(),
        'memo': 'GlobalPay NEAR MVP lock',
        'msg': jsonEncode({'id': id}),
      },
      gas: BigInt.from(100000000000000),
      deposit: BigInt.one,
      promptTitle: 'Lock USDC.e on NEAR',
      promptSubtitle: formatNearUnits(amount, 6),
    );
  }

  Future<NearExecution> refund({
    required NearSecureKey key,
    required NearKeyRecord record,
    required String id,
    String vault = nearVaultAccount,
  }) =>
      functionCall(
        key: key,
        record: record,
        receiverId: vault,
        method: 'request_refund',
        args: {'id': id},
        gas: BigInt.from(50000000000000),
        deposit: BigInt.zero,
        promptTitle: 'Refund NEAR escrow',
        promptSubtitle: id,
      );

  Future<NearExecution> transferTokens({
    required NearSecureKey key,
    required NearKeyRecord record,
    required String receiverId,
    required BigInt amount,
    String token = nearTokenAccount,
    int decimals = 6,
  }) {
    if (!isNearAccountId(receiverId)) {
      throw NearRpcError('Invalid NEAR recipient account.');
    }
    if (receiverId == record.accountId) {
      throw NearRpcError('The recipient is this wallet.');
    }
    if (amount <= BigInt.zero) throw NearRpcError('Amount must be positive.');
    return functionCall(
      key: key,
      record: record,
      receiverId: token,
      method: 'ft_transfer',
      args: {
        'receiver_id': receiverId,
        'amount': amount.toString(),
        'memo': 'GlobalPay wallet transfer',
      },
      gas: BigInt.from(30000000000000),
      deposit: BigInt.one,
      promptTitle: 'Send ${formatNearUnits(amount, decimals)} USDC.e',
      promptSubtitle: receiverId,
    );
  }

  Future<NearExecution> functionCall({
    required NearSecureKey key,
    required NearKeyRecord record,
    required String receiverId,
    required String method,
    required Map<String, dynamic> args,
    required BigInt gas,
    required BigInt deposit,
    required String promptTitle,
    String promptSubtitle = '',
  }) async {
    final access = await accessKey(record.accountId, record.publicKey);
    final nonce = BigInt.parse(access['nonce'].toString()) + BigInt.one;
    final blockHash = base58Decode(access['block_hash'] as String);
    if (blockHash.length != 32) {
      throw NearRpcError('NEAR returned an invalid block hash.');
    }

    final transaction = encodeFunctionCallTransaction(
      signerId: record.accountId,
      publicKey: record.publicKey,
      nonce: nonce,
      receiverId: receiverId,
      blockHash: blockHash,
      method: method,
      args: Uint8List.fromList(utf8.encode(jsonEncode(args))),
      gas: gas,
      deposit: deposit,
    );
    final digest = Uint8List.fromList(hashes.sha256.convert(transaction).bytes);
    final signature = await key.sign(
      digest,
      title: promptTitle,
      subtitle: promptSubtitle,
    );
    if (signature.length != 64) {
      throw NearRpcError('The NEAR signature is invalid.');
    }
    final signed = Uint8List.fromList([...transaction, 0, ...signature]);
    final result = Map<String, dynamic>.from(await _call('send_tx', {
      'signed_tx_base64': base64Encode(signed),
      'wait_until': 'FINAL',
    }));
    final transactionView =
        Map<String, dynamic>.from(result['transaction'] as Map);
    final success = !_containsFailure(result['status']) &&
        ((result['receipts_outcome'] as List?) ?? const [])
            .whereType<Map>()
            .every((item) =>
                !_containsFailure((item['outcome'] as Map?)?['status']));
    return NearExecution(
      hash: transactionView['hash'] as String,
      success: success,
      finalStatus: (result['final_execution_status'] ?? '').toString(),
      raw: result,
    );
  }
}

bool _containsFailure(dynamic value) =>
    value is Map && value.keys.any((key) => key.toString() == 'Failure');

Uint8List encodeFunctionCallTransaction({
  required String signerId,
  required String publicKey,
  required BigInt nonce,
  required String receiverId,
  required List<int> blockHash,
  required String method,
  required List<int> args,
  required BigInt gas,
  required BigInt deposit,
}) {
  if (!isNearAccountId(signerId) || !isNearAccountId(receiverId)) {
    throw ArgumentError('invalid NEAR account ID');
  }
  final keyText = publicKey.startsWith('ed25519:')
      ? publicKey.substring('ed25519:'.length)
      : publicKey;
  final key = base58Decode(keyText);
  if (key.length != 32 || blockHash.length != 32) {
    throw ArgumentError('invalid NEAR key or block hash');
  }
  final out = BytesBuilder(copy: false)
    ..add(_borshString(signerId))
    ..addByte(0) // ED25519 public-key enum
    ..add(key)
    ..add(_littleEndian(nonce, 8))
    ..add(_borshString(receiverId))
    ..add(blockHash)
    ..add(_littleEndian(BigInt.one, 4)) // one action
    ..addByte(2) // Action::FunctionCall
    ..add(_borshString(method))
    ..add(_borshBytes(args))
    ..add(_littleEndian(gas, 8))
    ..add(_littleEndian(deposit, 16));
  return out.toBytes();
}

Uint8List _borshString(String value) =>
    _borshBytes(Uint8List.fromList(utf8.encode(value)));

Uint8List _borshBytes(List<int> value) => Uint8List.fromList([
      ..._littleEndian(BigInt.from(value.length), 4),
      ...value,
    ]);

Uint8List _littleEndian(BigInt value, int length) {
  if (value < BigInt.zero || value >= (BigInt.one << (length * 8))) {
    throw ArgumentError('integer does not fit in $length bytes');
  }
  final out = Uint8List(length);
  var remaining = value;
  for (var i = 0; i < length; i++) {
    out[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  return out;
}
