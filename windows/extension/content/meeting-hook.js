// Runs in the page's own JavaScript world on meeting sites: notices when the page holds a live
// microphone track (= you're in a call) and tells the bridge script.
(() => {
  if (window.__aistackHook) return;
  window.__aistackHook = true;
  const devices = navigator.mediaDevices;
  if (!devices || typeof devices.getUserMedia !== 'function') return;

  const tracks = new Set();
  let reported = null;

  const report = () => {
    for (const track of tracks) if (track.readyState !== 'live') tracks.delete(track);
    const active = tracks.size > 0;
    if (active !== reported) {
      reported = active;
      window.postMessage({ __aistack: 'mic', active }, '*');
    }
  };

  const watch = (track) => {
    if (track.kind !== 'audio' || tracks.has(track)) return;
    tracks.add(track);
    track.addEventListener('ended', report);
  };

  const original = devices.getUserMedia.bind(devices);
  devices.getUserMedia = function (constraints) {
    return original(constraints).then((stream) => {
      try { stream.getAudioTracks().forEach(watch); } catch {}
      report();
      return stream;
    });
  };

  const clone = MediaStreamTrack.prototype.clone;
  MediaStreamTrack.prototype.clone = function () {
    const copy = clone.call(this);
    if (tracks.has(this)) watch(copy);
    return copy;
  };

  const stop = MediaStreamTrack.prototype.stop;
  MediaStreamTrack.prototype.stop = function () {
    const result = stop.call(this);
    setTimeout(report, 0);
    return result;
  };

  setInterval(() => {
    report();
    // Re-announce periodically so the extension can tell a live call from a closed tab.
    window.postMessage({ __aistack: 'mic', active: reported === true }, '*');
  }, 4000);
})();
