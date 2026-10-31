import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import 'output_cards.dart' show cardShell;

/// The ```visual card (owner, 2026-10-31): the agent's own SVG drawing shown right in the chat — architecture
/// and floor plans, artworks, posters, icons and mockups, any crisp 2D thing words and charts cannot be.
/// flutter_svg (already in the app for its own icons) renders the markup, so no new dependency.
class VisualCard extends StatelessWidget {
  final String body;
  const VisualCard(this.body, {super.key});

  /// True when a fenced block reads as SVG markup (the only thing this card can draw); anything else falls
  /// back to a code block.
  static bool isSvg(String body) {
    final t = body.trim();
    return t.startsWith('<') && t.contains('<svg') && t.contains('</svg>');
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return cardShell(
      context,
      kicker: tr('Visual'),
      collapse: false,
      child: Container(
        decoration: BoxDecoration(
          color: p.bg,
          borderRadius: Radii.fieldAll,
          border: Border.all(color: p.hairline),
        ),
        padding: const EdgeInsets.all(Space.x3),
        child: ClipRRect(
          borderRadius: Radii.fieldAll,
          child: SvgPicture.string(
            body.trim(),
            fit: BoxFit.contain,
            // A tall drawing gets a bounded window: the chat stays scannable, the drawing stays whole.
            height: 300,
            // A drawing that does not parse shows a quiet tile, never a broken chat.
            errorBuilder: (c, e, s) => SizedBox(
              height: 120,
              child: Center(child: Text(tr('The drawing could not be shown'), style: TextStyle(color: p.muted, fontSize: AppText.meta))),
            ),
          ),
        ),
      ),
    );
  }
}

/// An .svg file the agent made (shown through a ```file card), rendered in chat like a picture.
class SvgFileCard extends StatefulWidget {
  final String path;
  const SvgFileCard(this.path, {super.key});

  @override
  State<SvgFileCard> createState() => _SvgFileCardState();
}

class _SvgFileCardState extends State<SvgFileCard> {
  String? _body;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await File(widget.path).readAsString();
      if (mounted) setState(() => _body = t);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final name = widget.path.split('/').last;
    return cardShell(
      context,
      kicker: tr('Visual'),
      collapse: false,
      child: Container(
        decoration: BoxDecoration(
          color: p.bg,
          borderRadius: Radii.fieldAll,
          border: Border.all(color: p.hairline),
        ),
        padding: const EdgeInsets.all(Space.x3),
        child: _body != null && VisualCard.isSvg(_body!)
            ? ClipRRect(
                borderRadius: Radii.fieldAll,
                child: SvgPicture.string(_body!.trim(), fit: BoxFit.contain, height: 300, errorBuilder: (c, e, s) => _tile(context, name)),
              )
            : _tile(context, name),
      ),
    );
  }

  Widget _tile(BuildContext context, String name) {
    final p = Palette.of(context);
    return SizedBox(
      height: 72,
      child: Center(
        child: Text(
          _error == null ? tr('Getting it from your account') : tr('The drawing could not be shown'),
          style: TextStyle(color: p.muted, fontSize: AppText.meta),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
