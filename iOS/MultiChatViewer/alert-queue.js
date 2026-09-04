/* MultiChat local notification scheduler. Payloads never cross the native bridge.
 * Provider internals are version dependent: unknown contracts fail closed.
 * This file is shared verbatim with the iPhone target. */
(() => {
  'use strict';
  if (window.__mcAlertQueue) return;
  // Guard media in same-origin child frames as well as the main document. An
  // uncontrolled custom sound must not play over another widget's notification.
  const controller = () => { try { return window.top.__mcAlertQueue; } catch (_) { return null; } };
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function(...args) {
    const queue = controller();
    if (!queue?.allowsMedia()) { queue?.mediaFault(); return Promise.reject(new Error('Notification is not active')); }
    queue.trackMedia(this);
    return play.apply(this,args);
  };
  if (typeof AudioBufferSourceNode !== 'undefined') {
    const start = AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start = function(...args) {
      const queue = controller();
      if (!queue?.allowsMedia()) { queue?.mediaFault(); return; }
      queue.trackAudio(this);
      return start.apply(this,args);
    };
  }
  if (window !== window.top) return;
  const later = window.setTimeout.bind(window);
  const items = new Map();
  const media = new Set(), audioNodes = new Set();
  let serial = 0, active = null, ready = false, failed = false, bypass = false, inFlight = null;
  const unsent = [];
  const send = (type, sequence = 0) => {
    const message = JSON.stringify({type, sequence});
    if (window.mcAlertBridge) window.mcAlertBridge.postMessage(message);
    else window.webkit?.messageHandlers?.mcAlertBridge?.postMessage(message);
  };
  const fault = () => { if (!failed) { failed = true; send('fault'); } };
  const admit = run => {
    const sequence = ++serial;
    items.set(sequence, run);
    unsent.push(sequence); pump();
  };
  const pump = () => {
    if (inFlight !== null || !unsent.length) return;
    inFlight = unsent.shift(); send('request', inFlight);
  };
  const finish = sequence => {
    if (failed || active !== sequence) return;
    active = null; items.delete(sequence); send('done', sequence);
  };
  window.__mcAlertQueue = Object.freeze({
    allowsMedia() { return bypass || (!failed && active !== null); },
    mediaFault: fault,
    trackMedia(element) { media.add(element); },
    trackAudio(node) { audioNodes.add(node); node.addEventListener('ended', () => audioNodes.delete(node), {once:true}); },
    grant(sequence) {
      if (failed || active !== null || !items.has(sequence)) return;
      active = sequence;
      later(() => { if (active === sequence && !failed) send('stalled', sequence); }, 120000);
      try { items.get(sequence)(() => finish(sequence)); } catch (_) { fault(); }
    },
    accepted(sequence) { if (inFlight === sequence) { inFlight = null; pump(); } },
    retry(sequence) { if (inFlight === sequence) later(() => { if (inFlight === sequence) send('request', sequence); }, 500); }
  });
  const connected = () => { ready = true; send('ready'); };
  // Capture one known constructor/service without changing existing own properties.
  // Every interception restores the prototype immediately; unsuccessful traps expire.
  const capture = (key, accept) => {
    if (Object.getOwnPropertyDescriptor(Object.prototype, key)) { fault(); return; }
    const setter = function(value) {
      Object.defineProperty(this, key, {value, writable:true, configurable:true, enumerable:true});
      try { if (accept(this, value)) cleanup(); } catch (_) { cleanup(); fault(); }
    };
    const cleanup = () => {
      if (Object.getOwnPropertyDescriptor(Object.prototype, key)?.set === setter) delete Object.prototype[key];
    };
    Object.defineProperty(Object.prototype, key, {configurable:true, set:setter, get() { return undefined; }});
    later(cleanup, 30000);
  };
  const waitUntil = (condition, done) => {
    let quiet = 0;
    const tick = () => {
      if (failed) return;
      try {
        if (condition()) { if (++quiet >= 3) { done(); return; } }
        else quiet = 0;
      } catch (_) { fault(); return; }
      later(tick, 100);
    };
    tick();
  };
  const mediaIdle = () => {
    if (audioNodes.size) return false;
    for (const el of media) {
      if (!el.paused && !el.ended && !el.error) return false;
      media.delete(el);
    }
    return true;
  };
  const host = location.hostname.toLowerCase();
  if (host === 'doneru.jp' || host.endsWith('.doneru.jp')) {
    capture('resolver', instance => {
      if (typeof instance.startEvent !== 'function' || typeof instance.push !== 'function' || typeof instance.clear !== 'function') return false;
      const start = instance.startEvent;
      instance.startEvent = function(...args) {
        return new Promise((resolve, reject) => admit(done => {
          let result;
          try { result = start.apply(this,args); } catch (error) { fault(); reject(error); return; }
          if (!result || typeof result.then !== 'function') { fault(); return; }
          result.then(value => waitUntil(mediaIdle, () => { done(); resolve(value); }), error => { fault(); reject(error); });
        }));
      };
      connected(); return true;
    });
  } else if (host === 'streamelements.com' || host.endsWith('.streamelements.com')) {
    const install = service => {
      if (!service || typeof service.push !== 'function' || typeof service.getQueue !== 'function' || typeof service.isAnimating !== 'function') return false;
      const original = service.push, animate = service.isAnimating;
      let began = false;
      service.isAnimating = function(id, playing) {
        if (active !== null && playing) began = true;
        return animate.apply(this, arguments);
      };
      service.push = function(...args) {
        admit(done => {
          began = false;
          original.apply(this,args);
          if (!began && this.getQueue().queue.length === 0) { done(); return; }
          // Asset downloads may precede isAnimating(true) by many seconds.
          // Never mistake that loading gap for completion.
          waitUntil(() => began && this.getQueue().playing.length === 0 && mediaIdle(), done);
        });
      };
      connected(); return true;
    };
    capture('eventQueueService', (_, value) => install(value));
  } else if (host === 'streamlabs.com' || host.endsWith('.streamlabs.com')) {
    capture('alertQueue', instance => {
      if (typeof instance.onDisplay !== 'function' || typeof instance.addAlertToQueue !== 'function') return false;
      const display = instance.onDisplay;
      // Premium pre-rolls and media-share have a separate scheduler. Decline
      // those paths instead of letting them bypass the global playback owner.
      if (typeof instance.onShowGifBeforeAlert === 'function') instance.onShowGifBeforeAlert = () => fault();
      // Hold the actual display call, after the provider's moderation/filtering.
      instance.onDisplay = function(...args) {
        admit(done => {
          const settings = args[2], event = args[1];
          if (!settings || !Number.isFinite(settings.duration) || settings.duration < 0 || event?.freeze) { fault(); return; }
          let pendingTTS = 0, pendingNetwork = 0, displayed = false, seenVisible = false;
          // TTS can start after textDelay and wait for a Polly request. Track those
          // operations as well as the actual audio player's queue.
          const xhrSend = XMLHttpRequest.prototype.send;
          // Only requests initiated by this display/TTS scope are tracked, and
          // only their completion count; no endpoint or response is retained.
          const scopedSend = function(...values) {
            pendingNetwork++;
            this.addEventListener('loadend', () => { pendingNetwork--; }, {once:true});
            try { return xhrSend.apply(this,values); } catch (error) { pendingNetwork--; throw error; }
          };
          const tts = this.playTTS;
          this.playTTS = function(...values) {
            const saved = window.setTimeout;
            // Keep network tracking installed until the delayed TTS callback runs.
            window.setTimeout = function(fn, ms, ...rest) {
              pendingTTS++;
              return saved.call(this, (...v) => {
                const previous = XMLHttpRequest.prototype.send;
                XMLHttpRequest.prototype.send = scopedSend;
                try { fn(...v); } finally { XMLHttpRequest.prototype.send = previous; pendingTTS--; }
              }, ms, ...rest);
            };
            try { return tts.apply(this,values); } finally { window.setTimeout = saved; }
          };
          try { display.apply(this,args); displayed = true; }
          finally { this.playTTS = tts; }
          waitUntil(() => {
            const frame = document.getElementById('sl_frame');
            const doc = frame?.contentDocument;
            if (!doc) throw Error('frame');
            const box = doc.getElementById('widget');
            if (!box) throw Error('layout');
            if (!box.classList.contains('hidden')) seenVisible = true;
            if (!seenVisible || !displayed || pendingTTS || pendingNetwork || !mediaIdle()) return false;
            const audio = this.audioPlayer;
            if (!audio || typeof audio.getQueueLength !== 'function') throw Error('contract');
            if (audio.isPlaying || audio.getQueueLength() || this.isPlayingMedia || this.sounds.length) return false;
            // The normal Streamlabs iframe is same-origin. Require its visual
            // alert to have disappeared; custom HTML without that contract stops.
            for (const el of doc.querySelectorAll('audio,video')) if (!el.paused && !el.ended && !el.error) return false;
            return box.classList.contains('hidden');
          }, done);
        });
      };
      connected(); return true;
    });
  } else fault();
  // Some saved browser sources use Streamlabs as a wrapper around an external
  // frame rather than the Alert Box runtime. Keep that source usable without
  // disabling every compatible widget in the shared queue.
  later(() => { if (!ready && !failed) { bypass = true; send('unsupported'); } }, 30000);
})();
