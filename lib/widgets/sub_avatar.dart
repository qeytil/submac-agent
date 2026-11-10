import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

part 'sub_avatar_data.dart';

/// Telesia's own bot avatars (owner, 2026-10-23: "like Grok bot but our own brand").
///
/// Grok gives each bot a coloured blob with two small eyes. Telesia's set is drawn in-house: twelve shapes
/// (pebble, arch, squircle, spark, bean, bloom, dome, kite, ghost, capsule, cushion, leaf), twelve colours from the
/// Telesia palette (ink and Telesia red first), and six kinds of eyes, one of them the Telesia spark. An avatar is
/// stored on the bot as `look = 'av:<shape>.<colour>.<eyes>'` (presentation only: it never travels in a shared
/// bot package and a cloud push never overwrites it). Every bot without a chosen look gets a stable one from its id.
/// The shapes come from tools/avatars/gen.py, which also renders the contact sheet.
class AvatarSpec {
  const AvatarSpec(this.shape, this.color, this.eyes);
  final String shape;
  final String color;
  final String eyes;

  static const shapes = ['pebble', 'arch', 'squircle', 'spark', 'bean', 'bloom', 'dome', 'kite', 'ghost', 'capsule', 'cushion', 'leaf'];
  static const colors = ['ink', 'red', 'ember', 'saffron', 'sage', 'moss', 'sea', 'indigo', 'plum', 'rose', 'sand', 'stone'];
  static const eyeKinds = ['dots', 'wink', 'happy', 'sleepy', 'round', 'spark'];

  /// Names a person reads in the picker.
  static const colorNames = {
    'ink': 'Ink', 'red': 'Telesia red', 'ember': 'Ember', 'saffron': 'Saffron', 'sage': 'Sage', 'moss': 'Moss',
    'sea': 'Sea', 'indigo': 'Indigo', 'plum': 'Plum', 'rose': 'Rose', 'sand': 'Sand', 'stone': 'Stone',
  };

  static const prefix = 'av:';

  /// 'av:pebble.red.dots' -> spec; anything else -> null.
  static AvatarSpec? parse(String? look) {
    if (look == null || !look.startsWith(prefix)) return null;
    final p = look.substring(prefix.length).split('.');
    if (p.length != 3 || !shapes.contains(p[0]) || !colors.contains(p[1]) || !eyeKinds.contains(p[2])) return null;
    return AvatarSpec(p[0], p[1], p[2]);
  }

  /// A stable avatar for a bot that has not chosen one (same id, same face, on every phone).
  static AvatarSpec seeded(String seed) {
    var h = 2166136261;
    for (final c in seed.codeUnits) {
      h = ((h ^ c) * 16777619) & 0x7fffffff;
    }
    return AvatarSpec(shapes[h % shapes.length], colors[(h ~/ 13) % colors.length], eyeKinds[(h ~/ 169) % 4]);
  }

  String get look => '$prefix$shape.$color.$eyes';

  AvatarSpec copyWith({String? shape, String? color, String? eyes}) => AvatarSpec(shape ?? this.shape, color ?? this.color, eyes ?? this.eyes);

  @override
  bool operator ==(Object other) => other is AvatarSpec && other.look == look;

  @override
  int get hashCode => look.hashCode;

  static Color colorOf(String c) => Color(_colors[c] ?? 0xFF1B1A18);

  static const _paper = '#FBF8F2';
  static const _ink = '#1B1A18';

  /// The avatar as SVG markup (viewBox 0 0 100 100).
  String get svg {
    final (x, y, g0) = _eyesAt[shape]!;
    final g = g0 * 0.82;
    final fill = '#${(_colors[color]! & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final e = const {'saffron', 'sand', 'rose'}.contains(color) ? _ink : _paper;
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="${_shapes[shape]}" fill="$fill"/>'
        '<g transform="translate($x $y) scale(1.25) translate(${-x} ${-y})">${_eyes(x, y, g, e)}</g></svg>';
  }

  String _eyes(double x, double y, double g, String c) {
    final l = x - g, r = x + g;
    String bar(double at) => '<rect x="${at - 2.6}" y="${y - 5}" width="5.2" height="10" rx="2.6" fill="$c"/>';
    String arc(double at) =>
        '<path d="M${at - 4.5} ${y + 2}Q$at ${y - 5} ${at + 4.5} ${y + 2}" stroke="$c" stroke-width="3.6" fill="none" stroke-linecap="round"/>';
    switch (eyes) {
      case 'wink':
        return bar(l) +
            '<path d="M${r - 4.5} ${y + 1}Q$r ${y - 4} ${r + 4.5} ${y + 1}" stroke="$c" stroke-width="3.6" fill="none" stroke-linecap="round"/>';
      case 'happy':
        return arc(l) + arc(r);
      case 'sleepy':
        return [for (final a in [l, r]) '<path d="M${a - 4.5} ${y}H${a + 4.5}" stroke="$c" stroke-width="3.6" stroke-linecap="round"/>'].join();
      case 'round':
        final glint = c == _paper ? _ink : _paper;
        return [for (final a in [l, r]) '<circle cx="$a" cy="$y" r="5.4" fill="$c"/><circle cx="${a + 1.6}" cy="${y - 1.6}" r="1.6" fill="$glint"/>'].join();
      case 'spark':
        return bar(l) +
            '<path d="M$r ${y - 6}L${r + 1.6} ${y - 1.6}L${r + 6} ${y}L${r + 1.6} ${y + 1.6}L$r ${y + 6}L${r - 1.6} ${y + 1.6}L${r - 6} ${y}L${r - 1.6} ${y - 1.6}Z" fill="$c"/>';
      default:
        return bar(l) + bar(r);
    }
  }
}

/// One avatar, drawn crisp at any size. [dim] fades it for a bot that is paused or not hired.
class SubAvatar extends StatelessWidget {
  const SubAvatar({super.key, required this.spec, this.size = 44, this.dim = false});
  final AvatarSpec spec;
  final double size;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final pic = SvgPicture.string(spec.svg, width: size, height: size, excludeFromSemantics: true);
    return SizedBox(width: size, height: size, child: dim ? Opacity(opacity: 0.42, child: pic) : pic);
  }
}
