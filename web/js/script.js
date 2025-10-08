var request;
var interval = 1000;

var webSocketFactory = {
    connect: function(url) {

        var ws = new WebSocket(url);

        ws.addEventListener("open", e => {
            ws.close();
            document.location.reload();
        });

        ws.addEventListener("error", e => {
            if (e.target.readyState === 3) {
                setTimeout(() => this.connect(url), 1000);
            }
        });
    }
};

function getInfo() {

    var url = "msg.html";

    try {
        if (window.XMLHttpRequest) {
            request = new XMLHttpRequest();
        } else {
            throw "XMLHttpRequest not available!";
        }

        request.onreadystatechange = processInfo;
        request.open("GET", url, true);
        request.send();

    } catch (e) {
        var err = "Error: " + e.message;
        console.log(err);
        setError(err);
    }
}

function getURL() {

    var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    var path = window.location.pathname.replace(/[^/]*$/, '').replace(/\/$/, '');
    
    return protocol + "//" + window.location.host + path;
}

function processInfo() {
    try {

        if (request.readyState != 4) {
            return true;
        }

        var msg = request.responseText;
        if (msg == null || msg.length == 0) {
            setError("Lost connection");
            return false;
        }

        var notFound = (request.status == 404);

        if (request.status == 200) {
            if (msg.toLowerCase().indexOf("<html>") !== -1) {
                notFound = true;
            } else {
                setInfo(msg);
                return true;
            }
        }

        if (notFound) {
            setInfo("Connecting to VNC", true);

            var wsUrl = getURL() + "/websockify";
            var webSocket = webSocketFactory.connect(wsUrl);

            return true;
        }

        setError("Error: Received statuscode " + request.status);
        return false;

    } catch (e) {
        console.log("Error: " + e.message);
        setError(err);
        return false;
    }
}

function setInfo(msg, loading, error) {
    try {

        if (msg == null || msg.length == 0) {
            return false;
        }

        var el = document.getElementById("spinner");

        error = !!error;
        if (!error) {
            el.style.visibility = 'visible';
        } else {
            el.style.visibility = 'hidden';
        }

        loading = !!loading;
        if (loading) {
            msg = "<p class=\"loading\">" + msg + "</p>";
        }

        el = document.getElementById("info");

        if (el.innerHTML != msg) {
            el.innerHTML = msg;
        }

        return true;

    } catch (e) {
        console.log("Error: " + e.message);
        return false;
    }
}

function setError(text) {
    return setInfo(text, false, true);
}

function connect() {

  var wsUrl = getURL() + "/msg";
  var ws = new WebSocket(wsUrl);

  ws.onmessage = function(e) {
    console.log('Message:', e.data);
  };

  ws.onclose = function(e) {
    setTimeout(function() {
      connect();
    }, 1000);
  };

  ws.onerror = function(e) {
    console.log("Error: " + e.message);
    ws.close();
  };
}

getInfo();
connect();
