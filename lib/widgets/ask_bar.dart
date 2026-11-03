import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/connectors_screen.dart';
import '../services/bots.dart';
import '../services/connector_catalog.dart';
import '../services/mcp_oauth.dart';
import '../theme.dart';
import 'browser_card.dart' show BrowserLiveCardAsks;
import 'app_key_dialog.dart';
import 'brand_logo.dart';
import 'chat_extras.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// A calm card above the composer when a running task needs something from
/// the user (a login, a code, a choice). The task waits; the chat stays free.
class AskBar extends StatefulWidget {
  const AskBar({super.key});

  @override
  State<AskBar> createState() => _AskBarState();

  /// Does [a] show with its answers in the chat [currentId]? Login, code and connect asks are global; a task's
  /// question shows only in the chat it came from.
  static bool showsHere(UserAsk a, String? currentId) {
    if (a.kind == 'login' || a.kind == 'login_confirm' || a.kind == 'connect') return true;
    if (a.convId.isEmpty) return true;
    return a.convId == currentId;
  }

  /// The name the chip uses for another chat ("Chat X"): the bot's name, the chat's title, or "another chat".
  static String chatTitle(AppState state, String convId) {
    final bot = Bots.I.byConv(convId);
    if (bot != null) return bot.name;
    final c = state.conversations.where((c) => c.id == convId).firstOrNull;
    final t = c?.title.trim() ?? '';
    return t.isEmpty ? tr('another chat') : t;
  }
}

/// CB-41: "A task in *Chat X* is waiting for you" — never the answer buttons; a tap opens that chat.
class _ElsewhereChip extends StatelessWidget {
  const _ElsewhereChip({required this.ask, required this.title});
  final UserAsk ask;
  final String title;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // The chat's name sits wherever the language puts it, in italics.
    final parts = tr('A task in {chat} is waiting for you', {'chat': '\u0000'}).split('\u0000');
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x2),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Material(
          key: const ValueKey('ask-elsewhere'),
          color: p.sheet,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.read<AppState>().openConversation(ask.convId),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x4, Space.x2),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: parts.first),
                  TextSpan(text: title, style: const TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w600)),
                  if (parts.length > 1) TextSpan(text: parts.sublist(1).join()),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.captionStyle.copyWith(color: p.muted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AskBarState extends State<AskBar> {
  // Sign-in asks open their sheet by themselves (once), so a task never sits silently at a login page.
  static final Set<UserAsk> _autoOpened = {};

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = Palette.of(context);
    // A browser task's sign-in or code question shows on its chat card when that card is on screen.
    // CB-41: a task's question shows (with its answers) only in its own chat. Sign-in and connect asks, and asks that
    // belong to no chat, stay everywhere. Another chat's question is a quiet chip that opens that chat.
    final all = state.asks.where((a) => !BrowserLiveCardAsks.inline(a)).toList();
    final asks = all.where((a) => AskBar.showsHere(a, state.currentId)).toList();
    if (asks.isEmpty) {
      final other = all.where((a) => !AskBar.showsHere(a, state.currentId)).firstOrNull;
      if (other == null) return const SizedBox.shrink();
      return _ElsewhereChip(ask: other, title: AskBar.chatTitle(state, other.convId));
    }
    final a = asks.first;
    final quick = a.kind == 'text' && !a.secret ? a.options.where((o) => o.trim().isNotEmpty).take(5).toList() : const <String>[];
    if ((a.kind == 'login' || a.kind == 'login_confirm' || a.kind == 'connect') && !_autoOpened.contains(a) && (ModalRoute.of(context)?.isCurrent ?? true)) {
      _autoOpened.add(a);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && state.asks.contains(a)) openAsk(context, a, auto: true);
      });
    }
    final action = a.kind == 'login' || a.kind == 'login_confirm'
        ? 'Sign in'
        : (a.kind == 'connect' ? 'Connect' : 'Answer');
    // A modern ask: a soft surface with the question in clear type, then the answers as airy rows (or one
    // plain action). No border, no dot, no box inside a box.
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x2),
      child: AnimatedSize(
        duration: LuxMotion.base,
        curve: LuxMotion.ease,
        alignment: AlignmentDirectional.bottomCenter,
        child: Material(
          key: const ValueKey('ask-bar'),
          color: p.sheet,
          shape: const RoundedRectangleBorder(borderRadius: Radii.sheetAll),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: quick.isNotEmpty ? null : () => openAsk(context, a),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x4, Space.x4, Space.x3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Text(asks.length > 1 ? '${asks.length} questions need your answer' : 'Needs your answer',
                    style: AppText.captionStyle.copyWith(color: p.muted, fontWeight: FontWeight.w600)),
                const SizedBox(height: Space.x2),
                ConstrainedBox(
                  // On a small phone a long question scrolls instead of pushing the composer off the screen.
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                      Text(a.title, style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w600, height: 1.35)),
                      // A question with set answers: one tap answers it, right here, or "Something else" for your own words.
                      if (quick.isNotEmpty) ...[
                        const SizedBox(height: Space.x3),
                        ChoiceRows(
                          key: ValueKey(a),
                          options: quick,
                          onPick: (o) => state.answerAsk(a, {'answer': o}),
                          onOther: (t) => state.answerAsk(a, {'answer': t}),
                        ),
                      ],
                    ]),
                  ),
                ),
                if (quick.isEmpty)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () => openAsk(context, a),
                      child: Text(action, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                    ),
                  )
                else
                  const SizedBox(height: Space.x1),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the sheet for an ask. [auto] is true when the sheet opened by itself (a sign-in the task waits on):
/// then the keyboard waits for a tap instead of jumping up unasked.
Future<void> openAsk(BuildContext context, UserAsk a, {bool auto = false}) async {
  final state = context.read<AppState>();
  // Closing the sheet must not hand focus back to the message box (the keyboard would spring up).
  FocusManager.instance.primaryFocus?.unfocus();
  final r = await showModalBottomSheet<Map<String, String>?>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isScrollControlled: true,
    builder: (_) => a.kind == 'login'
        ? _LoginSheet(ask: a, autofocus: !auto)
        : a.kind == 'login_confirm'
            ? _ConfirmLoginSheet(ask: a)
            : a.kind == 'connect'
                ? _ConnectAppSheet(ask: a)
                : _AnswerSheet(ask: a),
  );
  if (r == null) return; // dismissed: card stays, task keeps waiting
  state.answerAsk(a, r['skip'] == 'true' ? null : r);
}

class _LoginSheet extends StatefulWidget {
  const _LoginSheet({required this.ask, this.autofocus = true});
  final UserAsk ask;
  final bool autofocus;

  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _show = false;
  bool _save = true;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SingleChildScrollView(
      padding: EdgeInsetsDirectional.fromSTEB(20, 20, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.ask.title, style: Brand.display(size: AppText.title / Brand.displayScale, color: p.text)),
        const SizedBox(height: 6),
        Text(widget.ask.prompt, style: TextStyle(color: p.muted, fontSize: AppText.meta)),
        const SizedBox(height: 16),
        TextField(
          controller: _user,
          autofocus: widget.autofocus,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email, phone or username'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pass,
          obscureText: !_show,
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: 'Password',
            suffix: GestureDetector(
              onTap: () => setState(() => _show = !_show),
              child: Text(_show ? 'Hide' : 'Show', style: TextStyle(color: p.muted, fontSize: AppText.meta)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _save,
          onChanged: (v) => setState(() => _save = v ?? true),
          title: Text('Save on this phone for next time', style: TextStyle(color: p.text, fontSize: AppText.meta)),
        ),
        const SizedBox(height: 4),
        Row(children: [
          TextButton(
            onPressed: () => Navigator.pop(context, {'skip': 'true'}),
            child: Text(tr('Not now'), style: TextStyle(color: p.muted)),
          ),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(
            onPressed: () {
              if (_user.text.trim().isEmpty && _pass.text.isEmpty) return;
              Navigator.pop(context, {
                'username': _user.text.trim(),
                'password': _pass.text,
                'save': _save ? 'true' : 'false',
              });
            },
            child: Text(tr('Continue')),
          )),
        ]),
      ]),
    );
  }
}

class _AnswerSheet extends StatefulWidget {
  const _AnswerSheet({required this.ask});
  final UserAsk ask;

  @override
  State<_AnswerSheet> createState() => _AnswerSheetState();
}

class _AnswerSheetState extends State<_AnswerSheet> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final a = widget.ask;
    final hasOptions = a.options.isNotEmpty;
    // The question in clear type, the answers as airy rows with "Something else" for your own words, and a
    // quiet Skip. Scrolls on a small phone (and above the keyboard) instead of overflowing.
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x6, Space.x5, Space.x4 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(a.title, style: AppText.titleStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
          if (a.prompt.trim().isNotEmpty && a.prompt.trim() != a.title.trim()) ...[
            const SizedBox(height: Space.x2),
            Text(a.prompt, style: AppText.bodyStyle.copyWith(color: p.muted)),
          ],
          const SizedBox(height: Space.x5),
          if (hasOptions && !a.secret)
            ChoiceRows(
              options: a.options,
              onPick: (o) => Navigator.pop(context, {'answer': o}),
              onOther: (t) => Navigator.pop(context, {'answer': t}),
            )
          else ...[
            if (hasOptions) ...[
              ChoiceRows(options: a.options, onPick: (o) => Navigator.pop(context, {'answer': o})),
              const SizedBox(height: Space.x3),
            ],
            TextField(
              controller: _c,
              // Opened by a tap on Answer, so the keyboard is expected.
              autofocus: !hasOptions,
              obscureText: a.secret,
              keyboardType: a.secret ? TextInputType.visiblePassword : TextInputType.text,
              textInputAction: TextInputAction.send,
              decoration: const InputDecoration(hintText: 'Your answer'),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.pop(context, {'answer': v.trim()});
              },
            ),
            const SizedBox(height: Space.x3),
            FilledButton(
              onPressed: () {
                if (_c.text.trim().isEmpty) return;
                Navigator.pop(context, {'answer': _c.text.trim()});
              },
              child: Text(tr('Send')),
            ),
          ],
          const SizedBox(height: Space.x2),
          Center(
            child: TextButton(
              onPressed: () => Navigator.pop(context, {'skip': 'true'}),
              child: Text('Skip', style: AppText.bodyStyle.copyWith(color: p.muted)),
            ),
          ),
        ]),
      ),
    );
  }
}


/// "Sign in to gmail.com as you@gmail.com?" A saved login is used only after the user says so.
class _ConfirmLoginSheet extends StatelessWidget {
  const _ConfirmLoginSheet({required this.ask});
  final UserAsk ask;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(20, 20, 20, 16 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ask.title, style: Brand.display(size: AppText.title / Brand.displayScale, color: p.text)),
        const SizedBox(height: 6),
        Text(ask.prompt, style: TextStyle(color: p.muted, fontSize: AppText.meta)),
        const SizedBox(height: 4),
        Text('Your password goes straight into the page; the AI never sees it.', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, {'choice': 'Continue'}),
            child: Text(tr('Continue')),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          TextButton(
            onPressed: () => Navigator.pop(context, {'skip': 'true'}),
            child: Text(tr('Not now'), style: TextStyle(color: p.muted)),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context, {'choice': 'Use another account'}),
            child: Text('Use another account', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
          ),
        ]),
      ]),
    );
  }
}


/// "Connect Notion": what it is for, then one tap. Sign-in apps open their own sign-in page; key apps open their key sheet.
class _ConnectAppSheet extends StatefulWidget {
  const _ConnectAppSheet({required this.ask});
  final UserAsk ask;

  @override
  State<_ConnectAppSheet> createState() => _ConnectAppSheetState();
}

class _ConnectAppSheetState extends State<_ConnectAppSheet> {
  bool _busy = false;
  String? _error;

  McpPreset? get _preset {
    final s = widget.ask.site;
    if (!s.startsWith('mcp:')) return null;
    final id = s.substring(4);
    return McpOAuth.presets.where((p) => p.id == id).firstOrNull;
  }

  ConnDef? get _def => widget.ask.site.startsWith('app:') ? ConnectorCatalog.byId(widget.ask.site.substring(4)) : null;

  Future<void> _connect() async {
    final state = context.read<AppState>();
    final pr = _preset;
    final d = _def;
    if (pr != null) {
      String? key;
      if (pr.needsKey) {
        key = await askAppKey(context, pr);
        if (key == null || !mounted) return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      final err = await state.connectMcpPreset(pr, key: key);
      if (!mounted) return;
      if (err == null) {
        Navigator.pop(context, {'ok': 'true'});
      } else {
        setState(() {
          _busy = false;
          _error = err;
        });
      }
      return;
    }
    if (d != null) {
      await showModalBottomSheet<void>(sheetAnimationStyle: SubMotion.sheet, context: context, isScrollControlled: true, builder: (_) => ConnectSheet(d));
      if (!mounted) return;
      if (ConnectorCatalog.connected.containsKey(d.id)) Navigator.pop(context, {'ok': 'true'});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final pr = _preset;
    final d = _def;
    final id = pr?.id ?? d?.id ?? '';
    final name = pr?.name ?? d?.name ?? widget.ask.title.replaceFirst('Connect ', '');
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(20, 20, 20, 16 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          BrandLogo(id, name, size: 44),
          const SizedBox(width: 12),
          Expanded(child: Text(widget.ask.title, style: Brand.display(size: AppText.title / Brand.displayScale, color: p.text))),
        ]),
        const SizedBox(height: 10),
        if (widget.ask.prompt.isNotEmpty) Text(widget.ask.prompt, style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.4)),
        const SizedBox(height: 6),
        Text(
            pr != null
                ? (pr.needsKey
                    ? 'You paste your $name key. It stays encrypted on this phone, and you can disconnect any time in Apps.'
                    : pr.signIn
                    ? 'You sign in on $name\'s own page. SubMac never sees your password, and you can disconnect any time in Apps.'
                    : 'Nothing to sign in to. You can turn it off any time in Apps.')
                : 'You paste a key from $name. It stays encrypted on this phone, and you can disconnect any time in Apps.',
            style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.35)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: TextStyle(color: p.accent, fontSize: AppText.meta)),
          ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _connect,
            child: Text(_busy ? 'Waiting for $name…' : (_error != null ? 'Try again' : 'Connect')),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: () {
              if (_busy && pr != null && pr.signIn) context.read<AppState>().cancelMcpSignIn();
              Navigator.pop(context, {'skip': 'true'});
            },
            child: Text(tr('Not now'), style: TextStyle(color: p.muted)),
          ),
        ),
      ]),
    );
  }
}
