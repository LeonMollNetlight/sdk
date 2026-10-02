// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dartpad/dartpad.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

int get liveWorkers =>
    (web.window['dartpadWorkerTest']['live'] as JSNumber).toDartInt;

int get liveBlobUrls =>
    ((web.window['dartpadWorkerTest']['urls'] as JSObject)['size'] as JSNumber)
        .toDartInt;

int get initializingWorkers =>
    (web.window['dartpadWorkerTest']['initializing'] as JSNumber).toDartInt;

void evaluate(String script) {
  (web.window['eval'] as JSFunction).callAsFunction(web.window, script.toJS);
}

Future<void> waitForInitialization(int count) async {
  while (initializingWorkers < count) {
    await pumpEventQueue();
  }
}

void main() {
  late DartPadSdk sdk;
  final pending = Uri.parse('https://test.invalid/pending');

  setUpAll(() {
    evaluate('''
      (() => {
        const state = window.dartpadWorkerTest = {
          live: 0, workers: [], urls: new Set(), initializing: 0
        };
        const NativeWorker = window.Worker;
        const createUrl = URL.createObjectURL;
        const revokeUrl = URL.revokeObjectURL;
        window.Worker = class extends NativeWorker {
          constructor(...args) {
            super(...args);
            this.retired = false;
            state.live++;
            state.workers.push(this);
            this.addEventListener('message', event => {
              if (event.data?.action === 'initializing') state.initializing++;
            });
          }
          terminate() {
            if (!this.retired) { this.retired = true; state.live--; }
            super.terminate();
          }
        };
        URL.createObjectURL = blob => {
          const url = createUrl.call(URL, blob);
          state.urls.add(url);
          return url;
        };
        URL.revokeObjectURL = url => {
          state.urls.delete(url);
          revokeUrl.call(URL, url);
        };
        state.restore = () => {
          window.Worker = NativeWorker;
          URL.createObjectURL = createUrl;
          URL.revokeObjectURL = revokeUrl;
        };
      })();
    ''');
  });

  setUp(() {
    sdk = DartPadSdk(
      assetBaseUrl: Uri.base.resolve('fixtures/worker_startup/'),
    );
    evaluate('dartpadWorkerTest.initializing = 0;');
  });

  tearDown(() {
    // Retire blocked fixture workers even when an assertion fails.
    evaluate('''
      dartpadWorkerTest.workers.forEach(worker => worker.terminate());
      dartpadWorkerTest.workers = [];
      [...dartpadWorkerTest.urls].forEach(url => URL.revokeObjectURL(url));
    ''');
  });

  tearDownAll(() => evaluate('dartpadWorkerTest.restore();'));

  test(
    'an already completed trigger aborts startup and releases resources',
    () async {
      final abort = Completer<void>()..complete();
      await expectLater(
        sdk.dedicatedWorker(abortTrigger: abort.future),
        throwsA(isA<StateError>()),
      );
      expect(liveWorkers, 0);
      expect(liveBlobUrls, 0);
    },
  );

  test('an error completion also requests cancellation', () async {
    final abort = Completer<void>();
    final started = sdk.dedicatedWorker(
      abortTrigger: abort.future,
      pubHostedUrl: pending,
    );
    started.ignore();
    await waitForInitialization(1);

    abort.completeError(StateError('Caller failed during startup'));

    await expectLater(started, throwsA(isA<StateError>()));
    expect(liveWorkers, 0);
    expect(liveBlobUrls, 0);
  });

  test(
    'abort terminates a pending worker without its session handshake',
    () async {
      final abort = Completer<void>();
      final started = sdk.dedicatedWorker(
        abortTrigger: abort.future,
        pubHostedUrl: pending,
      );
      started.ignore();
      await waitForInitialization(1);
      expect(liveWorkers, 1);
      expect(liveBlobUrls, 1);

      abort.complete();

      // Completing the trigger schedules cancellation without a handshake.
      await expectLater(started, throwsA(isA<StateError>()));
      expect(liveWorkers, 0);
      expect(liveBlobUrls, 0);
    },
  );

  test('aborting one start leaves another pending start alive', () async {
    final firstAbort = Completer<void>();
    final secondAbort = Completer<void>();
    final first = sdk.dedicatedWorker(
      abortTrigger: firstAbort.future,
      pubHostedUrl: pending,
    );
    final second = sdk.dedicatedWorker(
      abortTrigger: secondAbort.future,
      pubHostedUrl: pending,
    );
    first.ignore();
    second.ignore();
    await waitForInitialization(2);

    firstAbort.complete();
    await expectLater(first, throwsA(isA<StateError>()));
    expect(liveWorkers, 1);
    expect(liveBlobUrls, 1);

    secondAbort.complete();
    await expectLater(second, throwsA(isA<StateError>()));
    expect(liveWorkers, 0);
    expect(liveBlobUrls, 0);
  });

  test(
    'worker initialization errors release the worker and Blob URL',
    () async {
      await expectLater(
        sdk.dedicatedWorker(
          pubHostedUrl: Uri.parse('https://test.invalid/error'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(liveWorkers, 0);
      expect(liveBlobUrls, 0);
    },
  );

  test(
    'native worker load failure settles startup and releases resources',
    () async {
      final missing = DartPadSdk(
        assetBaseUrl: Uri.base.resolve('fixtures/missing_worker/'),
      );
      await expectLater(missing.dedicatedWorker(), throwsA(isA<StateError>()));
      expect(liveWorkers, 0);
      expect(liveBlobUrls, 0);
    },
  );

  for (final completeWithError in [false, true]) {
    test('after the handshake the client owns disposal, '
        'trigger completes with error=$completeWithError', () async {
      final abort = Completer<void>();
      final client = await sdk.dedicatedWorker(abortTrigger: abort.future);
      addTearDown(client.dispose);

      if (completeWithError) {
        abort.completeError(StateError('Caller failed after startup'));
      } else {
        abort.complete();
      }
      await pumpEventQueue();
      expect(liveWorkers, 1);
      expect(liveBlobUrls, 1);

      await client.dispose();
      expect(liveWorkers, 0);
      expect(liveBlobUrls, 0);
    });
  }
}
