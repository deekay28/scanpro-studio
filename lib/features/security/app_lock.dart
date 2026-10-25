import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/providers.dart';

/// Device authentication (biometrics or screen-lock PIN/pattern/password)
/// through Android BiometricPrompt via local_auth.
class DeviceAuth {
  static final _auth = LocalAuthentication();

  static Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Returns true when the user authenticated. Errors are reported as false
  /// with [onError] receiving a readable message.
  static Future<bool> authenticate(String reason, {void Function(String)? onError}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } on PlatformException catch (e) {
      onError?.call(switch (e.code) {
        'NotAvailable' || 'NotEnrolled' || 'PasscodeNotSet' => 'Set up a screen lock or fingerprint in Android settings first.',
        'LockedOut' || 'PermanentlyLockedOut' => 'Too many attempts. Try again later.',
        _ => e.message ?? 'Authentication failed',
      });
      return false;
    } catch (e) {
      onError?.call(e.toString());
      return false;
    }
  }
}

/// Locks the app behind device authentication when enabled in settings.
/// Re-locks after the app has been in the background for 30 seconds.
class AppLockGate extends ConsumerStatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  bool _unlocked = false;
  bool _authInProgress = false;
  DateTime? _pausedAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ref.read(settingsProvider).appLock) return;
    if (state == AppLifecycleState.paused) {
      if (!_authInProgress) _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final p = _pausedAt;
      _pausedAt = null;
      if (p != null && DateTime.now().difference(p) > const Duration(seconds: 30)) {
        setState(() => _unlocked = false);
        _maybePrompt();
      }
    }
  }

  Future<void> _maybePrompt() async {
    if (!mounted || _unlocked || _authInProgress) return;
    if (!ref.read(settingsProvider).appLock) return;
    _authInProgress = true;
    final ok = await DeviceAuth.authenticate('Unlock ScanPro Studio', onError: (m) => _error = m);
    _authInProgress = false;
    if (!mounted) return;
    setState(() {
      _unlocked = ok;
      if (ok) _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(settingsProvider).appLock;
    if (!lock || _unlocked) return widget.child;
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline, size: 72, color: t.colorScheme.primary),
              const SizedBox(height: 16),
              Text('ScanPro Studio is locked', style: t.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('Use your fingerprint, face or screen lock to continue.', textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(onPressed: _maybePrompt, icon: const Icon(Icons.fingerprint), label: const Text('Unlock')),
            ]),
          ),
        ),
      ),
    );
  }
}
