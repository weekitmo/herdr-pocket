import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:herdr_pocket/data/notifications/attention_tracker.dart';

/// Raises a local notification when an agent starts waiting on a human.
///
/// SCOPE, STATED PLAINLY: this is a FOREGROUND/best-effort notification. It
/// fires while the app is alive — in the foreground, or recently backgrounded
/// before Android reclaims it. It does NOT wake a killed app.
///
/// Real background delivery needs a server that can push (FCM), and herdr has
/// no such thing: the daemon is on the user's own machine and reaches the phone
/// only over a connection the phone opened. So "notify me when an agent needs
/// me while the app is closed" is not a client-side problem, and pretending
/// otherwise with a foreground service would promise something the architecture
/// cannot keep. The honest version ships now; the honest limit is documented.
class AgentNotifier {
  AgentNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    this.onSelected,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Called with a pane id when the user taps a notification.
  ///
  /// A notification that does not take you to the thing it is about is half a
  /// feature: the user has to open the app, find the board, find the agent and
  /// tap it — which is exactly the work the notification was supposed to save.
  final void Function(String paneId)? onSelected;

  static const _channelId = 'agent_attention';
  static const _channelName = 'Agent needs you';
  static const _channelDescription =
      'Raised when a coding agent is waiting on your answer.';

  bool _ready = false;

  /// Prepares the plugin and asks for permission.
  ///
  /// Returns false when the user declined or the platform refused; callers
  /// should keep working and simply not notify, rather than treating this as a
  /// failure worth surfacing.
  Future<bool> initialise() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return false;

    try {
      await _plugin.initialize(
        // The payload is the pane id. Reading it back here rather than storing
        // "last notified" somewhere is what makes the tap land on the RIGHT
        // agent even when several are waiting.
        onDidReceiveNotificationResponse: (response) {
          final paneId = response.payload;
          if (paneId != null && paneId.isNotEmpty) onSelected?.call(paneId);
        },
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );

      // Android 13+ requires the runtime permission, and iOS requires an
      // explicit ask. Asking at startup is deliberate: an app that asks the
      // moment the first agent blocks is asking at the worst possible time.
      final granted = await _requestPermission();
      _ready = granted;
      return granted;
    } on Object {
      _ready = false;
      return false;
    }
  }

  Future<bool> _requestPermission() async {
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    return await ios?.requestPermissions(alert: true, badge: true, sound: true) ??
        false;
  }

  /// Raises one notification per newly-waiting agent.
  Future<void> notify(List<AgentAttention> attention) async {
    if (!_ready || attention.isEmpty) return;

    for (final item in attention) {
      try {
        await _plugin.show(
          // Keyed by pane so a second alert for the same agent REPLACES the
          // first rather than stacking. Three agents waiting should read as
          // three notifications, not as nine after three refreshes.
          id: item.paneId.hashCode & 0x7fffffff,
          title: item.title,
          body: item.agent.isEmpty ? 'Waiting for you' : '${item.agent} is waiting',
          payload: item.paneId,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDescription,
              importance: Importance.high,
              priority: Priority.high,
            ),
            iOS: DarwinNotificationDetails(),
          ),
        );
      } on Object {
        // A notification that cannot be shown must never take down the board.
      }
    }
  }
}
