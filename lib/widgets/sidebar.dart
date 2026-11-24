import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/today_screen.dart';
import '../app_state.dart';
import '../models.dart';
import '../screens/connectors_screen.dart';
import '../screens/files_screen.dart';
import '../screens/projects_screen.dart';
import '../screens/settings_screen.dart';
import '../services/chat_search.dart';
import '../services/projects.dart';
import 'motion.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import 'logo.dart';
import 'sub_icon.dart';
import 'bot_list.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../services/cases.dart';
import '../services/inbox.dart';
import '../screens/inbox_screen.dart';
import '../screens/caseboard_screen.dart';
import 'chat/entrance.dart';
import '../services/reply_text.dart' show cleanGlyphs;

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  String _query = '';
  // CB-32: chats whose saved words match the query (id -> the matching line). Filled after a short pause in typing.
  Map<String, String> _bodyHits = const {};
  Timer? _searchTimer;
  int _searchGen = 0;

  void _onQuery(String v) {
    setState(() => _query = v);
    _searchTimer?.cancel();
    final gen = ++_searchGen;
    if (v.trim().length < ChatSearch.minChars) {
      if (_bodyHits.isNotEmpty) setState(() => _bodyHits = const {});
      return;
    }
    _searchTimer = Timer(ChatSearch.debounce, () async {
      if (!mounted) return;
      final state = context.read<AppState>();
      final store = state.repo.store;
      final botChats = state.botConvIds;
      final ids = (state.conversations.where((c) => !c.archived && !c.packedAway && !botChats.contains(c.id) && !state.caseConvIds.contains(c.id)).toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
          .map((c) => c.id);
      final hits = await ChatSearch(store.rowsForSearch).search(ids, v);
      if (!mounted || gen != _searchGen) return;
      setState(() => _bodyHits = hits);
    });
  }
  // Search only takes focus when tapped: opening the menu never brings up the keyboard.
  final FocusNode _searchFocus = FocusNode(canRequestFocus: false);

  void _onProjects() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    Projects.I.addListener(_onProjects);
  }

  @override
  void dispose() {
    Projects.I.removeListener(_onProjects);
    _searchFocus.dispose();
    _searchTimer?.cancel();
    super.dispose();
  }

  Map<String, List<Conversation>> _group(List<Conversation> list) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final groups = <String, List<Conversation>>{};
    void add(String k, Conversation c) => (groups[k] ??= []).add(c);
    for (final c in list.where((c) => c.pinned)) {
      add('Pinned', c);
    }
    for (final c in list.where((c) => !c.pinned)) {
      final d = DateTime(c.updatedAt.year, c.updatedAt.month, c.updatedAt.day);
      final diff = today.difference(d).inDays;
      if (diff <= 0) {
        add('Today', c);
      } else if (diff == 1) {
        add('Yesterday', c);
      } else if (diff <= 7) {
        add('Previous 7 days', c);
      } else if (diff <= 30) {
        add('Previous 30 days', c);
      } else {
        add('Older', c);
      }
    }
    return groups;
  }

  /// The menu rebuilds only when something it lists changes, never on every chat update: a reply streaming in used
  /// to rebuild the whole drawer many times a second, which made opening and closing it stutter.
  static int _listKey(AppState s) => Object.hashAll([
        s.currentId,
        s.loadingConversations,
        s.currentProject?.id,
        s.repo.email,
        s.botConvIds.length,
        s.caseConvIds.length,
        Cases.I.list.length,
        for (final c in s.conversations) Object.hash(c.id, c.title, c.pinned, c.archived, c.packedAway, c.updatedAt),
      ]);

  @override
  Widget build(BuildContext context) {
    context.select<AppState, int>(_listKey);
    final state = context.read<AppState>();
    final p = Palette.of(context);
    final q = _query.toLowerCase();
    final inProject = Projects.I.chatProject;
    // Chats inside a project live in that project; search still finds them.
    // Each bot's chat lives under Bots, not in the chat list.
    final botChats = state.botConvIds;
    final caseChats = state.caseConvIds;
    final visible = state.conversations
        .where((c) => !c.archived && !botChats.contains(c.id) && !caseChats.contains(c.id) && (q.isEmpty ? !inProject.containsKey(c.id) : c.title.toLowerCase().contains(q) || _bodyHits.containsKey(c.id)))
        .toList();
    final groups = _group(visible);
    final email = state.repo.email ?? '';
    return Drawer(
      width: MediaQuery.of(context).size.width * 0.84,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          // Telesia motion: the menu's rows rise and settle in turn as it opens.
          children: revealRows([
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 4),
              child: TextField(
                key: const ValueKey('menu-search'),
                focusNode: _searchFocus,
                onTap: () {
                  _searchFocus.canRequestFocus = true;
                  _searchFocus.requestFocus();
                },
                onTapOutside: (_) {
                  // Back to "only on a tap", so nothing hands the keyboard back to search later.
                  _searchFocus.unfocus();
                  _searchFocus.canRequestFocus = false;
                },
                onChanged: _onQuery,
                decoration: InputDecoration(hintText: tr('Search'), isDense: true),
              ),
            ),
            const SizedBox(height: 6),
            _NavTile(
              title: 'New chat',
              onTap: () {
                state.newChat();
                Navigator.pop(context);
              },
            ),
            // Today shows once there is a bot or a routine (PLAN.md 3.3).
            if (TodayScreen.hasFeed)
              _NavTile(
                title: 'Today',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const TodayScreen()));
                },
              ),
            _NavTile(
              title: 'Investigation',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const CaseboardScreen()));
              },
            ),
            _NavTile(
              title: 'Apps',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectorsScreen()));
              },
            ),
            _NavTile(
              title: 'Files',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const FilesScreen()));
              },
            ),
            // The inbox while something is unread (it used to sit in the top bar). No app name in the menu.
            ValueListenableBuilder<int>(
              valueListenable: Inbox.I.unread,
              builder: (context, n, _) => n <= 0
                  ? const SizedBox.shrink()
                  : _NavTile(
                      title: 'Inbox',
                      count: n,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const InboxScreen()));
                      },
                    ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: state.loadingConversations && state.conversations.isEmpty
                  ? const Center(child: RedDot(size: 18, animate: true))
                  : RefreshIndicator(
                      onRefresh: state.refreshConversations,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        children: [
                          // Grok-style: Chief, Bots and Teams as quiet, foldable sections. Search finds them too.
                          AnimatedBuilder(
                            animation: Listenable.merge([Bots.I, Offices.I]),
                            builder: (context, _) => DrawerBots(
                              query: q,
                              selectedConv: state.currentId,
                              onOpen: () => Navigator.pop(context),
                            ),
                          ),
                          AnimatedBuilder(
                            animation: Cases.I,
                            builder: (context, _) => q.isNotEmpty || Cases.I.list.isEmpty
                                ? const SizedBox.shrink()
                                : DrawerSection(
                                    id: 'drawer-cases',
                                    title: 'Cases',
                                    count: Cases.I.openCount,
                                    children: [
                                      for (final c in Cases.I.list.take(8)) _CaseTile(item: c, selected: state.currentId == c.convId),
                                    ],
                                  ),
                          ),
                          if (q.isEmpty) ...[
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(12, 16, 4, 2),
                              child: Row(children: [
                                Text(tr('Projects'), style: AppText.sectionStyle.copyWith(color: p.faint)),
                                const Spacer(),
                                TextButton(
                                  style: TextButton.styleFrom(minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: 8)),
                                  onPressed: () async {
                                    final pr = await createProjectFlow(context);
                                    if (pr != null && context.mounted) {
                                      Navigator.pop(context);
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectScreen(projectId: pr.id)));
                                    }
                                  },
                                  child: Text(tr('New'), style: AppText.metaStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                                ),
                              ]),
                            ),
                            for (final (i, pr) in Projects.I.list.indexed)
                              FadeSlideIn(
                                key: ValueKey('pj${pr.id}'),
                                delay: SubMotion.staggerFor(i) ~/ 2,
                                child: _ProjectTile(project: pr, selected: state.currentProject?.id == pr.id),
                              ),
                            if (Projects.I.list.isEmpty)
                              Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 4),
                                child: Text(tr('Keep chats, files and instructions together.'),
                                    style: AppText.metaStyle.copyWith(color: p.muted)),
                              ),
                          ],
                          for (final entry in groups.entries) ...[
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(12, 16, 12, 6),
                              child: Text(tr(entry.key), style: AppText.sectionStyle.copyWith(color: p.faint)),
                            ),
                            for (final c in entry.value)
                              _ChatTile(
                                conversation: c,
                                // The matching line shows under the title when only the words matched.
                                match: q.isEmpty || c.title.toLowerCase().contains(q) ? null : _bodyHits[c.id],
                              ),
                          ],
                          if (visible.isEmpty && !(q.isNotEmpty && DrawerBots.anyHit(q)))
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(tr(q.isEmpty ? 'No chats yet' : 'No results'),
                                  textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
                            ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: Space.x2),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 6),
              child: InkWell(
                borderRadius: Radii.fieldAll,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: p.text,
                      child: Text(email.isEmpty ? '?' : email[0].toUpperCase(),
                          style: Brand.display(size: 18, color: p.bg, height: 1.0)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(email,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppText.bodyStyle.copyWith(color: p.text)),
                    ),
                    Text(tr('Settings'), style: AppText.metaStyle.copyWith(color: p.muted)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Project project;
  final bool selected;
  const _ProjectTile({required this.project, required this.selected});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = Projects.I.chatsIn(project.id).length;
    return Material(
      color: selected ? p.bubble : Colors.transparent,
      borderRadius: Radii.fieldAll,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: () {
          Navigator.pop(context);
          Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectScreen(projectId: project.id)));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            SubIcon('folder', size: 18, color: p.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text))),
            if (n > 0) Text('$n', style: AppText.microStyle.copyWith(color: p.muted)),
          ]),
        ),
      ),
    );
  }
}

class _CaseTile extends StatelessWidget {
  final Case item;
  final bool selected;
  const _CaseTile({required this.item, required this.selected});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    return Material(
      color: selected ? p.bubble : Colors.transparent,
      borderRadius: Radii.fieldAll,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: () {
          state.openCase(item.id);
          Navigator.pop(context);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text)),
            const SizedBox(height: 2),
            Text('${item.numberLabel} · ${item.statusWord}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.captionStyle.copyWith(color: p.muted)),
          ]),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  final int count;
  const _NavTile({required this.title, required this.onTap, this.count = 0});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: () {
          onTap();
        },
        child: Container(
          height: 44,
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(child: Text(tr(title), style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500))),
            if (count > 0) Text(count > 9 ? '9+' : '$count', style: AppText.captionStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final Conversation conversation;
  final String? match;
  const _ChatTile({required this.conversation, this.match});

  @override
  Widget build(BuildContext context) {
    final selected = context.select<AppState, bool>((s) => s.currentId == conversation.id);
    final state = context.read<AppState>();
    final p = Palette.of(context);
    return Material(
      color: selected ? p.bubble : Colors.transparent,
      borderRadius: Radii.fieldAll,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: () {
          state.openConversation(conversation.id);
          Navigator.pop(context);
        },
        onLongPress: () => showChatActions(context, conversation),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: conversation.packedAway
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(cleanGlyphs(conversation.title),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text)),
                          const SizedBox(height: 2),
                          Text('Backed up. Tap to open', style: AppText.captionStyle.copyWith(color: p.muted)),
                        ],
                      )
                    : match != null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(cleanGlyphs(conversation.title),
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text)),
                              const SizedBox(height: 2),
                              Text(match!,
                                  key: ValueKey('menu-search-hit-${conversation.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.captionStyle.copyWith(color: p.muted)),
                            ],
                          )
                        : Text(cleanGlyphs(conversation.title),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showChatActions(BuildContext context, Conversation c) async {
  final state = context.read<AppState>();
  // The keyboard stays away: closing the sheet must not hand focus back to the message box.
  FocusManager.instance.primaryFocus?.unfocus();
  await showModalBottomSheet<void>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
            child: Text(cleanGlyphs(c.title), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppText.leadStyle.copyWith(fontWeight: FontWeight.w600)),
          ),
          ListTile(
            title: Text(tr('Rename')),
            onTap: () async {
              Navigator.pop(ctx);
              final ctrl = TextEditingController(text: c.title);
              if (!context.mounted) return;
              final name = await showDialog<String>(
                context: context,
                builder: (d) => AlertDialog(
                  title: Text(tr('Rename chat')),
                  content: TextField(controller: ctrl, autofocus: true),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancel'))),
                    TextButton(onPressed: () => Navigator.pop(d, ctrl.text), child: Text(tr('Save'))),
                  ],
                ),
              );
              // Disposed after the dialog's closing animation, which still reads it.
              Future.delayed(const Duration(seconds: 1), ctrl.dispose);
              if (name != null && name.trim().isNotEmpty) await state.renameConversation(c.id, name.trim());
            },
          ),
          ListTile(
            title: Text(Projects.I.forChat(c.id) == null ? 'Add to project' : 'Move to another project'),
            onTap: () async {
              Navigator.pop(ctx);
              await _pickProject(context, c.id);
            },
          ),
          ListTile(
            title: Text(c.pinned ? 'Unpin' : 'Pin'),
            onTap: () {
              Navigator.pop(ctx);
              state.togglePin(c.id);
            },
          ),
          ListTile(
            title: Text(c.archived ? 'Unarchive' : 'Archive'),
            onTap: () {
              Navigator.pop(ctx);
              state.setArchived(c.id, !c.archived);
            },
          ),
          ListTile(
            title: Text(tr('Delete'), style: TextStyle(color: Palette.of(context).accent)),
            onTap: () async {
              Navigator.pop(ctx);
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: Text(tr('Delete chat?')),
                  content: Text('This will delete "${c.title}".'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
                    TextButton(
                      onPressed: () => Navigator.pop(d, true),
                      child: Text(tr('Delete'), style: TextStyle(color: Palette.of(context).accent)),
                    ),
                  ],
                ),
              );
              if (ok == true) await state.deleteConversation(c.id);
            },
          ),
        ],
      ),
    ),
  );
}


Future<void> _pickProject(BuildContext context, String chatId) async {
  final current = Projects.I.forChat(chatId);
  final choice = await showModalBottomSheet<String>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    builder: (c) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final pr in Projects.I.list)
            ListTile(
              title: Text(pr.name),
              trailing: current?.id == pr.id ? Text(tr('Here')) : null,
              onTap: () => Navigator.pop(c, pr.id),
            ),
          ListTile(title: Text(tr('New project')), onTap: () => Navigator.pop(c, '_new')),
          if (current != null) ListTile(title: Text(tr('Remove from project')), onTap: () => Navigator.pop(c, '_none')),
        ],
      ),
    ),
  );
  if (choice == null) return;
  if (choice == '_none') {
    await Projects.I.assign(chatId, null);
  } else if (choice == '_new') {
    if (!context.mounted) return;
    final pr = await createProjectFlow(context);
    if (pr != null) await Projects.I.assign(chatId, pr.id);
  } else {
    await Projects.I.assign(chatId, choice);
  }
}
