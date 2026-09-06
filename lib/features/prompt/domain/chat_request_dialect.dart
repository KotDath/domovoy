enum ChatRequestDialect { generic, ollama, deepSeek }

String chatRequestDialectLabel(ChatRequestDialect dialect) => switch (dialect) {
  ChatRequestDialect.generic => 'generic',
  ChatRequestDialect.ollama => 'ollama',
  ChatRequestDialect.deepSeek => 'deepSeek',
};

ChatRequestDialect? chatRequestDialectFromName(String? name) {
  return switch (name) {
    'generic' => ChatRequestDialect.generic,
    'ollama' => ChatRequestDialect.ollama,
    'deepSeek' => ChatRequestDialect.deepSeek,
    _ => null,
  };
}
