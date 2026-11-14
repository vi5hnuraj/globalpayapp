import 'package:flutter/material.dart';

import 'theme.dart';

export 'theme.dart';

/// Short transaction hash for anything the user might want to look up but not read.
String txShort(String hash) {
  if (hash.length <= 16) return hash;
  return '${hash.substring(0, 10)}…${hash.substring(hash.length - 6)}';
}

String shortAddress(String address) {
  if (address.length <= 12) return address;
  return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
}

/// A white rounded panel, the PWA's `.activity` / `.status` surface.
class Panel extends StatelessWidget {
  const Panel(
      {super.key,
      required this.child,
      this.padding = EdgeInsets.zero,
      this.border});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Gp.surface,
        borderRadius: BorderRadius.circular(16),
        border: border,
      ),
      child: child,
    );
  }
}

/// `.display` heading.
class DisplayHeading extends StatelessWidget {
  const DisplayHeading(this.text, {super.key, this.size = 26, this.color});

  final String text;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: displayText(size, color: color ?? Gp.ink));
}

/// `.lede` under a heading.
class Lede extends StatelessWidget {
  const Lede(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: bodyText(17, color: Gp.inkSoft));
}

/// `.fine` print.
class Fine extends StatelessWidget {
  const Fine(this.text, {super.key, this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(text,
            textAlign: center ? TextAlign.center : TextAlign.left,
            style: bodyText(13, color: Gp.inkSoft)),
      );
}

/// `.section-title`.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: displayText(18, weight: FontWeight.w700)),
      );
}

/// `.state-tag`: Active, or Frozen on the ice tint.
class StateTag extends StatelessWidget {
  const StateTag(this.label, {super.key, this.frozen = false});

  final String label;
  final bool frozen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: frozen ? Gp.ice : Gp.greenTint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: bodyText(13,
              weight: FontWeight.w600,
              height: 1.3,
              color: frozen ? Gp.iceInk : Gp.green)),
    );
  }
}

/// `.spinner`, the PWA's waiting row.
class StatusSpinner extends StatelessWidget {
  const StatusSpinner({super.key, this.label = 'Waiting'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Text(label, style: bodyText(15, weight: FontWeight.w500))),
        ],
      ),
    );
  }
}

/// `.meter-bar` plus its text: what today's allowance has left.
class MeterBar extends StatelessWidget {
  const MeterBar({super.key, required this.value, required this.label});

  /// 0..1 of the daily limit used.
  final double value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 8,
          decoration: BoxDecoration(
              color: Gp.line, borderRadius: BorderRadius.circular(99)),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            builder: (context, v, _) => FractionallySizedBox(
              widthFactor: v,
              alignment: Alignment.centerLeft,
              child: Container(
                decoration: BoxDecoration(
                    color: Gp.action, borderRadius: BorderRadius.circular(99)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: bodyText(13, color: Gp.inkSoft)),
      ],
    );
  }
}

/// The gold EMV chip, `.chip`.
class ChipGlyph extends StatelessWidget {
  const ChipGlyph({super.key, this.scale = 1});

  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38 * scale,
      height: 28 * scale,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6 * scale),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Gp.goldHi, Gp.gold, Gp.goldDeep],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Container(
        margin: EdgeInsets.fromLTRB(9 * scale, 7 * scale, 9 * scale, 7 * scale),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3 * scale),
          border: Border.all(color: const Color(0x73503A0F), width: 1.5),
        ),
      ),
    );
  }
}

/// The contactless waves, `.wave`.
class WaveGlyph extends StatelessWidget {
  const WaveGlyph(
      {super.key, this.size = 26, this.color = const Color(0xD9FFFFFF)});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.contactless, size: size, color: color);
}

/// `.card`: the wallet drawn as the bank card it is, with the frozen overlay when frozen.
class WalletCard extends StatelessWidget {
  const WalletCard(
      {super.key,
      required this.label,
      required this.address,
      this.frozen = false,
      this.network,
      this.symbol});

  final String label;
  final String address;
  final bool frozen;
  final String? network;
  final String? symbol;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.586,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [Gp.cardNavyHi, Gp.cardNavy, Color(0xFF0F1A33)],
            stops: [0, 0.6, 1],
          ),
          boxShadow: [
            BoxShadow(
                color: Gp.ink.withValues(alpha: 0.45),
                blurRadius: 40,
                offset: const Offset(0, 22),
                spreadRadius: -18),
          ],
        ),
        child: Stack(
          children: [
            // The soft light in the top-right corner.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topRight,
                  radius: 1.4,
                  colors: [Color(0x1FFFFFFF), Colors.transparent],
                ),
              ),
            ),
            Positioned(
              left: 22,
              right: 22,
              top: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (Gp.dark)
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(
                            'assets/branding/globalpay-icon-1024.png',
                            width: 34,
                            height: 34,
                            cacheWidth: 80,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Text('GlobalPay',
                            style: displayText(18,
                                weight: FontWeight.w700, color: Colors.white)),
                      ],
                    )
                  else
                    const ChipGlyph(),
                  const WaveGlyph(),
                ],
              ),
            ),
            if (Gp.dark)
              Positioned(
                top: 72,
                left: 22,
                child: Row(
                  children: [
                    const ChipGlyph(scale: 0.82),
                    const SizedBox(width: 12),
                    if (network != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12)),
                        ),
                        child: Text(network!,
                            style: bodyText(10,
                                weight: FontWeight.w600,
                                color: const Color(0xCCFFFFFF))),
                      ),
                  ],
                ),
              ),
            Positioned(
              left: 22,
              bottom: 46,
              child: Text(label,
                  style: bodyText(13, color: const Color(0xA6FFFFFF))),
            ),
            Positioned(
              left: 22,
              bottom: 16,
              right: 22,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(shortAddress(address),
                        overflow: TextOverflow.ellipsis,
                        style: displayText(21,
                            weight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: Colors.white)),
                  ),
                  if (symbol != null) ...[
                    const SizedBox(width: 12),
                    Text(symbol!,
                        style: bodyText(13,
                            weight: FontWeight.w700,
                            color: const Color(0xD9FFFFFF))),
                  ],
                ],
              ),
            ),
            if (frozen)
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xC7E1EEFA), Color(0xB8BFD8EE)],
                    ),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock, size: 24, color: Gp.iceInk),
                        const SizedBox(width: 10),
                        Text('Frozen',
                            style: displayText(26, color: Gp.iceInk)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `.hero-art`: card + phone, the onboarding illustration.
class HeroArt extends StatelessWidget {
  const HeroArt({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 132,
          height: 84,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Gp.cardNavyHi, Gp.cardNavy],
            ),
            boxShadow: [
              BoxShadow(
                  color: Gp.ink.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                  spreadRadius: -10),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [ChipGlyph(scale: 0.9), WaveGlyph(size: 22)],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text('+',
              style:
                  displayText(26, weight: FontWeight.w700, color: Gp.inkSoft)),
        ),
        Container(
          width: 52,
          height: 92,
          decoration: BoxDecoration(
            color: Gp.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Gp.ink, width: 3),
          ),
          child: const Center(
              child: Icon(Icons.fingerprint, size: 26, color: Gp.action)),
        ),
      ],
    );
  }
}

/// `.facts`: the three things that are true about this wallet.
class FactList extends StatelessWidget {
  const FactList({super.key, required this.facts});

  /// Each entry: bold lead, then the rest of the sentence.
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (lead, rest) in facts)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Gp.line))),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: lead, style: bodyText(16, weight: FontWeight.w600)),
                TextSpan(text: rest, style: bodyText(16, color: Gp.inkSoft)),
              ]),
            ),
          ),
      ],
    );
  }
}

/// Who gets the money, shown the same way before and after paying.
class PayeeCard extends StatelessWidget {
  const PayeeCard({super.key, required this.name, required this.upi});

  final String name;
  final String upi;

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: const EdgeInsets.all(16),
      border: Border.all(color: Gp.line, width: 1.5),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
                color: Gp.greenTint, shape: BoxShape.circle),
            child: Center(
              child: Text(
                  name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                  style: displayText(18,
                      weight: FontWeight.w700, color: Gp.green)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.isEmpty ? 'UPI merchant' : name,
                    style: bodyText(16, weight: FontWeight.w600)),
                if (upi.isNotEmpty)
                  Text(upi, style: bodyText(12, color: Gp.inkSoft)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: Gp.red),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: bodyText(13, color: Gp.red))),
        ],
      ),
    );
  }
}

/// A labelled row, used for every "you pay / they get" pair.
class KeyValueRow extends StatelessWidget {
  const KeyValueRow(this.label, this.value, {super.key, this.emphasis = false});

  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: emphasis
                  ? bodyText(15, weight: FontWeight.w600)
                  : bodyText(13, color: Gp.inkSoft)),
          Text(value,
              style: emphasis
                  ? displayText(20, weight: FontWeight.w700)
                  : bodyText(13, color: Gp.inkSoft)),
        ],
      ),
    );
  }
}
