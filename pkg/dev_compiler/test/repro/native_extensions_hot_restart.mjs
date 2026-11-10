// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Manual regression against a compiled DDC canary SDK and its module loader.
// Requires Node.js 22+ and an isolated Chrome with --remote-debugging-port=9333.
//
// node native_extensions_hot_restart.mjs \
//   --sdk=/path/to/dart_sdk.js \
//   --loader=/path/to/ddc_module_loader.js
//
// The test opens and closes its own about:blank tab. Passing an unmodified
// module loader reproduces the failure against the same compiled SDK.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    sdk: { type: 'string' },
    loader: { type: 'string' },
    port: { type: 'string', default: '9333' },
  },
});
assert(values.sdk && values.loader, 'Pass --sdk and --loader paths.');
assert(/^\d+$/.test(values.port), 'The Chrome debugging port must be numeric.');

const endpoint = `http://127.0.0.1:${values.port}`;
const response = await fetch(`${endpoint}/json/new?about:blank`, { method: 'PUT' });
assert(response.ok, `Cannot open a test tab: ${response.status}`);
const tab = await response.json();
const socket = new WebSocket(tab.webSocketDebuggerUrl);
const pending = new Map();
let nextId = 0;

try {
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  };
  socket.onclose = () => {
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error('The test tab disconnected.'));
    }
    pending.clear();
  };

  function send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out.`));
      }, 30000);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description ??
        result.exceptionDetails.text);
    }
    return result.result.value;
  }

  const loader = await readFile(values.loader, 'utf8');
  const sdk = await readFile(values.sdk, 'utf8');
  // The loader reads document.currentScript during initialization.
  await evaluate(`(() => {
    const script = document.createElement('script');
    script.textContent = ${JSON.stringify(loader)};
    document.head.append(script);
    script.remove();
  })()`);
  await evaluate(sdk);
  await evaluate(`(() => {
    const embedder = dartDevEmbedder;
    embedder.defineLibrary('probe', library => {
      library[embedder.linkSymbol] = () => {};
      library.main = () => {};
    });
    self.$dartReloadModifiedModules = async (files, entryOrCallback) => {
      if (typeof entryOrCallback === 'function') entryOrCallback();
    };
    embedder.runMain('probe', {});
    self.nativeBaseline = Object.getOwnPropertySymbols(Function).length;
    self.userSymbol = Symbol('user property');
    Array.prototype[userSymbol] = 123;
    self.resets = 0;
    return true;
  })()`);

  // The legacy reset reuses its runtime and must leave extensions installed.
  assert(await evaluate(`(() => {
    dartDevEmbedder.importLibrary('dart:_runtime').hotRestart();
    return Object.getOwnPropertySymbols(Function).length === nativeBaseline;
  })()`), 'The legacy runtime reset removed native extensions.');

  for (let generation = 0; generation < 12; generation++) {
    await evaluate(`(() => {
      const runtime = dartDevEmbedder.importLibrary('dart:_runtime');
      runtime.resetFields.push(() => self.resets++);
      if (!self.otherFrame) {
        self.otherFrame = document.createElement('iframe');
        document.body.append(otherFrame);
      }
      runtime.applyAllExtensions(otherFrame.contentWindow);
      return true;
    })()`);
    // Cover both APIs on the canary library-bundle loader.
    if (generation % 2 === 0) {
      await evaluate('dartDevEmbedder.hotRestart()');
    } else {
      await evaluate(`dartDevEmbedder.hotRestartBegin([]).then(() => {
        dartDevEmbedder.hotRestartEnd();
      })`);
    }
    const state = await evaluate(`({
      symbols: Object.getOwnPropertySymbols(Function).length,
      otherSymbols: Object.getOwnPropertySymbols(
        otherFrame.contentWindow.Function).length,
      userProperty: Array.prototype[userSymbol],
      resets,
      baseline: nativeBaseline,
    })`);
    assert.equal(state.symbols, state.baseline,
      'Native constructor metadata accumulated across restarts.');
    assert.equal(state.otherSymbols, 0,
      'Native extensions in the other frame survived restart.');
    assert.equal(state.userProperty, 123,
      'Disposal removed an unrelated JavaScript property.');
    assert.equal(state.resets, generation + 1,
      'The outgoing runtime did not reset initialized static fields.');
  }

  // Tracking installed properties must not itself retain detached frames.
  await evaluate(`(() => {
    const frame = document.createElement('iframe');
    document.body.append(frame);
    const otherWindow = frame.contentWindow;
    dartDevEmbedder.importLibrary('dart:_runtime')
      .applyAllExtensions(otherWindow);
    self.detachedConstructor = new WeakRef(otherWindow.Function);
    frame.remove();
    return true;
  })()`);
  await new Promise(resolve => setTimeout(resolve, 100));
  await send('HeapProfiler.collectGarbage');
  assert.equal(await evaluate('!!detachedConstructor.deref()'), false,
    'Native-extension tracking retained a detached frame.');
  console.log('PASS: 12 restarts, both APIs, static reset, cross-frame cleanup, ' +
    'user properties, legacy reset, and detached-frame collection.');
} finally {
  await fetch(`${endpoint}/json/close/${tab.id}`).catch(() => {});
  socket.close();
}
