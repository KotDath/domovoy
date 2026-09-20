final class TaskId {
  const TaskId(this.value) : assert(value != '');

  factory TaskId.parse(String value) {
    if (value.trim().isEmpty) throw const FormatException('Empty task id.');
    return TaskId(value);
  }

  final String value;

  @override
  bool operator ==(Object other) => other is TaskId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class TaskNodeId {
  const TaskNodeId(this.value) : assert(value != '');

  factory TaskNodeId.parse(String value) {
    if (value.trim().isEmpty) {
      throw const FormatException('Empty task node id.');
    }
    return TaskNodeId(value);
  }

  final String value;

  @override
  bool operator ==(Object other) => other is TaskNodeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
