import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'local_store.dart';

class MemoryFact {
  final String id;
  String fact;
  final DateTime createdAt;
  MemoryFact({required this.id, required this.fact, required this.createdAt});

  Map<String, dynamic> toJson() => {'id': id, 'fact': fact, 'created_at': createdAt.toUtc().toIso8601String()};

  factory MemoryFact.fromJson(Map<String, dynamic> j) => MemoryFact(
        id: (j['id'] ?? const Uuid().v4()).toString(),
        fact: (j['fact'] ?? '').toString(),
        createdAt: DateTime.tryParse((j['created_at'] ?? '').toString())?.toLocal() ?? DateTime.now(),
      );
}

/// Facts the user asked SubMac to remember. Kept on the device and synced to
/// the account (table public.memories, protected by Row Level Security).
class MemoryStore {
  MemoryStore(this.local);
  final LocalStore local;
  List<MemoryFact> facts = [];

  SupabaseClient get _c => Supabase.instance.client;

  static const List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'remember',
        'description': 'Save a lasting fact about the user so you remember it in future chats '
            '(name, family, preferences, goals, important dates). Only save what the user would want kept. '
            'Write it as one short sentence in the third person, e.g. "Prefers short answers in Somali."',
        'parameters': {
          'type': 'object',
          'properties': {
            'fact': {'type': 'string'},
          },
          'required': ['fact'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'forget',
        'description': 'Remove saved memories that match some words, when the user asks you to forget something '
            'or a fact is no longer true.',
        'parameters': {
          'type': 'object',
          'properties': {
            'match': {'type': 'string', 'description': 'Words that appear in the memory to remove.'},
          },
          'required': ['match'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_memories',
        'description': 'List everything you currently remember about the user.',
        'parameters': {'type': 'object', 'properties': {}, 'required': []},
      },
    },
  ];

  static const names = {'remember', 'forget', 'list_memories'};

  void loadLocal() {
    facts = [for (final j in local.memories) MemoryFact.fromJson(j)];
  }

  void _saveLocal() => local.memories = [for (final f in facts) f.toJson()];

  /// The account the facts on this phone belong to ('' = from before this was kept: the signed-in account).
  static const ownerKey = 'memories_owner';
  String get _owner => local.prefs.getString(ownerKey) ?? '';
  void _own(String uid) {
    if (uid.isNotEmpty && _owner != uid) local.prefs.setString(ownerKey, uid);
  }

  String get _uid {
    try {
      return _c.auth.currentUser?.id ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Sign-out: the facts leave this phone (they stay in the account). The next account starts empty.
  void forgetDevice() {
    facts = [];
    _saveLocal();
    local.prefs.remove(ownerKey);
  }

  /// The facts on this phone that are still to be saved in the signed-in account [uid]: those its copy lacks, and
  /// only when they were written for this same account. Another account's facts are never uploaded (before, a
  /// sign-out kept them on the phone and the next account's first sync saved them into the new account).
  static List<MemoryFact> pendingUploads(List<MemoryFact> here, Set<String> remoteIds, {required String owner, required String uid}) {
    if (uid.isEmpty || (owner.isNotEmpty && owner != uid)) return const [];
    return [for (final f in here) if (!remoteIds.contains(f.id)) f];
  }

  /// Pull from the account and merge with anything saved offline.
  Future<void> sync() async {
    final uid = _uid;
    if (uid.isEmpty) return;
    try {
      final rows = await _c.from('memories').select().order('created_at', ascending: true);
      final remote = [for (final r in rows) MemoryFact.fromJson(r)];
      final remoteIds = remote.map((e) => e.id).toSet();
      final pending = pendingUploads(facts, remoteIds, owner: _owner, uid: uid);
      for (final f in pending) {
        try {
          await _c.from('memories').insert({'id': f.id, 'fact': f.fact});
        } catch (_) {}
      }
      facts = [...remote, ...pending];
      _saveLocal();
      _own(uid);
    } catch (_) {
      // Offline or table missing: keep the device copy.
    }
  }

  Future<MemoryFact> add(String fact) async {
    final f = MemoryFact(id: const Uuid().v4(), fact: fact.trim(), createdAt: DateTime.now());
    facts.add(f);
    _saveLocal();
    _own(_uid);
    try {
      await _c.from('memories').insert({'id': f.id, 'fact': f.fact});
    } catch (_) {}
    return f;
  }

  Future<void> update(MemoryFact f, String text) async {
    f.fact = text.trim();
    _saveLocal();
    try {
      await _c.from('memories').update({'fact': f.fact, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', f.id);
    } catch (_) {}
  }

  Future<void> remove(MemoryFact f) async {
    facts.removeWhere((e) => e.id == f.id);
    _saveLocal();
    try {
      await _c.from('memories').delete().eq('id', f.id);
    } catch (_) {}
  }

  Future<void> clear() async {
    final all = List.of(facts);
    facts.clear();
    _saveLocal();
    for (final f in all) {
      try {
        await _c.from('memories').delete().eq('id', f.id);
      } catch (_) {}
    }
  }

  Future<String> execute(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'remember':
        final fact = (args['fact'] ?? '').toString().trim();
        if (fact.isEmpty) return 'Error: nothing to remember.';
        if (facts.any((f) => f.fact.toLowerCase() == fact.toLowerCase())) return 'Already remembered: $fact';
        await add(fact);
        return 'Remembered: $fact';
      case 'forget':
        final m = (args['match'] ?? '').toString().toLowerCase().trim();
        if (m.isEmpty) return 'Error: say what to forget.';
        final hits = facts.where((f) => f.fact.toLowerCase().contains(m)).toList();
        if (hits.isEmpty) return 'Nothing saved matches "$m".';
        for (final f in hits) {
          await remove(f);
        }
        return 'Forgot ${hits.length}: ${hits.map((e) => e.fact).join(' | ')}';
      case 'list_memories':
        if (facts.isEmpty) return 'No memories saved yet.';
        return facts.map((e) => '- ${e.fact}').join('\n');
    }
    return 'Error: unknown memory tool';
  }

  String promptSection() {
    final sb = StringBuffer()
      ..writeln('# Memory')
      ..writeln('You can remember lasting facts with the remember tool and remove them with forget. '
          'Save a fact when the user shares something about themselves that will help later, or asks you to remember. '
          'Do not save passwords, card numbers or one-off details. Tell the user briefly when you save or forget something.');
    if (facts.isNotEmpty) {
      sb.writeln('What you remember about the user:');
      // At most 40 lines every step (the first 10 saved, usually who they are, and the newest 30); list_memories finds the rest.
      final shown = facts.length <= 40 ? facts : [...facts.take(10), ...facts.skip(facts.length - 30)];
      for (final f in shown) {
        sb.writeln('- ${f.fact}');
      }
      if (facts.length > 40) sb.writeln('(${facts.length - 40} older facts not shown: list_memories finds them.)');
    }
    return sb.toString();
  }
}
