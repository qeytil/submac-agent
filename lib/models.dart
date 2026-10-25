import 'dart:typed_data';

class Conversation {
  final String id;
  String title;
  String? model;
  bool pinned;
  bool archived;
  DateTime updatedAt;

  /// v1.12: the chat's messages are packed into a file in the account backup (older chats).
  String? archivePath;

  /// v1.12: this phone holds the whole chat, so it opens without the internet.
  bool onPhone;

  Conversation({
    required this.id,
    required this.title,
    this.model,
    this.pinned = false,
    this.archived = false,
    required this.updatedAt,
    this.archivePath,
    this.onPhone = true,
  });

  /// Packed away in the backup and not on this phone yet: opening it downloads it first.
  bool get packedAway => (archivePath ?? '').isNotEmpty && !onPhone;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        title: (j['title'] ?? 'New chat') as String,
        model: j['model'] as String?,
        pinned: (j['pinned'] ?? false) as bool,
        archived: (j['archived'] ?? false) as bool,
        updatedAt: DateTime.tryParse((j['updated_at'] ?? '') as String)?.toLocal() ?? DateTime.now(),
        archivePath: j['archive_path'] as String?,
        onPhone: (j['_local'] ?? true) as bool,
      );
}

class Attachment {
  final String name;
  final String mime;
  Uint8List? bytes;
  String? path; // Supabase storage path
  String? localPath; // copy inside the agent workspace
  String? extractedText; // text pulled out of a PDF (not saved)

  Attachment({required this.name, required this.mime, this.bytes, this.path, this.localPath});

  bool get isImage => mime.startsWith('image/');

  bool get isText {
    if (mime.startsWith('text/')) return true;
    const textMimes = ['application/json', 'application/xml', 'application/javascript', 'application/x-yaml'];
    return textMimes.contains(mime);
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'mime': mime,
        if (path != null) 'path': path,
        if (localPath != null) 'local_path': localPath,
      };

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        name: (j['name'] ?? 'file') as String,
        mime: (j['mime'] ?? 'application/octet-stream') as String,
        path: j['path'] as String?,
        localPath: j['local_path'] as String?,
      );

  static String mimeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'pdf': 'application/pdf',
      'json': 'application/json',
      'xml': 'application/xml',
      'yaml': 'application/x-yaml',
      'yml': 'application/x-yaml',
      'js': 'application/javascript',
    };
    if (map.containsKey(ext)) return map[ext]!;
    const textExts = [
      'txt', 'md', 'csv', 'tsv', 'log', 'py', 'dart', 'kt', 'java', 'ts', 'tsx', 'jsx', 'html', 'css', 'sh',
      'c', 'h', 'cpp', 'go', 'rs', 'rb', 'php', 'sql', 'toml', 'ini', 'env', 'swift',
    ];
    if (textExts.contains(ext)) return 'text/plain';
    return 'application/octet-stream';
  }
}

class ToolCall {
  String id;
  String name;
  String arguments;

  /// Provider data that must travel back with this call on the next request, exactly as received. Today that is
  /// Gemini's `extra_content` ({"google": {"thought_signature": "..."}}) from the OpenAI-compatible endpoint: without
  /// it Gemini 3 loses its reasoning between steps (and the server had to fake a skip value). Never shown, never edited.
  Map<String, dynamic>? extra;

  ToolCall({required this.id, required this.name, required this.arguments, this.extra});

  /// Gemini's thought signature, when the provider sent one.
  String? get thoughtSignature {
    final g = extra?['google'];
    final s = g is Map ? g['thought_signature'] : null;
    return s is String && s.isNotEmpty ? s : null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
        if (extra != null && extra!.isNotEmpty) 'extra_content': extra,
      };

  factory ToolCall.fromJson(Map<String, dynamic> j) {
    final fn = (j['function'] as Map?) ?? const {};
    final ex = j['extra_content'];
    return ToolCall(
      id: (j['id'] ?? '') as String,
      name: (fn['name'] ?? '') as String,
      arguments: (fn['arguments'] ?? '') as String,
      extra: ex is Map ? Map<String, dynamic>.from(ex) : null,
    );
  }
}

class ChatMessage {
  String id;
  final String role; // system | user | assistant | tool
  String content;
  List<ToolCall>? toolCalls;
  String? toolCallId;
  String? name;
  List<Attachment> attachments;
  bool streaming;
  String? error;

  /// True for replies created in this session, so their blocks animate in once.
  bool animateIn = false;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.toolCalls,
    this.toolCallId,
    this.name,
    List<Attachment>? attachments,
    this.streaming = false,
    this.error,
  }) : attachments = attachments ?? [];

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        role: j['role'] as String,
        content: (j['content'] ?? '') as String,
        toolCalls: (j['tool_calls'] as List?)
            ?.map((e) => ToolCall.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        toolCallId: j['tool_call_id'] as String?,
        name: j['name'] as String?,
        attachments: (j['attachments'] as List?)
            ?.map((e) => Attachment.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// Where model requests go. There is exactly one: SubMac Cloud (see services/cloud.dart).
class ProviderConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String defaultModel;
  final List<String> models;

  /// Per-minute and per-day limits the phone keeps to itself (0 = none; the server keeps the real ones).
  final int rpm;
  final int tpm;
  final int rpd;

  ProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.defaultModel,
    List<String>? models,
    this.rpm = 0,
    this.tpm = 0,
    this.rpd = 0,
  }) : models = models ?? const [];

  bool get hasLimits => rpm > 0 || tpm > 0 || rpd > 0;

  String get normalizedBaseUrl {
    var u = baseUrl.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}

/// A cloud model name for a job (chat, fast, vision...).
class ModelRef {
  final ProviderConfig provider;
  final String model;
  const ModelRef(this.provider, this.model);
}
