import '../../../core/agents/agents.dart';
import '../../../core/support/support.dart';

/// Reserved support IDs include unfinished creation intents, so even an
/// interrupted creation can never appear as a normal workspace chat.
final class SupportSessionCatalog implements AgentSessionCatalog {
  SupportSessionCatalog(this.catalog, {this.support = false});
  final AgentSessionCatalog catalog;
  final bool support;
  @override
  Future<AgentSessionCatalogSnapshot> list() async {
    final snapshot = await catalog.list();
    return AgentSessionCatalogSnapshot(
      available: snapshot.available
          .where((s) => isSupportSession(s.id) == support)
          .toList(),
      issues: snapshot.issues
          .where((i) => i.id == null || isSupportSession(i.id!) == support)
          .toList(),
    );
  }
}
