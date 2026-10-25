import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/browser_agent.dart';
import '../services/browser_jobs.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import 'sub_icon.dart';

/// Hosts the agent's browser (browser-use v2).
///
/// Layering, bottom to top:
///   1. the web pages, laid out at full size so screenshots and real touches work, when nobody is watching;
///   2. an opaque floor with the whole app on it (the sky is part of the app);
///   3. the full-screen live view, when the user opens it from the chat card.
///
/// The bug this replaces: the hidden page sat between the sky and the app. The app's pages are see-through (they show
/// the sky), so the web page bled into the sky behind every screen. Now the app, sky included, stands on an opaque floor
/// above the hidden page, and the live view is an opaque card above everything, clipped to its rounded corners.
class BrowserLayer extends StatefulWidget {
  const BrowserLayer({super.key, required this.child});
  final Widget child;

  /// Builds one tab's web view. Tests replace it (there is no platform web view in a widget test).
  static Widget Function(BrowserTab tab) webViewBuilder = (t) => _AgentWebView(tab: t);

  static const stackKey = ValueKey('browser-layer');
  static const hiddenKey = ValueKey('browser-hidden');
  static const appKey = ValueKey('browser-app');
  static const appPosKey = ValueKey('browser-app-layer');
  static const fullKey = ValueKey('browser-full');
  static const surfaceKey = ValueKey('browser-surface');

  /// Corner radius of the live page in the full view.
  static const double radius = Radii.sheet;

  @override
  State<BrowserLayer> createState() => _BrowserLayerState();
}

class _BrowserLayerState extends State<BrowserLayer> {
  final _webKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BrowserAgent.I,
      builder: (context, _) {
        final b = BrowserAgent.I;
        final p = Palette.of(context);
        // The app always stands on an opaque floor, so nothing under it can ever show through its see-through screens.
        final app = KeyedSubtree(
          key: BrowserLayer.appKey,
          child: ColoredBox(color: p.bg.withAlpha(255), child: widget.child),
        );
        // Always the same stack with keyed layers, so opening or closing the browser never rebuilds the app.
        if (!b.active) return Stack(key: BrowserLayer.stackKey, children: [Positioned.fill(key: BrowserLayer.appPosKey, child: app)]);
        final mq = MediaQuery.of(context);
        final vw = mq.size.width;
        final vh = mq.size.height - mq.padding.top;
        final web = KeyedSubtree(
          key: _webKey,
          child: SizedBox(
            width: vw,
            height: vh,
            // Every tab stays alive; only the current one is shown. Each page is opaque.
            child: ColoredBox(
              color: p.bg.withAlpha(255),
              child: IndexedStack(
                index: b.tabs.isEmpty ? 0 : b.current.clamp(0, b.tabs.length - 1),
                children: [for (final t in b.tabs) KeyedSubtree(key: t.key, child: BrowserLayer.webViewBuilder(t))],
              ),
            ),
          ),
        );
        final show = b.windowOpen && !b.sheetUp;
        return Stack(key: BrowserLayer.stackKey, children: [
          if (!show)
            Positioned(
              key: BrowserLayer.hiddenKey,
              left: 0,
              top: mq.padding.top,
              width: vw,
              height: vh,
              child: IgnorePointer(child: ExcludeSemantics(child: web)),
            ),
          Positioned.fill(key: BrowserLayer.appPosKey, child: app),
          if (show) Positioned.fill(key: BrowserLayer.fullKey, child: BrowserFullView(web: web, pageSize: Size(vw, vh))),
        ]);
      },
    );
  }
}

/// The full-screen live view: domain and status at the top, the live page in an opaque rounded card, Stop and
/// Take over at the bottom.
class BrowserFullView extends StatelessWidget {
  const BrowserFullView({super.key, required this.web, required this.pageSize});
  final Widget web;
  final Size pageSize;

  BrowserJob? _job() {
    final b = BrowserAgent.I;
    final owner = b.tab?.owner;
    for (final j in BrowserJobs.I.jobs.reversed) {
      if (!j.finished && (owner == null || j.id == owner)) return j;
    }
    return null;
  }

  void _stop() {
    final j = _job();
    if (j != null) BrowserJobs.I.stop(j);
    BrowserAgent.I.onStopTask?.call();
    BrowserAgent.I.hideWindow();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = BrowserAgent.I;
    final job = _job();
    final status = b.userControl ? tr('You are in control') : (job?.now ?? '');
    Widget pill(String label, VoidCallback onTap, {bool strong = false, String? icon}) => Material(
          color: strong ? p.text : p.composer,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[SubIcon(icon, size: IconSize.sm, color: strong ? p.bg : p.text), const SizedBox(width: Space.x2)],
                Text(label, style: AppText.metaStyle.copyWith(color: strong ? p.bg : p.text, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        );
    final header = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x2, Space.x2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(b.host.isEmpty ? tr('Browser') : b.host,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
            if (status.isNotEmpty)
              Semantics(
                liveRegion: true,
                child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
              ),
          ]),
        ),
        // No tooltip: this view lives above the app's navigator, where there is no overlay to show one.
        Semantics(
          button: true,
          label: tr('Close'),
          child: IconButton(onPressed: b.hideWindow, icon: SubIcon('close', size: IconSize.lg, color: p.text)),
        ),
      ]),
    );
    final tabsStrip = b.tabs.length < 2
        ? const SizedBox.shrink()
        : SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.x3),
              children: [
                for (var i = 0; i < b.tabs.length; i++)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: Space.x2),
                    child: ChoiceChip(
                      label: Text(b.tabs[i].host.isEmpty ? tr('Browser') : b.tabs[i].host, style: AppText.microStyle),
                      selected: i == b.current,
                      onSelected: (_) => b.showTab(i),
                    ),
                  ),
              ],
            ),
          );
    return Material(
      color: p.bg.withAlpha(255),
      child: SafeArea(
        child: Column(children: [
          header,
          tabsStrip,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.x3),
              // The live page: opaque, clipped to its own rounded corners, above the whole app (sky included).
              child: ClipRRect(
                key: BrowserLayer.surfaceKey,
                borderRadius: const BorderRadius.all(Radius.circular(BrowserLayer.radius)),
                child: ColoredBox(
                  color: p.bg.withAlpha(255),
                  child: FittedBox(fit: BoxFit.contain, alignment: Alignment.topCenter, child: SizedBox.fromSize(size: pageSize, child: web)),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.x4, Space.x3, Space.x4, Space.x3),
            child: Row(children: [
              b.userControl ? pill(tr('Hand back'), b.handBack, strong: true) : pill(tr('Take over'), b.takeOver),
              const Spacer(),
              if (job != null) pill(tr('Stop'), _stop, icon: 'stop'),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _AgentWebView extends StatelessWidget {
  const _AgentWebView({required this.tab});
  final BrowserTab tab;

  @override
  Widget build(BuildContext context) {
    final b = BrowserAgent.I;
    final t = tab;
    return InAppWebView(
      windowId: t.windowId,
      initialUrlRequest: t.windowId != null ? null : URLRequest(url: WebUri(t.openUrl ?? 'about:blank')),
      initialSettings: b.settings,
      initialUserScripts: b.userScripts,
      onWebViewCreated: (c) => b.onCreated(t, c),
      onLoadStart: (c, u) => b.onLoadStart(t, u),
      onLoadStop: (c, u) => b.onLoadStop(t, u),
      onProgressChanged: (c, p) => b.onProgress(t, p),
      onUpdateVisitedHistory: (c, u, _) => b.onUrlChanged(t, u),
      onReceivedError: (c, req, err) => b.onError(t, req, err.description),
      onReceivedHttpError: (c, req, res) {
        if ((res.statusCode ?? 0) >= 500) b.onError(t, req, 'the site answered with error ${res.statusCode}');
      },
      onCreateWindow: (c, a) => b.onCreateWindow(a),
      onCloseWindow: (c) => b.onCloseWindow(t),
      onJsAlert: (c, r) async {
        b.onDialog(t, 'alert', r.message ?? '');
        return JsAlertResponse(handledByClient: true, action: JsAlertResponseAction.CONFIRM);
      },
      onJsConfirm: (c, r) async {
        final ok = await b.onConfirm(t, r.message ?? '');
        return JsConfirmResponse(handledByClient: true, action: ok ? JsConfirmResponseAction.CONFIRM : JsConfirmResponseAction.CANCEL);
      },
      onJsPrompt: (c, r) async {
        b.onDialog(t, 'prompt', r.message ?? '');
        return JsPromptResponse(handledByClient: true, action: JsPromptResponseAction.CONFIRM, value: r.defaultValue ?? '');
      },
      onDownloadStartRequest: (c, r) => b.onDownload(t, r.url.toString(), r.suggestedFilename ?? ''),
    );
  }
}
