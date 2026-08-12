import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// A lease for one live SVG WebView.
///
/// WebView2 destruction is asynchronous.  The pool therefore keeps a released
/// lease counted for a short drain period so a new controller is not created
/// while the native controller from the previous one is still tearing down.
class SvgWebViewLease {
  SvgWebViewLease._(this._owner);

  final SvgWebViewControllerPool _owner;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(this);
  }
}

/// Limits the number of live SVG WebViews used by post signatures.
///
/// A platform WebView is much more expensive than a Flutter SVG painter.  The
/// setting still enables the WebView renderer, but only a small number of
/// visible signatures may own a live controller at once.  Other signatures
/// use a native fallback or a WebView-generated snapshot.
class SvgWebViewControllerPool {
  SvgWebViewControllerPool._();

  static final instance = SvgWebViewControllerPool._();

  /// Windows WebView2 keeps renderer/GPU resources longer during teardown, so
  /// keep its live controller budget lower than mobile/Apple WebViews.
  static int get maxControllers =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows ? 2 : 3;

  static const _nativeTeardownCooldown = Duration(milliseconds: 750);

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final Set<SvgWebViewLease> _leases = <SvgWebViewLease>{};

  SvgWebViewLease? tryAcquire() {
    if (_leases.length >= maxControllers) return null;

    final lease = SvgWebViewLease._(this);
    _leases.add(lease);
    revision.value++;
    AppLogger.debug(
      'slot_acquired',
      tag: 'SvgWebViewPool',
      fields: {
        'active': _leases.length,
        'max': maxControllers,
      },
    );
    return lease;
  }

  void _release(SvgWebViewLease lease) {
    // InAppWebView's Flutter dispose returns before WebView2 has necessarily
    // released its CompositionController and renderer resources.
    AppLogger.debug(
      'slot_release_scheduled',
      tag: 'SvgWebViewPool',
      fields: {
        'active': _leases.length,
        'cooldownMs': _nativeTeardownCooldown.inMilliseconds,
      },
    );
    Timer(_nativeTeardownCooldown, () {
      if (!_leases.remove(lease)) return;
      revision.value++;
      AppLogger.debug(
        'slot_release_completed',
        tag: 'SvgWebViewPool',
        fields: {
          'active': _leases.length,
          'max': maxControllers,
        },
      );
    });
  }

  int get activeCount => _leases.length;
}
