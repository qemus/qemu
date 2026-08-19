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

    if (cb.disabled) {
      cb.checked = false;
    }

    var ctx = null;
    var ws = null;
    var nextTime = 0;
    var leftover = EMPTY;
    var vncConnected = document.documentElement.classList.contains(
      "noVNC_connected",
    );

    function stop() {
      var socket = ws;
      var context = ctx;

      ws = null;
      ctx = null;
      leftover = EMPTY;

      try {
        if (socket) {
          socket.close();
        }
      } catch (e) {}

      try {
        if (context) {
          context.close();
        }
      } catch (e) {}
    }

    function start() {
      if (
        cb.disabled ||
        !document.documentElement.classList.contains("noVNC_connected")
      ) {
        cb.checked = false;
        stop();
        return;
      }

      stop();

      var context = new (window.AudioContext || window.webkitAudioContext)({
        sampleRate: 48000,
      });

      var socket = new WebSocket(getURL() + "/audio");

      ctx = context;
      ws = socket;
      nextTime = context.currentTime + 0.15;

      socket.binaryType = "arraybuffer";

      socket.onmessage = function (event) {
        if (ws !== socket || ctx !== context) {
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

        var buffer = context.createBuffer(2, frames, 48000);
        var left = buffer.getChannelData(0);
        var right = buffer.getChannelData(1);

        for (var i = 0, j = 0; i < frames; i++) {
          left[i] = samples[j++] / 32768;
          right[i] = samples[j++] / 32768;
        }

        var source = context.createBufferSource();
        source.buffer = buffer;
        source.connect(context.destination);

        var startTime =
          nextTime > context.currentTime
            ? nextTime
            : context.currentTime + 0.02;

        source.start(startTime);
        nextTime = startTime + buffer.duration;
      };

      socket.onclose = function () {
        if (ws !== socket) {
          return;
        }

        ws = null;
        leftover = EMPTY;
        cb.checked = false;

        if (ctx === context) {
          ctx = null;

          try {
            context.close();
          } catch (e) {}
        }
      };

      socket.onerror = function () {
        socket.close();
      };
    }

    cb.addEventListener("change", function () {
      if (cb.checked && !cb.disabled) {
        start();
      } else {
        cb.checked = false;
        stop();
      }
    });

    var observer = new MutationObserver(function () {
      var connected = document.documentElement.classList.contains(
        "noVNC_connected",
      );

      if (vncConnected && !connected) {
        cb.checked = false;
        stop();
      }

      vncConnected = connected;
    });

    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class"],
    });
  }

  attach();
})();
