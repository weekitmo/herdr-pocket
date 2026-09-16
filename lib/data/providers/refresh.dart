import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/domain/refresh/refresh_style.dart';

/// The deck every pull-to-refresh draws from.
///
/// ONE DECK FOR THE WHOLE APP, rather than one per page. The board and the
/// workspace tree are the same gesture on two screens, and two decks would let
/// them hand out the same animation twice in a row — pull on the board, switch
/// to the tree, and the "different one every time" promise breaks at exactly
/// the moment the user is looking for it.
///
/// A provider rather than a field, because a field only exists on a stateful
/// widget and the tree's page is stateless — and because a deck that is rebuilt
/// is a deck that restarts, which would show the first style forever.
final refreshStyleDeckProvider = Provider<RefreshStyleDeck>(
  (ref) => RefreshStyleDeck(),
);
