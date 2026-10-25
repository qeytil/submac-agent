import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'tools.dart';

/// A project: a name, standing instructions, its own files, and the chats that belong to it.
/// Every chat in a project gets the instructions and knows where the files are.
class Project {
  final String id;
  String name;
  String instructions;
  final DateTime created;
  DateTime updated;

  Project({required this.id, required this.name, this.instructions = '', DateTime? created, DateTime? updated})
      : created = created ?? DateTime.now(),
        updated = updated ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'instructions': instructions,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: (j['name'] ?? 'Project') as String,
        instructions: (j['instructions'] ?? '') as String,
        created: DateTime.tryParse('${j['created']}'),
        updated: DateTime.tryParse('${j['updated']}'),
      );
}

class Projects extends ChangeNotifier {
  Projects._();
  static final I = Projects._();

  final List<Project> list = [];
  /// chat id -> project id
  final Map<String, String> chatProject = {};
  final Map<String, List<String>> _fileCache = {};
  String _ws = '';
  SharedPreferences? _p;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    try {
      final raw = _p!.getString('projects_v1');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        list
          ..clear()
          ..addAll([for (final e in (j['projects'] as List? ?? [])) Project.fromJson(Map<String, dynamic>.from(e as Map))]);
        chatProject
          ..clear()
          ..addAll(Map<String, String>.from((j['chats'] as Map?) ?? {}));
      }
    } catch (_) {}
    _ws = await AgentTools.workspaceDir();
    for (final p in list) {
      await files(p.id);
    }
    notifyListeners();
  }

  Future<void> _save() async {
    _p ??= await SharedPreferences.getInstance();
    await _p!.setString('projects_v1', jsonEncode({'projects': [for (final p in list) p.toJson()], 'chats': chatProject}));
    notifyListeners();
  }

  Project? byId(String? id) => id == null ? null : list.where((p) => p.id == id).firstOrNull;
  Project? forChat(String? chatId) => chatId == null ? null : byId(chatProject[chatId]);
  List<String> chatsIn(String projectId) => [for (final e in chatProject.entries) if (e.value == projectId) e.key];

  Future<Project> create(String name, {String instructions = ''}) async {
    final p = Project(id: const Uuid().v4(), name: name.trim().isEmpty ? 'New project' : name.trim(), instructions: instructions.trim());
    list.insert(0, p);
    await Directory(await filesDir(p.id)).create(recursive: true);
    await _save();
    return p;
  }

  Future<void> update(Project p, {String? name, String? instructions}) async {
    if (name != null && name.trim().isNotEmpty) p.name = name.trim();
    if (instructions != null) p.instructions = instructions.trim();
    p.updated = DateTime.now();
    await _save();
  }

  /// Deletes the project. Its chats stay, back in the main list.
  Future<void> delete(Project p) async {
    list.remove(p);
    chatProject.removeWhere((_, v) => v == p.id);
    await _save();
  }

  Future<void> assign(String chatId, String? projectId) async {
    if (projectId == null) {
      chatProject.remove(chatId);
    } else {
      chatProject[chatId] = projectId;
      byId(projectId)?.updated = DateTime.now();
    }
    await _save();
  }

  static Future<String> filesDir(String projectId) async => '${await AgentTools.workspaceDir()}/projects/$projectId';

  Future<List<File>> files(String projectId) async {
    final d = Directory(await filesDir(projectId));
    if (!await d.exists()) return [];
    final out = <File>[];
    await for (final e in d.list()) {
      if (e is File) out.add(e);
    }
    out.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    _fileCache[projectId] = [for (final f in out) f.path];
    return out;
  }

  Future<void> addFile(String projectId, String name, List<int> bytes) async {
    final dir = await filesDir(projectId);
    await Directory(dir).create(recursive: true);
    var target = File('$dir/$name');
    var i = 1;
    while (await target.exists()) {
      final dot = name.lastIndexOf('.');
      target = File(dot > 0 ? '$dir/${name.substring(0, dot)} ($i)${name.substring(dot)}' : '$dir/$name ($i)');
      i++;
    }
    await target.writeAsBytes(bytes);
    await files(projectId);
    notifyListeners();
  }

  /// What a chat inside a project adds to the system prompt.
  String promptFor(String? chatId) {
    final p = forChat(chatId);
    if (p == null) return '';
    final dir = '$_ws/projects/${p.id}';
    final files = _fileCache[p.id] ?? const <String>[];
    final sb = StringBuffer()
      ..writeln('# Project: ${p.name}')
      ..writeln('This chat is part of the project "${p.name}". Keep everything you do consistent with it.');
    if (p.instructions.isNotEmpty) {
      sb
        ..writeln('Project instructions from the user (follow them in every reply):')
        ..writeln(p.instructions);
    }
    if (files.isNotEmpty) {
      sb.writeln('Project files (read them with read_file or the document tools when relevant):');
      for (final f in files.take(60)) {
        sb.writeln('- $f');
      }
    }
    sb.writeln('Save files you make for this project into $dir.');
    return sb.toString();
  }

  /// Short memory of the project's other chats, so a new chat knows what was already done.
  List<String> otherChats(String? chatId) {
    final p = forChat(chatId);
    if (p == null) return const [];
    return [for (final c in chatsIn(p.id)) if (c != chatId) c];
  }
}
