import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/rewards.dart';

import '../app_state.dart';
import '../config.dart';
import '../services/bot_package.dart';
import '../services/bot_store.dart';
import '../services/bots.dart';
import '../services/events.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import 'bot_activity_screen.dart';
import 'bot_setup_screens.dart';
import 'bots_screen.dart';
import '../ui/tokens.dart';
import '../ui/launch_flags.dart';
import '../ui/i18n.dart';

/// The Bot Store: ready-made colleagues to hire. SubMac's own bots first, then bots people published.
class BotStoreScreen extends StatefulWidget {
  const BotStoreScreen({super.key});

  @override
  State<BotStoreScreen> createState() => _BotStoreScreenState();
}

class _BotStoreScreenState extends State<BotStoreScreen> {
  String _q = '';

  @override
  void initState() {
    super.initState();
    BotStore.I.refresh();
  }

  bool _match(StoreBot s) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return '${s.name} ${s.role} ${s.blurb} ${s.author}'.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([BotStore.I, Bots.I]),
      builder: (context, _) {
        final store = BotStore.I;
        final own = store.builtIns.where((s) => !LaunchFlags.hiddenStoreBots.contains(s.id.replaceFirst('builtin:', ''))).where(_match).toList();
        final others = store.community.where(_match).toList();
        return Scaffold(
          appBar: AppBar(title: Text(tr('Bot Store')), actions: [
            IconButton(
              tooltip: 'Add from code or file',
              icon: const Icon(Icons.qr_code_2_rounded),
              onPressed: () => addSharedBot(context),
            ),
          ]),
          body: RefreshIndicator(
            onRefresh: store.refresh,
            child: ListView(padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 40), children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 4, 12),
                child: Text('Your own copy. Learns you. Shares nothing.',
                    style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
              ),
              TextField(
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: InputDecoration(
                  hintText: 'Search bots',
                  prefixIcon: const Icon(Icons.search_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              if (own.isNotEmpty) ...[
                _Head('Made by SubMac'),
                for (final s in own) StoreCard(item: s),
                const SizedBox(height: 14),
              ],
              _Head('Community'),
              if (store.loading && store.community.isEmpty)
                const SkeletonList(rows: 3, padding: EdgeInsetsDirectional.fromSTEB(0, 4, 0, 8))
              else if (store.error != null)
                Padding(padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 12), child: Text(store.error!, style: TextStyle(color: p.muted)))
              else if (others.isEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 12),
                  child: Text(_q.isEmpty ? 'Nothing here yet.' : 'No bots match.',
                      style: TextStyle(color: p.muted)),
                ),
              for (final s in others) StoreCard(item: s),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: p.text, side: BorderSide(color: p.border), minimumSize: const Size.fromHeight(46)),
                onPressed: () => addSharedBot(context),
                icon: const Icon(Icons.card_giftcard_rounded, size: 18),
                label: Text(tr('Add from code or file')),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 8),
        child: Text(text, style: AppText.sectionStyle.copyWith(color: Palette.of(context).muted)),
      );
}

/// A Bot Store card: icon, name, role, one line, author, hires, and Hire.
class StoreCard extends StatelessWidget {
  const StoreCard({super.key, required this.item});
  final StoreBot item;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = item;
    final copy = BotStore.I.hiredCopy(s);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: p.sheet,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _details(context, s),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: p.border, width: 0.8)),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.bg, border: Border.all(color: p.border, width: 0.8)),
                child: Icon(botIcon(s.icon), size: 22, color: p.text),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s.name} · ${s.role}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(s.blurb, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.3)),
                  const SizedBox(height: 4),
                  Text(
                    [
                      'by ${s.author.isEmpty ? 'a SubMac user' : s.author}${s.mine ? ' (you)' : ''}',
                      if (!s.builtIn && s.hires > 0) '${s.hires} added',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: AppText.micro),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              // The app theme gives buttons minimumSize Size.fromHeight(52) (infinite min width) for full-width
              // buttons; inside this Row that starved the text column. Keep the action compact and capped.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: copy != null
                    ? TextButton(
                        style: TextButton.styleFrom(
                            minimumSize: _minSize, maximumSize: _maxSize, padding: _pad, tapTargetSize: MaterialTapTargetSize.shrinkWrap, textStyle: _btnText),
                        onPressed: () => _openCopy(context, copy), child: _label('Open'))
                    : FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: p.text,
                            foregroundColor: p.bg,
                            minimumSize: _minSize,
                            maximumSize: _maxSize,
                            padding: _pad,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: _btnText),
                        onPressed: () => hireFromStore(context, s),
                        child: _label('Get'),
                      ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Compact button sizing for card rows: overrides the theme's full-width minimum (Size.fromHeight).
  static const _minSize = Size(64, 38);
  static const _maxSize = Size(96, 48);
  static const _pad = EdgeInsets.symmetric(horizontal: 14);
  static const _btnText = TextStyle(fontFamily: Brand.sans, fontSize: AppText.body, fontWeight: FontWeight.w600);

  static Widget _label(String t) => Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false);

  static void _openCopy(BuildContext context, Bot b) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id)));

  Future<void> _details(BuildContext context, StoreBot s) async {
    final p = Palette.of(context);
    final pkg = await BotStore.I.package(s);
    if (!context.mounted) return;
    final inc = BotStore.includes(pkg);
    final warn = s.builtIn ? const <String>[] : BotPackage.warnings(pkg);
    await showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (ctx, sc) => ListView(controller: sc, padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 30), children: [
          Center(child: Icon(botIcon(s.icon), size: 40, color: p.text)),
          const SizedBox(height: 10),
          Center(child: Text(s.name, style: Brand.serif(size: 28, color: p.text))),
          Center(child: Text(s.role, style: TextStyle(color: p.muted))),
          const SizedBox(height: 14),
          Text('${pkg?['persona'] ?? s.blurb}', style: TextStyle(color: p.text, height: 1.4)),
          if (inc.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('Comes with', style: TextStyle(color: p.muted, fontWeight: FontWeight.w600)),
            for (final i in inc)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text('· $i', style: TextStyle(color: p.text))),
          ],
          if (warn.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('Couldn\'t verify', style: TextStyle(color: Colors.red.shade400, fontWeight: FontWeight.w600)),
            for (final w in warn)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text('· It $w', style: TextStyle(color: p.text))),
          ],
          const SizedBox(height: 18),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size.fromHeight(46)),
            onPressed: () {
              Navigator.pop(ctx);
              final copy = BotStore.I.hiredCopy(s);
              if (copy != null) {
                _openCopy(context, copy);
              } else {
                hireFromStore(context, s);
              }
            },
            child: Text(BotStore.I.hiredCopy(s) != null ? 'Open ${s.name}' : 'Get ${s.name}'),
          ),
        ]),
      ),
    );
  }
}

/// Hires a copy and opens it; then lists any app it still needs connecting.
Future<void> hireFromStore(BuildContext context, StoreBot s) async {
  final messenger = ScaffoldMessenger.of(context);
  showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
  final (b, err) = await BotStore.I.hire(s);
  if (!context.mounted) return;
  Navigator.pop(context);
  if (b == null) {
    messenger.showSnackBar(_addError(err ?? 'Not ready yet.', s.name));
    return;
  }
  await afterJoin(context, b, '${b.name} is ready.');
}

/// A "Hire in SubMac" link from a public bot page (submac.site/b/<code>): ask once, then hire like the Store does.
Future<void> hireFromLink(BuildContext context, String code) async {
  final messenger = ScaffoldMessenger.of(context);
  final (listing, shareCode, err) = await BotStore.I.resolveLink(code);
  if (!context.mounted) return;
  if (err != null) {
    messenger.showSnackBar(SnackBar(content: Text(err)));
    return;
  }
  if (listing != null && shareCode == null) {
    final have = BotStore.I.hiredCopy(listing);
    if (have != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => BotProfileScreen(botId: have.id)));
      messenger.showSnackBar(SnackBar(content: Text('${have.name} is already on your team.')));
      return;
    }
  }
  final name = listing?.name ?? 'this bot';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Get $name?'),
      content: Text(listing != null && listing.blurb.isNotEmpty
          ? '${listing.blurb}\n\nYou get your own copy. It never gets its creator\'s logins, keys or chats.'
          : 'You get your own copy of the bot from that link. It never gets its creator\'s logins, keys or chats.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Not now'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Get')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  if (shareCode == null) {
    // A public bot page link to a Store listing: a hire that came from a share.
    final before = {for (final x in Bots.I.bots) x.id};
    BotStore.I.nextHireSource = 'link';
    await hireFromStore(context, listing!);
    BotStore.I.nextHireSource = 'store';
    for (final x in Bots.I.bots.where((x) => !before.contains(x.id))) {
      Events.I.log('hired_from_share', botId: x.id, props: {'how': 'link'});
    }
    return;
  }
  final (b, e) = await BotStore.I.hireByCode(shareCode);
  if (!context.mounted) return;
  if (b == null) {
    messenger.showSnackBar(SnackBar(content: Text(e ?? 'Couldn\'t add it.')));
    return;
  }
  await afterJoin(context, b, '${b.name} is ready.');
}

/// After a bot joins (hired, shared code or file): open its profile and show what still needs connecting.
Future<void> afterJoin(BuildContext context, Bot b, String msg) async {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  final need = Bots.I.appsNeeded(b);
  Navigator.push(context, MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id)));
  if (need.isEmpty) return;
  await Future<void>.delayed(const Duration(milliseconds: 400));
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Connect ${b.name}\'s apps', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('${b.name} works with these. Connect them with your own account; until then ${b.name} tells you when one is needed.',
              style: TextStyle(color: Palette.of(ctx).muted)),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: Bots.I,
            builder: (ctx, _) => Column(children: [for (final a in b.apps) BotAppRow(app: a)]),
          ),
        ]),
      ),
    ),
  );
}

/// A failed add. When the store flags a bot as unsafe ("You can report it."), the snackbar carries a Report
/// button that writes to support with the bot's name or code (PLAN.md 3.3).
SnackBar _addError(String err, String what) => SnackBar(
      content: Text(err),
      action: err.contains('report it')
          ? SnackBarAction(
              label: 'Report',
              onPressed: () => launchUrl(
                  Uri.parse('mailto:${AppConfig.supportEmail}?subject=${Uri.encodeComponent('Report a bot: $what')}'),
                  mode: LaunchMode.externalApplication),
            )
          : null,
    );

/// "Add from code or file": the one way to add a bot someone shared. Type a code, or pick the file they sent.
Future<void> addSharedBot(BuildContext context) async {
  final c = TextEditingController();
  final pick = await showModalBottomSheet<String>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsetsDirectional.fromSTEB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Add from code or file'), style: Theme.of(ctx).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text('Type the code, or pick the file.', style: TextStyle(color: Palette.of(ctx).muted)),
        const SizedBox(height: 12),
        TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'ABCD-2345'),
          onSubmitted: (v) => Navigator.pop(ctx, 'code'),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx, 'file'), child: const Text('Pick a file'))),
          const SizedBox(width: 10),
          Expanded(child: FilledButton(onPressed: () => Navigator.pop(ctx, 'code'), child: const Text('Add'))),
        ]),
      ]),
    ),
  );
  if (pick == null || !context.mounted) return;
  if (pick == 'file') {
    final before = {for (final b in Bots.I.bots) b.id};
    final msg = await TeamFiles.pickAndAdd(context);
    if (!context.mounted) return;
    final added = Bots.I.bots.where((b) => !before.contains(b.id)).toList();
    if (added.length == 1 && msg != null && !msg.contains('joined your teams')) {
      await afterJoin(context, added.first, msg);
    } else {
      TeamFiles.toast(context, msg);
    }
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final (b, err) = await BotStore.I.hireByCode(c.text);
  if (!context.mounted) return;
  if (b == null) {
    messenger.showSnackBar(_addError(err ?? 'Couldn\'t add it.', c.text.trim()));
    return;
  }
  await afterJoin(context, b, '${b.name} is ready.');
}

/// Share one of your bots: as a code, or as a file. Logins, keys and what it knows about you never go along.
Future<void> shareBotSheet(BuildContext context, Bot b) async {
  final how = await showModalBottomSheet<String>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
          child: Text('Your friend gets ${b.name}\'s skills, instructions and apps. Never your logins, keys, chats '
              'or anything ${b.name} knows about you.',
              style: TextStyle(color: Palette.of(ctx).muted)),
        ),
        ListTile(
          leading: const Icon(Icons.link_rounded),
          title: const Text('Share a link'),
          subtitle: Text(b.storeId.isNotEmpty
              ? 'Its public page. You get a bonus when a copy is taken'
              : 'A page anyone can open to get a copy'),
          onTap: () => Navigator.pop(ctx, 'link'),
        ),
        ListTile(
          leading: const Icon(Icons.password_rounded),
          title: const Text('Share a code'),
          subtitle: const Text('A short code they type in the Bot Store'),
          onTap: () => Navigator.pop(ctx, 'code'),
        ),
        ListTile(
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: const Text('Share as a file'),
          subtitle: const Text('Send it in any app'),
          onTap: () => Navigator.pop(ctx, 'file'),
        ),
      ]),
    ),
  );
  if (how == null || !context.mounted) return;
  if (how == 'file') {
    await TeamFiles.shareBot(context, b);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  if (how == 'link') {
    // Published bots have a page by listing id; others get a share code, whose page works too (submac.site/b/<code>).
    // The link carries the sharer's invite code (?ref=), so a new person who joins through it counts for them.
    if (Rewards.I.myCode == null) await Rewards.I.refresh();
    var key = b.storeId;
    if (key.isEmpty) {
      final (code, err) = await BotStore.I.shareCode(b);
      if (code == null) {
        messenger.showSnackBar(SnackBar(content: Text(err ?? 'Not ready yet.')));
        return;
      }
      key = code.replaceAll('-', '');
    }
    await SharePlus.instance.share(ShareParams(text: 'Meet ${b.name}, my ${b.role.isEmpty ? 'bot' : b.role} on SubMac. Get your own copy: ${Rewards.I.botLink(key)}', subject: b.name));
    return;
  }
  final (code, err) = await BotStore.I.shareCode(b);
  if (code == null) {
    messenger.showSnackBar(SnackBar(content: Text(err ?? 'Not ready yet.')));
    return;
  }
  await SharePlus.instance.share(ShareParams(text: 'Get my bot ${b.name} (${b.role}) in SubMac: open SubMac > Bots > Bot Store > Add from code: $code', subject: b.name));
}

/// Publish (or update) your bot in the Bot Store.
Future<void> publishBotSheet(BuildContext context, Bot b) async {
  final state = context.read<AppState>();
  final author = TextEditingController(text: state.local.storeAuthorName);
  final blurb = TextEditingController(text: b.pitch);
  final pkg = b.export();
  final inc = BotStore.includes(pkg);
  final ok = await showModalBottomSheet<bool>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsetsDirectional.fromSTEB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(b.storeId.isEmpty ? 'Publish ${b.name} to the Bot Store' : 'Update ${b.name} in the Bot Store', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('Anyone can get a copy. They get its skills, instructions and apps. Never your logins, keys, '
              'chats or anything ${b.name} knows about you.',
              style: TextStyle(color: Palette.of(ctx).muted)),
          if (inc.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Goes along: ${inc.join('; ')}', style: TextStyle(color: Palette.of(ctx).muted, fontSize: AppText.micro)),
          ],
          const SizedBox(height: 12),
          TextField(controller: blurb, maxLength: 160, decoration: const InputDecoration(labelText: 'One line about it')),
          TextField(controller: author, maxLength: 40, decoration: const InputDecoration(labelText: 'Your name in the Store (optional)')),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(b.storeId.isEmpty ? 'Publish' : 'Update')),
          ),
        ]),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  state.local.storeAuthorName = author.text.trim();
  final messenger = ScaffoldMessenger.of(context);
  final err = await BotStore.I.publish(b, author: author.text, blurb: BotPackage.scrubPersonal(blurb.text));
  messenger.showSnackBar(SnackBar(content: Text(err ?? '${b.name} is in the Bot Store.')));
}
