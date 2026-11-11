import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../app_state.dart';
import '../../services/digital_human/registry.dart';
import '../../services/digital_human/person.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import '../../widgets/motion.dart';
import 'bot_feed_card.dart';

/// The Digital Humans feed — your living colleagues at a glance.
///
/// WhatsApp-style list but elevated: each card shows an animated presence ring,
/// last message preview, and a live "thinking" indicator when the person is
/// actively doing something. Pull to refresh triggers all people to check in.
///
/// This is the front door to the Digital Human feature. When production-ready,
/// a payment wall gates access here.
class BotsFeedScreen extends StatefulWidget {
  const BotsFeedScreen({super.key});

  @override
  State<BotsFeedScreen> createState() => BotsFeedScreenState();
}

class BotsFeedScreenState extends State<BotsFeedScreen> {
  final _listKey = GlobalKey<ListViewState>();
  Timer? _refreshTimer;
  static const _refreshInterval = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    _startRefreshTimer();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      // Trigger a background awareness tick on all active persons
      for (final p in DigitalHumanRegistry.I.all) {
        if (p.isActive) p.awareness.observe();
      }
    });
  }

  Future<void> _pullToRefresh() async {
    for (final p in DigitalHumanRegistry.I.all) {
      await p.awareness.observe();
    }
    if (mounted) setState(() {});
  }

  void _openChat(DigitalPerson person) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BotChatScreen(person: person),
      ),
    );
  }

  void _showProfile(DigitalPerson person) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BotProfileSheet(person: person),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final people = DigitalHumanRegistry.I.all;

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(p, people),
            const Divider(height: 1, thickness: 0.5, color: Colors.transparent),
            // Feed list
            Expanded(
              child: RefreshIndicator(
                onRefresh: _pullToRefresh,
                child: ListView.separated(
                  key: _listKey,
                  padding: const EdgeInsets.symmetric(vertical: Space.x2),
                  separatorBuilder: (_, __) => const SizedBox(height: 1),
                  itemCount: people.isEmpty ? 1 : people.length,
                  itemBuilder: (context, index) {
                    if (people.isEmpty) return _EmptyState();
                    final person = people[index];
                    return BotFeedCard(
                      person: person,
                      lastMessage: _lastPreview(person),
                      lastTime: _formatTime(person.lastSpokeAt),
                      unreadCount: _unreadCount(person),
                      onTap: () => _openChat(person),
                      isPinned: person.role == 'chief',
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _FABButton(persons: people),
    );
  }

  Widget _buildHeader(Palette p, List<DigitalPerson> people) {
    final active = people.where((pe) => pe.isActive).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.x4, Space.x4, Space.x4, Space.x2),
      child: Row(
        children: [
          Text(
            'Digital Humans',
            style: Brand.display(size: 28, color: p.text),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x1),
            decoration: BoxDecoration(
              color: p.bubble,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active > 0 ? PresenceStateColors.online : p.muted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Space.x1),
                Text(
                  '$active awake',
                  style: AppText.metaStyle.copyWith(color: p.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _lastPreview(DigitalPerson person) {
    if (person.memory.episodeCount == 0) return 'Say hello';
    final recent = person.memory.recentEpisodes(1);
    if (recent.isEmpty) return 'Still learning about you...';
    final content = recent[0]['content'] as String? ?? '';
    return content.length > 60 ? '${content.substring(0, 60)}...' : content;
  }

  int _unreadCount(DigitalPerson person) => person.awareness.insightCount;

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _FABButton extends StatelessWidget {
  const _FABButton({required this.persons});
  final List<DigitalPerson> persons;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FloatingActionButton.extended(
      onPressed: () => _showNewBotSheet(context),
      backgroundColor: p.text,
      foregroundColor: p.bg,
      icon: const Icon(Icons.person_add_rounded),
      label: const Text('New person'),
    );
  }

  void _showNewBotSheet(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => const _NewBotSheet(),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: p.bubble,
              ),
              child: Icon(Icons.psychology_rounded, size: 40, color: p.muted),
            ),
            const SizedBox(height: Space.x4),
            Text(
              'No digital humans yet',
              style: Brand.display(size: 22, color: p.text),
            ),
            const SizedBox(height: Space.x2),
            InkText(
              'Your first digital person will live here — alive, aware, and ready to help.\nTap + to create one.',
              style: AppText.leadStyle.copyWith(color: p.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.x4),
            ElevatedButton(
              onPressed: () {},
              style: ElevatedButton.styleFrom(
                backgroundColor: p.text,
                foregroundColor: p.bg,
                padding: const EdgeInsets.symmetric(horizontal: Space.x6, vertical: Space.x3),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.field)),
              ),
              child: const Text('Create your first person'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewBotSheet extends StatefulWidget {
  const _NewBotSheet();

  @override
  State<_NewBotSheet> createState() => _NewBotSheetState();
}

class _NewBotSheetState extends State<_NewBotSheet> {
  final _nameCtrl = TextEditingController();
  final _roleCtrl = TextEditingController();
  String _selectedRole = 'researcher';

  static const _roles = [
    {'id': 'researcher', 'label': 'Researcher', 'desc': 'Curious, explores topics'},
    {'id': 'analyst', 'label': 'Analyst', 'desc': 'Data-focused, finds patterns'},
    {'id': 'creator', 'label': 'Creator', 'desc': 'Writes, designs, makes things'},
    {'id': 'helper', 'label': 'Helper', 'desc': 'Proactive, anticipates needs'},
    {'id': 'chief', 'label': 'Chief', 'desc': 'Leads teams, coordinates'},
  ];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _roleCtrl.dispose();
    super.dispose();
  }

  void _create() {
    if (_nameCtrl.text.trim().isEmpty) return;
    final reg = DigitalHumanRegistry.I;
    final id = 'dh_${DateTime.now().millisecondsSinceEpoch}';
    final person = DigitalPerson(
      id: id,
      name: _nameCtrl.text.trim(),
      role: _selectedRole,
      personaDescription: _roleCtrl.text.trim(),
    );
    reg.register(person);
    Navigator.pop(context); // close sheet
    Navigator.pop(context); // close sheet
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.sheet,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(Space.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: Space.x4),
              decoration: BoxDecoration(
                color: p.border,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
            ),
            const SizedBox(height: Space.x4),
            Text('New Digital Human', style: Brand.display(size: 24, color: p.text)),
            const SizedBox(height: Space.x2),
            InkText('Give them a name, pick their role, and they come alive.', style: AppText.metaStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x4),
            // Name field
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Name (e.g., Nova)',
                filled: true,
                fillColor: p.bubble,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.field), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x3),
              ),
              style: AppText.bodyStyle.copyWith(color: p.text),
            ),
            const SizedBox(height: Space.x3),
            // Role selector
            Text('Role', style: AppText.sectionStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x2),
            ..._roles.map((r) => _RoleTile(
                  id: r['id']!,
                  label: r['label']!,
                  desc: r['desc']!,
                  selected: _selectedRole == r['id'],
                  onTap: () => setState(() => _selectedRole = r['id']),
                )),
            const SizedBox(height: Space.x4),
            // Optional persona
            TextField(
              controller: _roleCtrl,
              decoration: InputDecoration(
                hintText: 'Additional traits (optional)',
                filled: true,
                fillColor: p.bubble,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.field), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x3),
              ),
              maxLines: 2,
              style: AppText.bodyStyle.copyWith(color: p.text),
            ),
            const SizedBox(height: Space.x4),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _create,
                style: ElevatedButton.styleFrom(
                  backgroundColor: p.text,
                  foregroundColor: p.bg,
                  padding: const EdgeInsets.symmetric(vertical: Space.x3),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.field)),
                ),
                child: const Text('Create Person'),
              ),
            ),
            const SizedBox(height: Space.x2),
          ],
        ),
      ),
    );
  }
}

class _RoleTile extends StatelessWidget {
  const _RoleTile({required this.id, required this.label, required this.desc, required this.selected, required this.onTap});
  final String id;
  final String label;
  final String desc;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x2),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? p.text : p.border, width: selected ? 2 : 1),
                color: selected ? p.text.withValues(alpha: 0.1) : Colors.transparent,
              ),
              child: selected ? Icon(Icons.check_rounded, size: 14, color: p.text) : null,
            ),
            const SizedBox(width: Space.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w600, color: p.text)),
                  Text(desc, style: AppText.metaStyle.copyWith(color: p.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
