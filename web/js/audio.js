(function () {
  var EMPTY = new Uint8Array(0);

  function getURL() {
    var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    var path = window.location.pathname
      .replace(/[^/]*$/, "")
      .replace(/\/$/, "");

    return protocol + "//" + window.location.host + path;
  }

  function attach() {
    var cb = document.getElementById("noVNC_setting_audio");

    if (!cb) {
      setTimeout(attach, 300);
      return;
    }

    var ctx = null;
    var ws = null;
    var nextTime = 0;
    var leftover = EMPTY;

    function stop() {
      try {
        if (ws) {
          ws.close();
        }
      } catch (e) {}

      try {
        if (ctx) {
          ctx.close();
        }
      } catch (e) {}

      ws = null;
      ctx = null;
      leftover = EMPTY;
    }

    function start() {
      stop();

      ctx = new (window.AudioContext || window.webkitAudioContext)({
        sampleRate: 48000,
      });

      nextTime = ctx.currentTime + 0.15;

      ws = new WebSocket(getURL() + "/audio");
      ws.binaryType = "arraybuffer";

      ws.onmessage = function (event) {
        if (!ctx) {
          return;
        }

        var bytes;

        if (leftover.length) {
          bytes = new Uint8Array(leftover.length + event.data.byteLength);
          bytes.set(leftover);
          bytes.set(new Uint8Array(event.data), leftover.length);
        } else {
          bytes = new Uint8Array(event.data);
        }

        var usable = bytes.length & ~3;
        leftover = usable < bytes.length ? bytes.slice(usable) : EMPTY;

        if (!usable) {
          return;
        }

        var frames = usable >> 2;
        var samples = new Int16Array(
          bytes.buffer,
          bytes.byteOffset,
          usable >> 1,
        );

        var buffer = ctx.createBuffer(2, frames, 48000);
        var left = buffer.getChannelData(0);
        var right = buffer.getChannelData(1);

        for (var i = 0, j = 0; i < frames; i++) {
          left[i] = samples[j++] / 32768;
          right[i] = samples[j++] / 32768;
        }

        var source = ctx.createBufferSource();
        source.buffer = buffer;
        source.connect(ctx.destination);

        var startTime =
          nextTime > ctx.currentTime ? nextTime : ctx.currentTime + 0.02;

        source.start(startTime);
        nextTime = startTime + buffer.duration;
      };

      ws.onclose = function () {
        stop();
        cb.checked = false;
      };

      ws.onerror = function () {
        ws.close();
      };
    }

    cb.addEventListener("change", function () {
      if (cb.checked) {
        start();
      } else {
        stop();
      }
    });
  }

  attach();
})();
