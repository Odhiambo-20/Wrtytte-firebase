import 'dart:convert';

/// MESSAGE TYPES (STRICT ENUM)

enum SocketMessageType {
  auth,
  message,
  typing,
  presence,
  system,
  error,
  unknown,
}

SocketMessageType _typeFromString(String? type) {
  switch (type) {
    case "auth":
      return SocketMessageType.auth;
    case "newMsg":
      return SocketMessageType.message;
    case "sendMsg":
      return SocketMessageType.message;
    case "typing":
      return SocketMessageType.typing;
    case "presence":
      return SocketMessageType.presence;
    case "cmdStatus":
      return SocketMessageType.system;
    case "error":
      return SocketMessageType.error;
    default:
      return SocketMessageType.unknown;
  }
}

String _typeToString(SocketMessageType type) {
  switch (type) {
    case SocketMessageType.message:
      return "sendMsg";
    case SocketMessageType.typing:
      return "typing";
    case SocketMessageType.presence:
      return "presence";
    case SocketMessageType.auth:
      return "auth";
    case SocketMessageType.system:
      return "cmdStatus";
    case SocketMessageType.error:
      return "error";
    case SocketMessageType.unknown:
      return "unknown";
  }
}

/// SOCKET MESSAGE MODEL

class SocketMessage {
  final SocketMessageType type;
  final Map<String, dynamic> payload;
  final String? status;
  final String? message;
  final DateTime? timestamp;

  const SocketMessage({
    required this.type,
    required this.payload,
    this.status,
    this.message,
    this.timestamp,
  });

  /// FROM JSON MAP

  factory SocketMessage.fromMap(Map<String, dynamic> map) {
    final cmd = map["cmd"] as String?;

    return SocketMessage(
      type: _typeFromString(cmd),
      payload: Map<String, dynamic>.from(map),
      status: map["status"]?.toString(),
      message: map["msg"]?.toString() ?? map["message"]?.toString(),
      timestamp:
          map["ts"] != null ? DateTime.tryParse(map["ts"].toString()) : null,
    );
  }

  /// FROM RAW JSON STRING

  factory SocketMessage.fromRaw(String source) {
    final decoded = jsonDecode(source);
    if (decoded is Map<String, dynamic>) {
      return SocketMessage.fromMap(decoded);
    }
    throw const FormatException("Invalid WebSocket message format");
  }

  /// TO MAP

  Map<String, dynamic> toMap() {
    return {
      "cmd": _typeToString(type),
      ...payload,
      if (status != null) "status": status,
      if (message != null) "message": message,
      if (timestamp != null) "ts": timestamp!.toUtc().toIso8601String(),
    };
  }

  /// TO JSON STRING (FOR SENDING)

  String toRaw() => jsonEncode(toMap());

  /// COPY WITH (IMMUTABILITY SAFE)

  SocketMessage copyWith({
    SocketMessageType? type,
    Map<String, dynamic>? payload,
    String? status,
    String? message,
    DateTime? timestamp,
  }) {
    return SocketMessage(
      type: type ?? this.type,
      payload: payload ?? this.payload,
      status: status ?? this.status,
      message: message ?? this.message,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  String toString() {
    return "SocketMessage(type: $type, status: $status, message: $message, payload: $payload, timestamp: $timestamp)";
  }
}
