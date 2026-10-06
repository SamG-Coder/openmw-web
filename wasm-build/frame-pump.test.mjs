import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

function fixture() {
  let now = 0, id = 0, frames = 0;
  const rafs = new Map(), timers = new Map(), messages = [];
  const listeners = new Set();
  let receive;
  const env = {
    performance: { now: () => now },
    document: { hidden: false,
      addEventListener: (_, f) => listeners.add(f),
      removeEventListener: (_, f) => listeners.delete(f) },
    requestAnimationFrame: f => { rafs.set(++id, f); return id; },
    cancelAnimationFrame: id => rafs.delete(id),
    setTimeout: (f, delay) => { timers.set(++id, { f, delay }); return id; },
    clearTimeout: id => timers.delete(id),
    MessageChannel: class {
      port1 = { set onmessage(f) { receive = f; } };
      port2 = { postMessage: data => messages.push(data) };
    }
  };
  vm.runInNewContext(readFileSync(new URL('../play/frame-pump.js', import.meta.url), 'utf8'), env);
  const pump = env.createOpenMWFramePump(env, () => { frames++; now += 1; });
  function fire(map) {
    assert.equal(map.size, 1, 'exactly one scheduled callback');
    const [key, value] = map.entries().next().value;
    map.delete(key);
    (value.f ?? value)();
  }
  return { pump, rafs, timers, messages, get frames() { return frames; },
    advance: t => { now = t; }, raf: () => fire(rafs), timer: () => fire(timers),
    drain: () => { while (messages.length) receive({ data: messages.shift() }); },
    hide: hidden => { env.document.hidden = hidden; for (const f of listeners) f(); }
  };
}

test('follows changing 60/90/120/144/180 Hz callbacks with one task-delivered tick each', () => {
  const f = fixture(); f.pump.start(); f.pump.start();
  let time = 0, expected = 0;
  for (const hz of [60, 90, 120, 144, 180, 60, 180]) {
    for (let i = 0; i < hz; i++) {
      time += 1000 / hz; f.advance(time); f.raf();
      assert.equal(f.frames, expected, 'engine stays outside rAF');
      f.drain(); assert.equal(f.frames, ++expected);
      assert.equal(f.rafs.size, 1); assert.equal(f.timers.size, 0);
    }
  }
  assert.ok(Math.abs(f.pump.stats().intervalP50Ms - 1000 / 180) < .001);
});

test('visibility changes discard queued messages and cancel callbacks in both directions', () => {
  const f = fixture(); f.pump.start(); f.raf(); // visible message already queued
  f.hide(true); f.drain(); assert.equal(f.frames, 0);
  assert.equal(f.rafs.size, 0); assert.equal(f.timers.size, 1);
  f.timer(); // background message already queued
  f.hide(false); f.drain(); assert.equal(f.frames, 0);
  assert.equal(f.timers.size, 0); assert.equal(f.rafs.size, 1);
  f.raf(); f.drain(); assert.equal(f.frames, 1);
  for (let i = 0; i < 100; i++) { f.hide(true); f.hide(false); }
  f.raf(); f.drain(); assert.equal(f.frames, 2); assert.equal(f.rafs.size, 1);
});

test('hidden ticks are timer paced; stop invalidates queued work and restart is singular', () => {
  const f = fixture(); f.pump.start(); f.hide(true);
  assert.equal([...f.timers.values()][0].delay, 33);
  f.timer(); f.drain(); assert.equal(f.frames, 1);
  f.timer(); f.pump.stop(); f.drain(); assert.equal(f.frames, 1);
  assert.equal(f.timers.size, 0); assert.equal(f.rafs.size, 0);
  f.hide(false); assert.equal(f.rafs.size, 0);
  f.pump.start(); f.raf(); f.drain(); assert.equal(f.frames, 2);
});
