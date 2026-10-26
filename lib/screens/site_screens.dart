import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../services/sites.dart';
import '../theme.dart';
import '../ui/embed.dart';
import '../widgets/lux_kit.dart';
import '../widgets/motion.dart';
import '../ui/tokens.dart';
import '../widgets/sub_icon.dart';
import '../ui/i18n.dart';

/// Full-screen preview of a page SubMac built: try it at phone, tablet and computer width, then Publish.
class SitePreviewScreen extends StatefulWidget {
  const SitePreviewScreen({super.key, required this.path});
  final String path;

  @override
  State<SitePreviewScreen> createState() => _SitePreviewScreenState();
}

class _SitePreviewScreenState extends State<SitePreviewScreen> {
  InAppWebViewController? _web;
  String _size = 'phone';
  Site? _site;

  @override
  void initState() {
    super.initState();
    Sites.I.find(widget.path).then((s) {
      if (mounted) setState(() => _site = s);
    });
  }

  static const _widths = {'phone': 0, 'tablet': 820, 'computer': 1280};

  Future<void> _applySize() async {
    final w = _widths[_size] ?? 0;
    final content = w == 0 ? 'width=device-width, initial-scale=1' : 'width=$w';
    await _web?.evaluateJavascript(source: '''
      (function(){var m=document.querySelector('meta[name="viewport"]');
      if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}
      m.setAttribute('content','$content');})();''');
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final site = _site;
    return Scaffold(
      appBar: AppBar(
        title: Text(site?.title ?? 'Preview', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Reload', icon: SubIcon('refresh', color: p.text, size: IconSize.lg), onPressed: () => _web?.reload()),
          // Share: the live link once the page is published, else the page file itself.
          IconButton(
            tooltip: 'Share',
            icon: SubIcon('share', color: p.text, size: IconSize.lg),
            onPressed: () => site != null && site.isLive && site.url.isNotEmpty
                ? SharePlus.instance.share(ShareParams(text: site.url))
                : SharePlus.instance.share(ShareParams(files: [XFile(widget.path)])),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 8),
          child: LuxWords([
            for (final e in const [('phone', 'Phone'), ('tablet', 'Tablet'), ('computer', 'Computer')])
              LuxWord(e.$2, selected: _size == e.$1, onTap: () {
                setState(() => _size = e.$1);
                _applySize();
              }),
          ]),
        ),
        Expanded(
          child: InAppWebView(
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              allowFileAccess: true,
              allowFileAccessFromFileURLs: true,
              allowUniversalAccessFromFileURLs: true,
              useWideViewPort: true,
              loadWithOverviewMode: true,
              supportZoom: true,
              builtInZoomControls: true,
              displayZoomControls: false,
              mediaPlaybackRequiresUserGesture: false,
            ),
            initialUrlRequest: URLRequest(url: WebUri('file://${widget.path}')),
            onWebViewCreated: (c) => _web = c,
            onLoadStop: (_, __) => _applySize(),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 10),
            child: Row(children: [
              Expanded(
                child: site == null || site.url.isEmpty
                    ? Text('Only you can see this. Publish to put it online.', style: TextStyle(color: p.muted, fontSize: AppText.meta))
                    : GestureDetector(
                        onTap: site.isLive ? () => launchUrl(Uri.parse(site.url), mode: LaunchMode.externalApplication) : null,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(site.statusLine, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                          Text(site.url.replaceFirst('https://', ''),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
                        ]),
                      ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(120, 46)),
                onPressed: () async {
                  await showPublishSheet(context, widget.path);
                  final s = await Sites.I.find(widget.path);
                  if (mounted) setState(() => _site = s);
                },
                child: Text(site != null && site.isLive ? 'Update' : 'Publish'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// The Publish sheet: a free 7-day link or the user's own Vercel. Remembers the choice, shows progress in plain words,
/// and ends on the live link (open, copy, share).
Future<void> showPublishSheet(BuildContext context, String pagePath) async {
  final app = context.read<AppState>();
  final chatId = app.currentId;
  final site = await Sites.I.forPage(pagePath);
  if (!context.mounted) return;
  final before = site.publishCount;
  await showModalBottomSheet<bool>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PublishSheet(app: app, site: site, chatId: chatId),
  );
  // Offered after a publish that went through, however the sheet was closed.
  if (site.publishCount > before && context.mounted && Sites.I.shouldOfferProject(site, chatId)) {
    await _offerProject(context, site, chatId);
  }
}

Future<void> _offerProject(BuildContext context, Site site, String? chatId) async {
  await Sites.I.markOffered(site);
  if (!context.mounted) return;
  final yes = await showModalBottomSheet<bool>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Keep "${site.title}" as a project?', style: Brand.serif(size: 24, color: p.text)),
          const SizedBox(height: 8),
          Text('You keep coming back to this site. As a project, its chats and files stay together and SubMac remembers what it is for.',
              style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size.fromHeight(46)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Make it a project'),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(width: double.infinity, child: TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Not now'), style: TextStyle(color: p.muted)))),
        ]),
      );
    },
  );
  if (yes == true) {
    final proj = await Sites.I.makeProject(site, chatId: chatId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${proj.name}" is now a project.')));
    }
  }
}

class _PublishSheet extends StatefulWidget {
  const _PublishSheet({required this.app, required this.site, required this.chatId});
  final AppState app;
  final Site site;
  final String? chatId;

  @override
  State<_PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends State<_PublishSheet> {
  String _step = 'choose'; // choose | working | done | error
  String _working = '';
  String _error = '';
  String _host = '';
  bool _changing = false;

  Site get s => widget.site;

  @override
  void initState() {
    super.initState();
    // A site that already lives somewhere goes straight to updating it there.
    _host = s.host;
  }

  Future<void> _go(String host) async {
    setState(() {
      _host = host;
      _step = 'working';
      _error = '';
      _working = host == SiteHost.vercel ? 'Getting Vercel ready…' : 'Putting your site online…';
    });
    try {
      if (host == SiteHost.vercel && !Sites.vercelConnected(widget.app)) {
        setState(() => _working = 'Sign in to Vercel in the window that opens. SubMac carries on by itself.');
        final err = await widget.app.connectMcpPreset(Sites.vercelPreset);
        if (err != null) throw PublishException(err);
        unawaited(widget.app.refreshMcpTools());
        if (!Sites.vercelConnected(widget.app)) throw PublishException('Vercel didn\'t finish connecting. Tap Try again.');
      }
      if (host == SiteHost.vercel && mounted) setState(() => _working = 'Sending your site to Vercel… this can take a minute.');
      await Sites.I.publish(widget.app, s, host, chatId: widget.chatId);
      if (mounted) setState(() => _step = 'done');
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = 'error';
          _error = e is PublishException ? e.message : 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget body;
    switch (_step) {
      case 'working':
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.4)),
          const SizedBox(height: 16),
          Text(_working, textAlign: TextAlign.center, style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.4)),
          const SizedBox(height: 12),
        ]);
        break;
      case 'done':
        body = _done(p);
        break;
      case 'error':
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Not online yet', style: Brand.serif(size: 24, color: p.text)),
          const SizedBox(height: 8),
          Text(_error, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
          const SizedBox(height: 16),
          _primary(p, 'Try again', () => _go(_host)),
          TextButton(onPressed: () => setState(() => _step = 'choose'), child: Text('Choose another way', style: TextStyle(color: p.muted))),
        ]);
        break;
      default:
        body = (_host.isNotEmpty && !_changing) ? _update(p) : _choose(p);
    }
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 24),
      child: SubSize(
        duration: SubMotion.base,
        alignment: AlignmentDirectional.topStart,
        child: body,
      ),
    );
  }

  Widget _primary(Palette p, String label, VoidCallback onTap) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size.fromHeight(48)),
          onPressed: onTap,
          child: Text(label),
        ),
      );

  // A choice is words on the paper (fix/ui-restyle): no card, border, tag pill or chevron. The tag is a quiet word.
  Widget _option(Palette p, {required String title, required String line, required VoidCallback onTap, String? tag}) => LuxRow(
        title: tr(title),
        sub: tr(line),
        value: tag == null ? null : tr(tag),
        padding: const EdgeInsets.symmetric(vertical: Space.x3),
        onTap: onTap,
      );

  Widget _choose(Palette p) {
    final vercelOn = Sites.vercelConnected(widget.app);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('Put it online', style: Brand.serif(size: 26, color: p.text)),
      const SizedBox(height: 6),
      Text('Pick where your site lives. You can change this later.', style: TextStyle(color: p.muted, fontSize: AppText.meta)),
      const SizedBox(height: 16),
      _option(p,
          title: 'Free SubMac link',
          tag: 'No sign-up',
          line: 'Free link, 7 days.',
          onTap: () => _go(SiteHost.free)),
      _option(p,
          title: 'Your Vercel',
          tag: vercelOn ? 'Connected' : 'Free account',
          line: vercelOn
              ? 'Stays online for good, in your own Vercel account. Add your own domain there any time.'
              : 'Stays online for good, in your own account. You sign in once, SubMac does the rest.',
          onTap: () => _go(SiteHost.vercel)),
    ]);
  }

  Widget _update(Palette p) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(s.isExpired ? 'Publish again' : 'Update your site', style: Brand.serif(size: 26, color: p.text)),
        const SizedBox(height: 6),
        Text(
            s.isExpired
                ? 'Your free link ended. Publishing again gives it 7 more days.'
                : 'Your latest changes go to the same address: ${s.url.replaceFirst('https://', '')}',
            style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
        const SizedBox(height: 16),
        _primary(p, s.isExpired ? 'Publish again' : 'Update on ${s.host == SiteHost.vercel ? 'Vercel' : 'the free link'}', () => _go(s.host)),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: TextButton(onPressed: () => setState(() => _changing = true), child: Text('Put it somewhere else', style: TextStyle(color: p.muted))),
        ),
      ]);

  Widget _done(Palette p) {
    final url = s.url;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        DoneTick(size: 22, color: p.text),
        const SizedBox(width: 10),
        Expanded(child: Text('Your site is online', style: Brand.serif(size: 26, color: p.text))),
      ]),
      const SizedBox(height: 10),
      SelectableText(url, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(
          _host == SiteHost.free
              ? 'Free for 7 days. Want it for good, or on your own domain? Publish it to your Vercel any time.'
              : 'It stays online in your Vercel account. Add your own domain in Vercel under Domains.',
          style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
      const SizedBox(height: 16),
      _primary(p, 'Open', () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
            },
            child: const Text('Copy link'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: OutlinedButton(onPressed: () => SharePlus.instance.share(ShareParams(text: url)), child: const Text('Share'))),
      ]),
      const SizedBox(height: 4),
      SizedBox(
        width: double.infinity,
        child: TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Done'), style: TextStyle(color: p.muted))),
      ),
    ]);
  }
}

/// Every site SubMac built on this phone, with where it lives and what is left on free links.
class SitesScreen extends StatefulWidget {
  final bool embedded;
  const SitesScreen({super.key, this.embedded = false});

  @override
  State<SitesScreen> createState() => _SitesScreenState();
}

class _SitesScreenState extends State<SitesScreen> {
  @override
  void initState() {
    super.initState();
    Sites.I.refresh();
  }

  Future<void> _menu(Site s) async {
    final app = context.read<AppState>();
    final pick = await showLuxChoices<String>(context, choices: [
      const LuxChoice('preview', 'Preview'),
      if (s.isLive) const LuxChoice('open', 'Open the live site'),
      if (s.isLive) const LuxChoice('share', 'Share the link'),
      LuxChoice('publish', s.isLive ? 'Update' : 'Publish'),
      if (s.projectId == null) const LuxChoice('project', 'Make it a project'),
      if (s.host == SiteHost.free && s.isLive) const LuxChoice('down', 'Take the free link down', destructive: true),
      const LuxChoice('forget', 'Remove from this list'),
    ]);
    if (!mounted || pick == null) return;
    switch (pick) {
      case 'preview':
        await Navigator.push(context, MaterialPageRoute(builder: (_) => SitePreviewScreen(path: s.entryPath)));
        break;
      case 'open':
        await launchUrl(Uri.parse(s.url), mode: LaunchMode.externalApplication);
        break;
      case 'share':
        await SharePlus.instance.share(ShareParams(text: s.url));
        break;
      case 'publish':
        await showPublishSheet(context, s.entryPath);
        break;
      case 'project':
        final proj = await Sites.I.makeProject(s, chatId: app.currentId);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${proj.name}" is now a project.')));
        break;
      case 'down':
        try {
          await Sites.I.removeFreeLink(s);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The free link is offline now.')));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
        break;
      case 'forget':
        if (s.host == SiteHost.free && s.isLive) {
          try {
            await Sites.I.removeFreeLink(s);
          } catch (_) {}
        }
        await Sites.I.forget(s);
        break;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return maybeScaffold(
      embedded: widget.embedded,
      appBar: AppBar(title: const Text('Your sites')),
      body: AnimatedBuilder(
        animation: Sites.I,
        builder: (context, _) {
          final list = Sites.I.list;
          if (list.isEmpty) {
            return const EmptyHint(text: 'Sites SubMac builds for you show here, ready to publish.');
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: Space.x1),
            itemBuilder: (_, i) {
              final s = list[i];
              return LuxRow(
                title: s.title,
                sub: s.url.isEmpty ? s.statusLine : '${s.statusLine}\n${s.url.replaceFirst('https://', '')}',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SitePreviewScreen(path: s.entryPath))),
                onLongPress: () => _menu(s),
                trailing: IconButton(tooltip: 'More', icon: SubIcon('more', size: IconSize.xl, color: p.muted), onPressed: () => _menu(s)),
              );
            },
          );
        },
      ),
    );
  }
}
