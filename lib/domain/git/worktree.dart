/// Git worktrees, as herdr reports them.
///
/// herdr has a first-class concept here that most clients never surface:
/// `worktree.create` opens an isolated checkout **as a workspace**, which is
/// the honest way to give an agent its own copy of a repo. Verified against a
/// live 0.9.0 — `worktree.list` returns a `source` describing the repository
/// plus every checkout in it.
library;

/// One checkout in a repository.
class WorktreeInfo {
  const WorktreeInfo({
    required this.path,
    required this.label,
    this.branch,
    this.isBare = false,
    this.isDetached = false,
    this.isLinked = false,
    this.isPrunable = false,
    this.openWorkspaceId,
  });

  factory WorktreeInfo.fromJson(Map<String, Object?> json) => WorktreeInfo(
        path: _str(json['path']) ?? '',
        label: _str(json['label']) ?? '',
        branch: _str(json['branch']),
        isBare: json['is_bare'] == true,
        isDetached: json['is_detached'] == true,
        isLinked: json['is_linked_worktree'] == true,
        isPrunable: json['is_prunable'] == true,
        openWorkspaceId: _str(json['open_workspace_id']),
      );

  /// Absolute path of the checkout.
  final String path;

  /// What herdr calls it — the repo name for the main checkout.
  final String label;

  /// Null when the checkout is detached.
  final String? branch;

  final bool isBare;
  final bool isDetached;

  /// True for a worktree created FROM another checkout, i.e. the ones this
  /// feature is about. The main checkout is not linked.
  final bool isLinked;

  /// git says the checkout's directory is gone; `worktree prune` would remove
  /// the bookkeeping entry. Worth showing as stale rather than as usable.
  final bool isPrunable;

  /// The workspace herdr already has open on this checkout, if any.
  ///
  /// Non-null means opening it again should NAVIGATE rather than create — a
  /// second workspace on the same path is not an error, but it is never what
  /// the person meant.
  final String? openWorkspaceId;

  bool get isOpen => openWorkspaceId != null;

  /// The branch name to show when [branch] is null.
  String get shortBranch => branch ?? (isDetached ? 'detached' : '—');
}

/// The repository a listing came from.
class WorktreeSource {
  const WorktreeSource({
    required this.repoKey,
    required this.repoName,
    required this.repoRoot,
    required this.checkoutPath,
    this.sourceWorkspaceId,
  });

  factory WorktreeSource.fromJson(Map<String, Object?> json) => WorktreeSource(
        repoKey: _str(json['repo_key']) ?? '',
        repoName: _str(json['repo_name']) ?? '',
        repoRoot: _str(json['repo_root']) ?? '',
        checkoutPath: _str(json['source_checkout_path']) ?? '',
        sourceWorkspaceId: _str(json['source_workspace_id']),
      );

  final String repoKey;
  final String repoName;
  final String repoRoot;

  /// The checkout the question was asked FROM.
  final String checkoutPath;
  final String? sourceWorkspaceId;
}

/// `worktree.list`'s answer.
class WorktreeListing {
  const WorktreeListing({required this.source, required this.worktrees});

  factory WorktreeListing.fromJson(Map<String, Object?> json) {
    final source = json['source'];
    final list = json['worktrees'];
    return WorktreeListing(
      source: source is Map
          ? WorktreeSource.fromJson(source.cast<String, Object?>())
          : null,
      worktrees: list is List
          ? list
              .whereType<Map<Object?, Object?>>()
              .map((e) => WorktreeInfo.fromJson(e.cast<String, Object?>()))
              .toList(growable: false)
          : const [],
    );
  }

  /// Null when herdr could not describe a repository at that path — which is
  /// exactly the `not_git_worktree` case, and the reason the UI must ask before
  /// offering to create anything.
  final WorktreeSource? source;
  final List<WorktreeInfo> worktrees;

  bool get isRepository => source != null;

  /// The checkouts that are NOT the one we asked from, i.e. the ones with their
  /// own branch. These are what "open an existing worktree" should offer.
  List<WorktreeInfo> get linked =>
      worktrees.where((w) => w.isLinked).toList(growable: false);
}

String? _str(Object? v) => v is String ? v : null;
