import 'package:flutter/widgets.dart';

import '../../core/automation/automation.dart';
import 'automation_platform_stub.dart'
    if (dart.library.io) 'automation_platform_io.dart'
    as platform;

/// Foreground policy adapter of the automation scheduler.
///
/// On mobile the app calls [attach]; leaving the foreground stops the timers
/// and cancels a running execution (recorded as `interrupted`), returning to
/// the foreground resumes with the single catch-up rule. On desktop and web
/// [automationPausesInBackground] is false and the scheduler keeps working
/// while the process lives, which is the accepted scope: a closed application
/// never runs anything.
final class AutomationForegroundObserver with WidgetsBindingObserver {
  AutomationForegroundObserver({
    required this.service,
    bool Function()? pauseWhenBackgrounded,
  }) : pauseWhenBackgrounded =
           pauseWhenBackgrounded ?? platform.automationPausesInBackground;

  final AutomationService service;
  final bool Function() pauseWhenBackgrounded;
  var _attached = false;

  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void detach() {
    if (!_attached) {
      return;
    }
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!pauseWhenBackgrounded()) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        service.setForeground(true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        service.setForeground(false);
      case AppLifecycleState.inactive:
        // Transient (app switcher, notification shade): keep the timers.
        break;
    }
  }
}
