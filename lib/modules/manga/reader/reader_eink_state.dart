import 'package:flutter/foundation.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';

class ReaderEInkState {
  ReaderEInkState._();

  static final enabled = ValueNotifier<bool>(false);
  static bool _initialized = false;
  static Future<void>? _initializing;

  static Future<void> initialize() async {
    if (_initialized) return;
    if (_initializing != null) return _initializing;
    final operation = _load();
    _initializing = operation;
    try {
      await operation;
    } finally {
      _initializing = null;
    }
  }

  static Future<void> _load() async {
    final stored = await MiningPreferences.getReaderEInkMode();
    // A toggle made while the stored value was loading is newer; keep it.
    if (_initialized) return;
    enabled.value = stored;
    _initialized = true;
  }

  @visibleForTesting
  static void resetForTesting() {
    enabled.value = false;
    _initialized = false;
    _initializing = null;
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    _initialized = true;
    await MiningPreferences.setReaderEInkMode(value);
  }
}
