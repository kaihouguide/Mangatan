import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/main_view/auto_sync_timer_controller.dart';

void main() {
  test('reacts to off, interval changes, and temporary disable', () async {
    final timers = <_TestTimer>[];
    var syncCount = 0;
    final controller = AutoSyncTimerController(
      onTick: () => syncCount++,
      timerFactory: _timerFactory(timers),
    );

    controller.configure((syncOn: true, frequencySeconds: 0));
    expect(timers, isEmpty);

    controller.configure((syncOn: true, frequencySeconds: 300));
    expect(timers, hasLength(1));
    expect(timers.single.interval, const Duration(minutes: 5));
    timers.single.fire();
    expect(syncCount, 1);
    await pumpEventQueue();

    controller.configure((syncOn: true, frequencySeconds: 300));
    expect(timers, hasLength(1), reason: 'An unchanged preference is a no-op.');
    expect(timers.single.isActive, isTrue);

    controller.configure((syncOn: true, frequencySeconds: 600));
    expect(timers, hasLength(2));
    expect(timers.first.isActive, isFalse);
    expect(timers.last.interval, const Duration(minutes: 10));

    controller.configure((syncOn: true, frequencySeconds: 0));
    expect(timers.last.isActive, isFalse);
    timers.last.fire();
    expect(syncCount, 1, reason: 'A temporary zero must stop pending writes.');

    controller.configure((syncOn: true, frequencySeconds: 600));
    expect(timers, hasLength(3));
    expect(timers.last.isActive, isTrue);
    timers.last.fire();
    expect(syncCount, 2);

    controller.dispose();
  });

  test('syncOn participates in scheduling even with a saved interval', () {
    final timers = <_TestTimer>[];
    final controller = AutoSyncTimerController(
      onTick: () {},
      timerFactory: _timerFactory(timers),
    );

    controller.configure((syncOn: false, frequencySeconds: 300));
    expect(timers, isEmpty);

    controller.configure((syncOn: true, frequencySeconds: 300));
    expect(timers, hasLength(1));

    controller.configure((syncOn: false, frequencySeconds: 300));
    expect(timers.single.isActive, isFalse);

    controller.dispose();
  });

  test('does not overlap automatic sync callbacks', () async {
    final timers = <_TestTimer>[];
    final firstSync = Completer<void>();
    var syncCount = 0;
    final controller = AutoSyncTimerController(
      onTick: () {
        syncCount++;
        return syncCount == 1 ? firstSync.future : Future<void>.value();
      },
      timerFactory: _timerFactory(timers),
    );
    controller.configure((syncOn: true, frequencySeconds: 1));

    timers.single
      ..fire()
      ..fire();
    expect(syncCount, 1);

    firstSync.complete();
    await pumpEventQueue();
    timers.single.fire();
    expect(syncCount, 2);

    controller.dispose();
  });

  test('an unexpected tick error stops only the active schedule', () async {
    final timers = <_TestTimer>[];
    final errors = <Object>[];
    var shouldFail = true;
    final controller = AutoSyncTimerController(
      onTick: () async {
        if (shouldFail) throw StateError('tick failed');
      },
      onError: (error, _) => errors.add(error),
      timerFactory: _timerFactory(timers),
    );
    const settings = (syncOn: true, frequencySeconds: 300);
    controller.configure(settings);

    timers.single.fire();
    await pumpEventQueue();
    expect(errors.single, isA<StateError>());
    expect(timers.single.isActive, isFalse);

    shouldFail = false;
    controller.configure(settings);
    controller.configure(settings);
    expect(timers, hasLength(2));
    timers.last.fire();
    await pumpEventQueue();
    expect(errors, hasLength(1));

    controller.dispose();
  });

  test('dispose cancels the timer and ignores later configuration', () {
    final timers = <_TestTimer>[];
    final controller = AutoSyncTimerController(
      onTick: () {},
      timerFactory: _timerFactory(timers),
    );
    controller.configure((syncOn: true, frequencySeconds: 300));

    controller.dispose();
    controller.configure((syncOn: true, frequencySeconds: 600));

    expect(timers, hasLength(1));
    expect(timers.single.isActive, isFalse);
  });
}

PeriodicTimerFactory _timerFactory(List<_TestTimer> timers) {
  return (interval, callback) {
    final timer = _TestTimer(interval, callback);
    timers.add(timer);
    return timer;
  };
}

class _TestTimer implements Timer {
  _TestTimer(this.interval, this._callback);

  final Duration interval;
  final void Function(Timer timer) _callback;

  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) return;
    _tick++;
    _callback(this);
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}
