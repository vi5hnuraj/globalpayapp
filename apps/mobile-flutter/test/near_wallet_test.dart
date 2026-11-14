import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalpay/near/base58.dart';
import 'package:globalpay/near/rpc.dart';
import 'package:globalpay/near/secure_key.dart';
import 'package:globalpay/screens/near_receive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('globalpay/native');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'encryptNearSecret':
          final plain = Uint8List.fromList(args['plaintext'] as Uint8List);
          return {
            'ciphertext':
                Uint8List.fromList(plain.map((byte) => byte ^ 0xa5).toList()),
            'iv': Uint8List.fromList(List<int>.generate(12, (i) => i)),
          };
        case 'decryptNearSecret':
          final encrypted = args['ciphertext'] as Uint8List;
          return Uint8List.fromList(
              encrypted.map((byte) => byte ^ 0xa5).toList());
        case 'deleteKey':
          return null;
      }
      throw PlatformException(code: 'unexpected', message: call.method);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('base58 preserves leading zeroes and round-trips', () {
    final bytes = Uint8List.fromList([0, 0, 1, 2, 3, 250, 255]);
    final encoded = base58Encode(bytes);
    expect(encoded.startsWith('11'), isTrue);
    expect(base58Decode(encoded), bytes);
  });

  test('NEAR account validation rejects EVM and malformed identifiers', () {
    expect(isNearAccountId('demo.globalpay-receipts.testnet'), isTrue);
    expect(isNearAccountId('a' * 64), isTrue);
    expect(isNearAccountId('0x${'11' * 20}'), isFalse);
    expect(isNearAccountId('Upper.testnet'), isFalse);
    expect(isNearAccountId('two..dots'), isFalse);
  });

  test('token amounts parse without floating point rounding', () {
    expect(parseNearUnits('1', 6), BigInt.from(1000000));
    expect(parseNearUnits('0.000001', 6), BigInt.one);
    expect(parseNearUnits('12.34', 6), BigInt.from(12340000));
    expect(() => parseNearUnits('0.0000001', 6), throwsA(isA<NearRpcError>()));
    expect(() => parseNearUnits('0', 6), throwsA(isA<NearRpcError>()));
  });

  test('compact display bounds long NEAR balances without changing units', () {
    expect(
      formatNearUnitsCompact(BigInt.parse('994026752157922499999996'), 24),
      '0.994026',
    );
    expect(formatNearUnitsCompact(BigInt.parse('99999000'), 6), '99.999');
  });

  test('GlobalPay NEAR receive code is network and token bound', () {
    const account = 'demo.globalpay-receipts.testnet';
    expect(nearRecipientOf(nearReceivePayload(account)), account);
    expect(nearRecipientOf(account), account);
    expect(
      nearRecipientOf(
          'globalpay://near/receive?network=mainnet&account=$account&token=usdc.fakes.testnet'),
      isNull,
    );
    expect(nearRecipientOf('upi://pay?pa=merchant@okaxis'), isNull);
  });

  test('the Ed25519 seed is stored encrypted and signs only after unlock',
      () async {
    final key = NearSecureKey(channel: channel);
    final record = await key.create(
      accountId: 'demo.testnet',
      cardFingerprint: 'aabbccdd',
    );
    expect(record.accountId, 'demo.testnet');
    expect(record.cardFingerprint, 'aabbccdd');
    expect(record.publicKey, startsWith('ed25519:'));
    expect(record.ciphertext, hasLength(32));
    final stored =
        (await SharedPreferences.getInstance()).getString('near_wallet_v1')!;
    expect(stored, isNot(contains('private')));
    expect((await key.record())!.cardFingerprint, 'aabbccdd');

    final message = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final signature = await key.sign(message, title: 'Test');
    expect(signature, hasLength(64));
    final public = SimplePublicKey(
      base58Decode(record.publicKey.substring('ed25519:'.length)),
      type: KeyPairType.ed25519,
    );
    expect(
      await Ed25519().verify(
        message,
        signature: Signature(signature, publicKey: public),
      ),
      isTrue,
    );
  });

  test('function-call transaction contains one Ed25519 action', () {
    final public = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final block = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
    final encoded = encodeFunctionCallTransaction(
      signerId: 'demo.testnet',
      publicKey: 'ed25519:${base58Encode(public)}',
      nonce: BigInt.from(42),
      receiverId: 'token.testnet',
      blockHash: block,
      method: 'ft_transfer_call',
      args: Uint8List.fromList([123, 125]),
      gas: BigInt.from(100000000000000),
      deposit: BigInt.one,
    );
    // Generated independently by near-api-js 7.1.0 for these exact fields.
    expect(
      encoded.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      '0c00000064656d6f2e746573746e657400000102030405060708090a0b0c0d0e0f'
      '101112131415161718191a1b1c1d1e1f2a000000000000000d000000746f6b65'
      '6e2e746573746e6574fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9'
      'e8e7e6e5e4e3e2e1e001000000021000000066745f7472616e736665725f6361'
      '6c6c020000007b7d00407a10f35a000001000000000000000000000000000000',
    );
  });
}
