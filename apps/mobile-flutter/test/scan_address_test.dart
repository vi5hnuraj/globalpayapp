import 'package:flutter_test/flutter_test.dart';

import 'package:globalpay/screens/scan_address.dart';

void main() {
  test('reads the recipient from the Receive QR payload', () {
    const address = '0xf77B378ae8A547466701Cf82c9e22687Efb65D0b';
    expect(recipientAddressOf(address), address);
    expect(recipientAddressOf('globalpay://receive?address=$address'), address);
  });

  test('does not mistake a UPI QR or a malformed address for a recipient', () {
    expect(recipientAddressOf('upi://pay?pa=cafe@okaxis&am=1'), isNull);
    expect(recipientAddressOf('0x1234'), isNull);
  });
}
