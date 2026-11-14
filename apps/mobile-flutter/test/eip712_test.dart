// The digest computed here must be byte-identical to the vault's, or every payment is rejected
// on-chain. The expected values below were produced by ethers' TypedDataEncoder for the same struct
// the contract defines, so this test is the guard against silent drift in either direction.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalpay/eip712.dart';

void main() {
  test('keccak256 matches the known digest of "abc"', () {
    expect(
      hexOf(keccak256(Uint8List.fromList(utf8.encode('abc')))),
      '0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45',
    );
  });

  test('an off-ramp intent hashes to the vault digest', () {
    const domain = VaultDomain(
      chainId: 31337,
      verifyingContract: '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    );
    final intent = OfframpIntent(
      id: '0x${'11' * 32}',
      user: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
      amount: BigInt.from(1000000),
      inrPaise: BigInt.from(25000),
      rateE6: BigInt.from(100122560),
      qrCommitment: '0x${'22' * 32}',
      deadline: BigInt.from(1893456000),
    );

    expect(
      hexOf(intent.hash(domain)),
      '0xe49cc666253f285d2d174a574cdab018bfcd1d0d3327d9dcea2710191aa85dd0',
    );
  });

  test('the amount shown is the amount signed', () {
    final intent = OfframpIntent(
      id: '0x${'11' * 32}',
      user: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
      amount: BigInt.from(2496940),
      inrPaise: BigInt.from(25000),
      rateE6: BigInt.from(100122560),
      qrCommitment: '0x${'22' * 32}',
      deadline: BigInt.from(1893456000),
    );
    expect(intent.tokenAmount, '2.49694');
    expect(intent.rupees, '250');
  });
}
