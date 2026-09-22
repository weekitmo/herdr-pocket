import 'package:flutter_riverpod/flutter_riverpod.dart';
// `FutureProviderFamily` is the explicit type of the family below, and it is
// exported from `misc.dart` rather than the main entry point. Importing it is
// what keeps the declaration annotated (and therefore checkable) instead of
// letting the inferred type stand.
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:herdr_pocket/data/git_client.dart';
import 'package:herdr_pocket/domain/git/git_tree_marks.dart';

/// What git knows about the directory the file browser is showing.
///
/// Keyed by the ABSOLUTE directory being browsed, because that is what the page
/// has and what pushing into a subdirectory changes. Two reads (the repository
/// root, then the status) per directory, which is the price of every level
/// knowing where it sits inside a repository — and the page shows its listing
/// immediately regardless, because the marks are read separately.
///
/// EVERY failure answers [GitTreeMarks.empty] rather than throwing: no runner,
/// no git, not a repository, a dead link. The highlight is an extra on top of a
/// directory listing, and a listing that turns into an error page because a
/// decoration could not be computed would be a worse screen than one with no
/// highlight.
final FutureProviderFamily<GitTreeMarks, String> gitTreeMarksProvider =
    FutureProvider.family<GitTreeMarks, String>(
  (ref, path) async {
    final client = ref.watch(gitClientProvider);
    if (client == null) return GitTreeMarks.empty();

    try {
      // The root is resolved first for the same reason the git page resolves it:
      // every path git prints afterwards is relative to the root, not to this
      // directory, and joining them onto this one would produce paths that do not
      // exist.
      final root = await client.repoRoot(path);
      if (root == null) return GitTreeMarks.empty();

      final result = await client.status(root);
      if (result is! GitStatusBody) return GitTreeMarks.empty();

      return GitTreeMarks.forStatus(root: root, entries: result.status.entries);
    } on Object {
      return GitTreeMarks.empty();
    }
  },
  isAutoDispose: true,
);
