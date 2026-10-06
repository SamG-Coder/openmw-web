// SPDX-License-Identifier: GPL-3.0-or-later
// One browser-paced engine tick at a time. Keep the MessageChannel task boundary:
// running the engine inside rAF previously regressed real SDL keyboard input.
(function (root) {
  'use strict';
  root.createOpenMWFramePump = function (env, tick) {
    var channel = new env.MessageChannel();
    var generation = 0, pending = false, stopped = true;
    var raf = null, timer = null, lastStart = null;
    var samples = [], total = 0;
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
      var start = env.performance.now();
      try { tick(); }
      finally {
        var end = env.performance.now();
        if (!env.document.hidden) {
          if (lastStart !== null) {
            samples.push({ intervalMs: start - lastStart,
              taskDelayMs: start - event.data.queuedAt, engineMs: end - start });
            if (samples.length > 360) samples.shift();
          }
          lastStart = start;
          total++;
        }
        schedule();
      }
    };
    function visibilityChanged() { cancel(); schedule(); }
    return {
      start: function () {
        if (!stopped) return;
        stopped = false;
        env.document.addEventListener('visibilitychange', visibilityChanged);
        schedule();
      },
      stop: function () {
        stopped = true;
        cancel();
        env.document.removeEventListener('visibilitychange', visibilityChanged);
      },
      stats: function () {
        function percentile(key, fraction) {
          if (!samples.length) return 0;
          var sorted = samples.map(function (s) { return s[key]; }).sort(function (a, b) { return a - b; });
          return +sorted[Math.ceil(fraction * sorted.length) - 1].toFixed(3);
        }
        return { visibleTicks: total, sampleCount: samples.length,
          intervalP50Ms: percentile('intervalMs', .5), intervalP95Ms: percentile('intervalMs', .95),
          intervalP99Ms: percentile('intervalMs', .99), taskDelayP95Ms: percentile('taskDelayMs', .95),
          engineP95Ms: percentile('engineMs', .95) };
      }
    };
  };
})(globalThis);
