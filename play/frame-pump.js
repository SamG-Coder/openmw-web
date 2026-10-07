// SPDX-License-Identifier: GPL-3.0-or-later
// One browser-paced engine tick at a time. Keep the MessageChannel task boundary:
// running the engine inside rAF previously regressed real SDL keyboard input.
(function (root) {
  'use strict';
  root.createOpenMWFramePump = function (env, tick) {
    var channel = new env.MessageChannel();
    var generation = 0, pending = false, stopped = true;
    var raf = null, timer = null, lastStart = null;
    // [start, interval, task delay, engine duration, stream stall, misses, bytes].
    // Fixed storage avoids allocating/shifting a diagnostic record every tick.
    var capacity = 360, stride = 7, samples = new Float64Array(capacity * stride), cursor = 0, count = 0, total = 0;
    var profile = /[?&]engineprofile=1(?:&|$)/.test(env.location && env.location.search || '');
    var profileModule = null, previousProfile, button = null;
    function cancel() {
      generation++;
      if (raf !== null) env.cancelAnimationFrame(raf);
      if (timer !== null) env.clearTimeout(timer);
      raf = timer = null;
      pending = false;
      lastStart = null;
    }
    function schedule() {
      if (stopped || pending) return;
      pending = true;
      var token = generation;
      function post() {
        if (stopped || token !== generation) return;
        raf = timer = null;
        channel.port2.postMessage({ generation: token, queuedAt: env.performance.now() });
      }
      if (env.document.hidden) timer = env.setTimeout(post, 33);
      else raf = env.requestAnimationFrame(post);
    }
    channel.port1.onmessage = function (event) {
      if (stopped || !pending || event.data.generation !== generation) return;
      pending = false;
      // CPU capture profiling is separate from renderdebug. It does not turn
      // on per-camera texture materialization or GPU pixel readbacks.
      var module = env.Module;
      if (profile && module && module.webgpuEnabled) {
        if (profileModule !== module) {
          profileModule = module; previousProfile = module.webcudaProfileCapture;
        }
        module.webcudaProfileCapture = true;
      }
      var ioBefore = profile ? env.__streamfsStats : null;
      var start = env.performance.now();
      try { tick(); }
      finally {
        var end = env.performance.now();
        if (!env.document.hidden) {
          if (lastStart !== null) {
            var offset = cursor * stride;
            samples[offset] = start;
            samples[offset + 1] = start - lastStart;
            samples[offset + 2] = start - event.data.queuedAt;
            samples[offset + 3] = end - start;
            var ioAfter = profile ? env.__streamfsStats : null;
            samples[offset + 4] = ioBefore && ioAfter ? Math.max(0, ioAfter.stallMs - ioBefore.stallMs) : 0;
            samples[offset + 5] = ioBefore && ioAfter ? Math.max(0, ioAfter.misses - ioBefore.misses) : 0;
            samples[offset + 6] = ioBefore && ioAfter ? Math.max(0, ioAfter.bytes - ioBefore.bytes) : 0;
            cursor = (cursor + 1) % capacity;
            count = Math.min(count + 1, capacity);
          }
          lastStart = start;
          total++;
        }
        schedule();
      }
    };
    function visibilityChanged() { cancel(); schedule(); }
    function snapshotSamples() {
      var result = [];
      for (var i = 0; i < count; i++) {
        var offset = ((cursor - count + i + capacity) % capacity) * stride;
        result.push({ startAt: samples[offset], intervalMs: samples[offset + 1],
          taskDelayMs: samples[offset + 2], engineMs: samples[offset + 3],
          streamStallMs: profile ? samples[offset + 4] : null, streamMisses: profile ? samples[offset + 5] : null,
          streamBytes: profile ? samples[offset + 6] : null });
      }
      return result;
    }
    function clone(value) { return value == null ? null : JSON.parse(JSON.stringify(value)); }
    var api = {
      start: function () {
        if (!stopped) return;
        stopped = false;
        env.__omwEnginePerformance = api;
        env.document.addEventListener('visibilitychange', visibilityChanged);
        if (profile && env.document.createElement && env.document.body) {
          button = env.document.createElement('button');
          button.textContent = 'Save engine + WebGPU report';
          Object.assign(button.style, { position: 'fixed', right: '8px', top: '8px', zIndex: '100002', padding: '8px' });
          button.addEventListener('click', api.saveReport);
          env.document.body.appendChild(button);
        }
        schedule();
      },
      stop: function () {
        stopped = true;
        cancel();
        env.document.removeEventListener('visibilitychange', visibilityChanged);
        if (button) { button.remove(); button = null; }
        if (profileModule && profileModule.webcudaProfileCapture === true)
          profileModule.webcudaProfileCapture = previousProfile;
        profileModule = null;
        if (env.__omwEnginePerformance === api) delete env.__omwEnginePerformance;
      },
      stats: function () {
        function percentile(column, fraction) {
          if (!count) return 0;
          var sorted = [];
          for (var i = 0; i < count; i++) sorted.push(samples[i * stride + column]);
          sorted.sort(function (a, b) { return a - b; });
          return +sorted[Math.ceil(fraction * sorted.length) - 1].toFixed(3);
        }
        var longTicks = 0;
        for (var i = 0; i < count; i++) if (samples[i * stride + 3] > 50) longTicks++;
        return { visibleTicks: total, sampleCount: count,
          intervalP50Ms: percentile(1, .5), intervalP95Ms: percentile(1, .95),
          intervalP99Ms: percentile(1, .99), taskDelayP95Ms: percentile(2, .95),
          engineP50Ms: percentile(3, .5), engineP95Ms: percentile(3, .95), engineP99Ms: percentile(3, .99),
          engineMaxMs: percentile(3, 1), engineTicksOver50Ms: longTicks,
          streamStallP95Ms: profile ? percentile(4, .95) : null, streamStallMaxMs: profile ? percentile(4, 1) : null };
      },
      report: function () {
        var host = env.__omwWebGPU || env.__omwWebCuda, counters = null, module = env.Module;
        try { counters = JSON.parse(host.canvas.dataset.webcudaStats || 'null'); } catch (_) {}
        return { schema: 'openmw-engine-webgpu-performance-v1', observedAt: new Date().toISOString(),
          url: env.location && env.location.href || null,
          timingNote: 'Engine tick and renderer submission times are wall-clock CPU observations, not GPU timestamp durations.',
          captureProfiling: profile, engine: api.stats(), engineFrames: snapshotSamples(),
          capturePhases: clone(module && module.webcudaCaptureTimings),
          shaderAnalysis: clone(module && module.webcudaShaderAnalysisStats), streaming: clone(env.__streamfsStats),
          renderer: clone(host && host.stats), rendererCounters: counters,
          rendererFrames: host && host.timingSnapshot ? clone(host.timingSnapshot()) : [] };
      },
      saveReport: function () {
        var url = env.URL.createObjectURL(new env.Blob([JSON.stringify(api.report(), null, 2) + '\n'], { type: 'application/json' }));
        var link = env.document.createElement('a');
        link.href = url; link.download = 'openmw-engine-webgpu-performance.json'; link.click();
        env.setTimeout(function () { env.URL.revokeObjectURL(url); }, 0);
      }
    };
    return api;
  };
})(globalThis);
