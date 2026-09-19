enum ProjectFilesystemOpKind {
  stat,
  canonicalize,
  createDirectory,
  deleteDirectory,
  list,
  read,
  write,
  move,
  bookmark,
}

final class ProjectFilesystemOp {
  const ProjectFilesystemOp(this.kind, {this.detail});

  final ProjectFilesystemOpKind kind;
  final String? detail;
}

final class ProjectFilesystemOpLog {
  final List<ProjectFilesystemOp> ops = <ProjectFilesystemOp>[];

  void add(ProjectFilesystemOpKind kind, {String? detail}) {
    ops.add(ProjectFilesystemOp(kind, detail: detail));
  }

  bool get hasContentIo {
    return ops.any(
      (op) =>
          op.kind == ProjectFilesystemOpKind.read ||
          op.kind == ProjectFilesystemOpKind.write ||
          op.kind == ProjectFilesystemOpKind.move,
    );
  }

  bool get hasUserFileMutation {
    return ops.any(
      (op) =>
          op.kind == ProjectFilesystemOpKind.write ||
          op.kind == ProjectFilesystemOpKind.move ||
          op.kind == ProjectFilesystemOpKind.read,
    );
  }
}
