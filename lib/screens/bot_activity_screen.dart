import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/bot_package.dart';
import '../services/bot_powers.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../services/whatsapp.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../widgets/lux_kit.dart';
import '../ui/tokens.dart';
import '../widgets/surface.dart';
import '../ui/i18n.dart';

/// Everything a bot did, run by run and step by step.
class BotActivityScreen extends StatelessWidget {
  const BotActivityScreen({super.key, required this.bot, this.find = ''});
  final Bot bot;
  /// A reply from the chat ("How"): the run that wrote it opens expanded.
  final String find;

  static String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// Did this run write [reply]? Compares the start of the run's result with the start of the reply.
  static bool wrote(String result, String reply) {
    final a = _norm(result), b = _norm(reply);
    if (a.isEmpty || b.isEmpty) return false;
    final n = [a.length, b.length, 40].reduce((x, y) => x < y ? x : y);
    return a.substring(0, n) == b.substring(0, n);
  }

  static String _ago(DateTime d) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final t = '${two(d.hour)}:${two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today $t';
    final y = now.subtract(const Duration(days: 1));
    if (d.year == y.year && d.month == y.month && d.day == y.day) return 'Yesterday $t';
    return '${d.day}/${d.month} $t';
  }

  static String _took(Duration d) => d.inSeconds < 60 ? '${d.inSeconds}s' : (d.inMinutes < 60 ? '${d.inMinutes} min' : '${d.inHours} h ${d.inMinutes % 60} min');

  static String tokens(int n) => n >= 1000000 ? '${(n / 1000000).toStringAsFixed(1)}M' : (n >= 1000 ? '${(n / 1000).round()}k' : '$n');

  /// Plain words for how much a bot worked today (plan 5: no token counts on screen).
  static String dayWord(int tokens) => tokens <= 0
      ? 'Resting'
      : tokens < 20000
          ? 'Light'
          : tokens < 150000
              ? 'Normal'
              : tokens < 600000
                  ? 'Busy'
                  : 'Full';

  /// "Busy day, 40% of its daily limit" or just "Busy day".
  static String usageLine(Bot b) {
    final used = b.tokensTodayNow;
    final word = dayWord(used);
    if (b.tokenBudgetK <= 0) return word;
    final pct = (100 * used / (b.tokenBudgetK * 1000)).clamp(0, 100).round();
    return '$word, $pct% of its daily limit';
  }

  /// Daily limit choices, in plain words.
  static const budgetChoices = {0: 'No limit', 50: 'Light', 200: 'Normal', 500: 'Busy', 1000: 'Heavy', 3000: 'Full'};

  static String _toolWords(String t) {
    final s = t.replaceFirst(RegExp(r'^mcp_[a-z0-9_]+__'), '').replaceAll('_', ' ').trim();
    return s.isEmpty ? t : s[0].toUpperCase() + s.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final runs = BotTraces.I.of(bot.id);
    final used = bot.tokensTodayNow;
    final hit = find.isEmpty ? null : runs.where((r) => wrote(r.result, find)).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(find.isEmpty ? '${bot.name}\'s activity' : 'How ${bot.name} did it'), actions: [
        if (runs.isNotEmpty)
          LuxWordButton('Clear', key: const ValueKey('activity-clear'), onPressed: () {
            BotTraces.I.clear(bot.id);
            Navigator.pop(context);
          }),
      ]),
      body: ListView(padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 40), children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 4, 14),
          child: Text(
            find.isNotEmpty && hit == null
                ? 'The steps for that reply are no longer kept. Here are ${bot.name}\'s recent runs.'
                : 'Today: ${usageLine(bot)}.',
            style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35),
          ),
        ),
        if (bot.tokenBudgetK > 0)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (used / (bot.tokenBudgetK * 1000)).clamp(0.0, 1.0).toDouble(),
                minHeight: 5,
                color: p.text,
                backgroundColor: p.muted.withValues(alpha: 0.18),
              ),
            ),
          ),
        if (runs.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: EmptyHint(text: 'Nothing yet. Work shows up here as it happens.'),
          ),
        for (final r in runs)
          SurfaceRow(
            margin: const EdgeInsets.only(bottom: Space.x2),
            child: ExpansionTile(
              initiallyExpanded: identical(r, hit),
              shape: const Border(),
              collapsedShape: const Border(),
              showTrailingIcon: false,
              tilePadding: EdgeInsets.zero,
              // The run's state in plain words under it (RESTYLE.md: no status icons or dots).
              title: Text(r.why, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text)),
              subtitle: Text(
                '${_ago(r.start)} · ${r.end == null ? tr('Working') : (r.failed ? '${tr('Stopped')} · ${_took(r.took)}' : _took(r.took))}',
                style: AppText.microStyle.copyWith(color: r.end != null && r.failed ? Palette.red : p.muted),
              ),
              childrenPadding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 14),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in r.steps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        _toolWords(s.tool),
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: AppText.meta, color: s.failed ? Palette.red : p.text),
                      ),
                      Text(s.output, style: TextStyle(color: p.text, fontSize: AppText.micro, height: 1.3)),
                    ]),
                  ),
                if (r.result.isNotEmpty) ...[
                  Text('Result', style: TextStyle(fontWeight: FontWeight.w600, fontSize: AppText.meta, color: p.text)),
                  Text(r.result, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.35)),
                ],
              ],
            ),
          ),
      ]),
    );
  }
}

/// Sharing and adding bots and offices as small files anyone can import.
class TeamFiles {
  static Future<void> share(BuildContext context, String name, Map<String, dynamic> data) async {
    try {
      final dir = await getTemporaryDirectory();
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim().replaceAll(' ', '-');
      final f = File('${dir.path}/${safe.isEmpty ? 'submac' : safe}.submac.json');
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')], subject: name));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sharing did not work this time. Try again in a moment.')));
    }
  }

  /// Shares the bot package as a file: who it is, how it works, its knowledge, skills, apps and lessons.
  /// Never its memory about you, its chats, or any login or key.
  static Future<void> shareBot(BuildContext context, Bot b) async {
    await share(context, b.name, b.export());
  }

  /// Pick a .json file a friend shared and add the bot or team it holds.
  static Future<String?> pickAndAdd(BuildContext context) async {
    final res = await FilePicker.pickFiles(withData: true, type: FileType.any);
    final f = res?.files.firstOrNull;
    if (f == null) return null;
    try {
      final text = f.bytes != null ? utf8.decode(f.bytes!) : await File(f.path!).readAsString();
      return await importText(text);
    } catch (_) {
      return 'That file isn\'t a SubMac bot or team.';
    }
  }

  static Future<String> importText(String text) async {
    final j = Map<String, dynamic>.from(jsonDecode(text.trim()) as Map);
    if ('${j['submac']}' == 'bot') {
      final warn = BotPackage.warnings(j);
      if (warn.isNotEmpty) return 'Not added: this bot looks unsafe (it ${warn.join(', ')}).';
      final b = await Bots.I.importBot(j);
      return b == null ? 'That bot could not be added.' : '${b.name} joined. Open them to start.';
    }
    if ('${j['submac']}' == 'office') {
      final o = await Offices.I.importOffice(j);
      return o == null ? 'That team could not be added.' : '${o.name} joined your teams. New tasks wait for your OK at first.';
    }
    return 'That file isn\'t a SubMac bot or team.';
  }

  static void toast(BuildContext context, String? msg) {
    if (msg == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// The powers and daily budget of a bot, for its settings.
class BotPowersSection extends StatelessWidget {
  const BotPowersSection({super.key, required this.bot});
  final Bot bot;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = bot;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final g in BotPowers.all)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(BotPowers.labels[g]!),
          subtitle: Text(BotPowers.blurbs[g]!, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
          value: !b.powersOff.contains(g),
          onChanged: (v) async {
            v ? b.powersOff.remove(g) : b.powersOff.add(g);
            await Bots.I.save();
          },
        ),
      // Plugins: skills on top of a power (WhatsApp needs Phone).
      for (final g in BotPowers.plugins) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(BotPowers.pluginLabels[g]!),
          subtitle: Text(BotPowers.pluginBlurbs[g]!, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
          value: !b.powersOff.contains(g) && !b.powersOff.contains(BotPowers.pluginPower[g]),
          onChanged: b.powersOff.contains(BotPowers.pluginPower[g])
              ? null
              : (v) async {
                  v ? b.powersOff.remove(g) : b.powersOff.add(g);
                  await Bots.I.save();
                },
        ),
        if (g == 'whatsapp' && !b.powersOff.contains(g) && !b.powersOff.contains('phone'))
          _WaTrust(bot: b),
      ],
      // Look only (fix/ui-restyle): the same choices and values as before, in the shared quiet row and sheet.
      LuxRow(
        padding: const EdgeInsets.symmetric(vertical: Space.x3),
        title: tr('Daily limit'),
        sub: '${BotActivityScreen.budgetChoices[b.tokenBudgetK] ?? 'Custom'} · today: ${BotActivityScreen.usageLine(b)}.',
        onTap: () async {
          const opts = BotActivityScreen.budgetChoices;
          final v = await showLuxChoices<int>(context,
              title: 'Daily limit', selected: b.tokenBudgetK, choices: [for (final e in opts.entries) LuxChoice(e.key, e.value)]);
          if (v == null) return;
          b.tokenBudgetK = v;
          await Bots.I.save();
        },
      ),
    ]);
  }
}


/// "Send on WhatsApp without asking": the user's trust for one bot (kept on this phone only).
class _WaTrust extends StatefulWidget {
  const _WaTrust({required this.bot});
  final Bot bot;

  @override
  State<_WaTrust> createState() => _WaTrustState();
}

class _WaTrustState extends State<_WaTrust> {
  @override
  void initState() {
    super.initState();
    WhatsAppTools.init().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SwitchListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 16),
      title: const Text('Send on WhatsApp without asking'),
      subtitle: Text('Off: you approve every message, file and call first (recommended)', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
      value: WhatsAppTools.trusted(widget.bot.id),
      onChanged: (v) async {
        await WhatsAppTools.setTrusted(widget.bot.id, v);
        if (mounted) setState(() {});
      },
    );
  }
}
