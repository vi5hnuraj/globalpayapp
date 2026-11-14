import 'dart:typed_data';

const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

String base58Encode(List<int> bytes) {
  if (bytes.isEmpty) return '';
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  final out = <String>[];
  while (value > BigInt.zero) {
    final part = value.remainder(BigInt.from(58)).toInt();
    value ~/= BigInt.from(58);
    out.add(_alphabet[part]);
  }
  for (final byte in bytes) {
    if (byte != 0) break;
    out.add('1');
  }
  return out.reversed.join();
}

Uint8List base58Decode(String text) {
  var value = BigInt.zero;
  for (final char in text.codeUnits) {
    final at = _alphabet.codeUnits.indexOf(char);
    if (at < 0) throw const FormatException('invalid base58 character');
    value = value * BigInt.from(58) + BigInt.from(at);
  }
  final body = <int>[];
  while (value > BigInt.zero) {
    body.add((value & BigInt.from(0xff)).toInt());
    value >>= 8;
  }
  var leading = 0;
  while (leading < text.length && text[leading] == '1') {
    leading++;
  }
  return Uint8List.fromList([
    ...List<int>.filled(leading, 0),
    ...body.reversed,
  ]);
}
