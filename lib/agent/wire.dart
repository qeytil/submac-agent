// Conversion between SubMac's OpenAI-style chat (what ai-chat speaks, what the app builds its prompt as) and Genkit's
// typed messages. Lossless both ways for everything the app sends: each converted message keeps its original map in
// `metadata['oa']`, and a tool call keeps its exact argument text and provider data (Gemini thought signatures) in the
// part's metadata.
import 'dart:convert';

import 'package:genkit/genkit.dart';

import '../models.dart';

class Wire {
  Wire._();

  static const _oa = 'oa';

  /// Metadata keys on a tool request part.
  static const argsKey = 'args'; // the exact argument text the model wrote
  static const extraKey = 'extra_content'; // provider data to send back as is (Gemini thought signature)
  static const brokenKey = 'broken'; // the argument text was not a JSON object

  /// OpenAI messages → Genkit messages.
  static List<Message> toGenkit(List<Map<String, dynamic>> openai) {
    final names = <String, String>{};
    for (final m in openai) {
      final calls = m['tool_calls'];
      if (calls is List) {
        for (final c in calls) {
          if (c is Map) names['${c['id']}'] = '${(c['function'] as Map?)?['name'] ?? ''}';
        }
      }
    }
    return [for (final m in openai) _one(m, names)];
  }

  static Message _one(Map<String, dynamic> m, Map<String, String> names) {
    final role = '${m['role']}';
    final meta = {_oa: m};
    switch (role) {
      case 'system':
        return Message(role: Role.system, content: [TextPart(text: _text(m['content']))], metadata: meta);
      case 'assistant':
        final parts = <Part>[];
        final t = _text(m['content']);
        if (t.isNotEmpty) parts.add(TextPart(text: t));
        final calls = m['tool_calls'];
        if (calls is List) {
          for (final c in calls) {
            if (c is Map) parts.add(callToPart(ToolCall.fromJson(Map<String, dynamic>.from(c))));
          }
        }
        if (parts.isEmpty) parts.add(TextPart(text: ''));
        return Message(role: Role.model, content: parts, metadata: meta);
      case 'tool':
        final id = '${m['tool_call_id'] ?? ''}';
        return Message(role: Role.tool, content: [
          ToolResponsePart(toolResponse: ToolResponse(ref: id, name: '${m['name'] ?? names[id] ?? ''}', output: _text(m['content']))),
        ], metadata: meta);
      default:
        final c = m['content'];
        final parts = <Part>[];
        if (c is List) {
          for (final p in c) {
            if (p is! Map) continue;
            if (p['type'] == 'image_url') {
              final url = '${(p['image_url'] as Map?)?['url'] ?? ''}';
              final mime = RegExp(r'^data:([^;]+);').firstMatch(url)?.group(1);
              parts.add(MediaPart(media: Media(url: url, contentType: mime)));
            } else {
              parts.add(TextPart(text: '${p['text'] ?? ''}'));
            }
          }
        } else {
          parts.add(TextPart(text: _text(c)));
        }
        if (parts.isEmpty) parts.add(TextPart(text: ''));
        return Message(role: Role.user, content: parts, metadata: meta);
    }
  }

  static String _text(Object? c) {
    if (c == null) return '';
    if (c is String) return c;
    if (c is List) return c.whereType<Map>().where((p) => p['type'] == 'text').map((p) => '${p['text'] ?? ''}').join('\n');
    return '$c';
  }

  /// Genkit messages → OpenAI messages. A message that came from [toGenkit] goes back exactly as it was.
  static List<Map<String, dynamic>> toOpenAi(List<Message> msgs) {
    final out = <Map<String, dynamic>>[];
    for (final m in msgs) {
      final orig = m.metadata?[_oa];
      if (orig is Map) {
        out.add(Map<String, dynamic>.from(orig));
        continue;
      }
      final text = m.content.map((p) => p.textPart?.text ?? '').where((t) => t.isNotEmpty).join();
      if (m.role == Role.system) {
        out.add({'role': 'system', 'content': text});
      } else if (m.role == Role.model) {
        final calls = [for (final p in m.content) if (p.toolRequestPart != null) partToCall(p.toolRequestPart!)];
        out.add({
          'role': 'assistant',
          'content': text.isEmpty && calls.isNotEmpty ? null : text,
          if (calls.isNotEmpty) 'tool_calls': [for (final c in calls) c.toJson()],
        });
      } else if (m.role == Role.tool) {
        for (final p in m.content) {
          final r = p.toolResponsePart?.toolResponse;
          if (r == null) continue;
          final o = r.output;
          out.add({'role': 'tool', 'tool_call_id': r.ref ?? '', 'content': o is String ? o : jsonEncode(o)});
        }
      } else {
        final media = [for (final p in m.content) if (p.mediaPart != null) p.mediaPart!.media];
        if (media.isEmpty) {
          out.add({'role': 'user', 'content': text});
        } else {
          out.add({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': text},
              for (final md in media)
                {
                  'type': 'image_url',
                  'image_url': {'url': md.url},
                },
            ],
          });
        }
      }
    }
    return out;
  }

  /// A tool call → a Genkit tool request. The exact argument text and the provider data ride in the metadata.
  static ToolRequestPart callToPart(ToolCall c) {
    Object? input;
    var broken = false;
    try {
      final d = jsonDecode(c.arguments.trim().isEmpty ? '{}' : c.arguments);
      if (d is Map) {
        input = Map<String, dynamic>.from(d);
      } else {
        broken = true;
      }
    } catch (_) {
      broken = true;
    }
    return ToolRequestPart(
      toolRequest: ToolRequest(ref: c.id, name: c.name, input: input ?? <String, dynamic>{}),
      metadata: {
        argsKey: c.arguments,
        if (c.extra != null && c.extra!.isNotEmpty) extraKey: c.extra,
        if (broken) brokenKey: true,
      },
    );
  }

  /// A Genkit tool request → a tool call, with its exact argument text and provider data.
  static ToolCall partToCall(ToolRequestPart p) {
    final r = p.toolRequest;
    final meta = p.metadata ?? const {};
    final raw = meta[argsKey];
    final ex = meta[extraKey];
    return ToolCall(
      id: r.ref ?? r.name,
      name: r.name,
      arguments: raw is String ? raw : jsonEncode(r.input ?? const {}),
      extra: ex is Map ? Map<String, dynamic>.from(ex) : null,
    );
  }

  static bool isBroken(ToolRequestPart p) => p.metadata?[brokenKey] == true;

  /// The arguments of a tool request as a map ({} when they were not valid JSON).
  static Map<String, dynamic> argsOf(ToolRequestPart p) {
    final i = p.toolRequest.input;
    return i is Map ? Map<String, dynamic>.from(i) : <String, dynamic>{};
  }

  /// The tool name inside an OpenAI tool definition.
  static String toolName(Map<String, dynamic> def) => '${(def['function'] as Map?)?['name'] ?? def['name'] ?? ''}';
}
