// The shared GlobalPay-styled widgets render, hold the frozen state, and use the two bundled faces.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:globalpay/ui.dart';

Widget _host(List<Widget> children) => MaterialApp(
      theme: globalPayTheme(),
      home: Scaffold(
          body:
              ListView(padding: const EdgeInsets.all(16), children: children)),
    );

void main() {
  testWidgets('the wallet card draws its label, address and frozen overlay',
      (tester) async {
    await tester.pumpWidget(_host(const [
      WalletCard(
          label: 'Linked bank card',
          address: '0x1234567890abcdef1234567890abcdef12345678'),
      WalletCard(
        label: 'Linked bank card',
        address: '0x1234567890abcdef1234567890abcdef12345678',
        frozen: true,
      ),
    ]));

    expect(find.text('Linked bank card'), findsNWidgets(2));
    expect(find.text('0x1234…5678'),
        findsNWidgets(2)); // shortened, never the whole address
    expect(find.text('Frozen'), findsOneWidget);
  });

  testWidgets('onboarding shows the hero art and its three facts',
      (tester) async {
    await tester.pumpWidget(_host(const [
      HeroArt(),
      FactList(facts: [
        ('Tap your card', ' to the back of the phone.'),
        ('Confirm with your fingerprint', ' on this phone.'),
        ('Neither works alone. ', 'A lost card can\'t spend your money.'),
      ]),
      PayeeCard(name: 'Krishna Stores', upi: 'krishna@okaxis'),
      StateTag('Active'),
      StateTag('Frozen', frozen: true),
      MeterBar(value: 0.25, label: '25 of 100 USDT spent today'),
    ]));

    expect(find.text('Krishna Stores'), findsOneWidget);
    expect(find.text('krishna@okaxis'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Frozen'), findsOneWidget);
    expect(find.text('25 of 100 USDT spent today'), findsOneWidget);
    expect(
        find.text('Tap your card to the back of the phone.',
            findRichText: true),
        findsOneWidget);
    expect(
        find.text('Neither works alone. A lost card can\'t spend your money.',
            findRichText: true),
        findsOneWidget);
  });

  test('the theme carries the two bundled faces', () {
    final theme = globalPayTheme();
    expect(displayText(26).fontFamily, 'BricolageGrotesque');
    expect(bodyText(16).fontFamily, 'InstrumentSans');
    expect(theme.textTheme.bodyMedium?.fontFamily, 'InstrumentSans');
    expect(theme.textTheme.headlineMedium?.fontFamily, 'BricolageGrotesque');
  });
}
