var request;
var interval = 1000;

var webSocketFactory = {
    connect: function(url) {

        var ws = new WebSocket(url);

        ws.addEventListener("open", e => {
            ws.close();
            window.location.reload();
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
        setError("Error: " + e.message);
    }
}

function getURL() {

    var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    var path = window.location.pathname.replace(/[^/]*$/, '').replace(/\/$/, '');

    return protocol + "//" + window.location.host + path;
}

function redirect() {

    setInfo("Connecting to VNC", true);

    var wsUrl = getURL() + "/websockify";
    var webSocket = webSocketFactory.connect(wsUrl);

    return true;
}

function processInfo() {
    try {

        if (request.readyState != 4) {
            return true;
        }

        var msg = request.responseText;
        if (msg == null || msg.length == 0) {
            window.location.reload();
            return false;
        }

        var notFound = (request.status == 404);

        if (request.status == 200) {
            if (msg.toLowerCase().indexOf("<html>") !== -1) {
                notFound = true;
            } else {
                setInfo(msg);
                schedule();
                return true;
            }
        }

        if (notFound) {
            redirect();
            return true;
        }

        setError("Error: Received statuscode " + request.status);
        return false;

    } catch (e) {
        setError("Error: " + e.message);
        return false;
    }
}

function extractContent(s) {
    var span = document.createElement('span');
    span.innerHTML = s;
    return span.textContent || span.innerText;
};

function setInfo(msg, loading, error) {
    try {

        if (msg == null || msg.length == 0) {
            return false;
        }

        var el = document.getElementById("info");

        if (el.innerText == msg || el.innerHTML == msg) {
            return true;
        }

        var spin = document.getElementById("spinner");

        error = !!error;
        if (!error) {
            spin.style.visibility = 'visible';
        } else {
            spin.style.visibility = 'hidden';
        }

        var p = "<p class=\"loading\">";
        loading = !!loading;
        if (loading) {
            msg = p + msg + "</p>";
        }

        if (msg.includes(p)) {
            if (el.innerHTML.includes(p)) {
                el.getElementsByClassName('loading')[0].textContent = extractContent(msg);
                return true;
            }
        }

        el.innerHTML = msg;
        return true;

    } catch (e) {
        console.log("Error: " + e.message);
        return false;
    }
}

function setError(text) {
    console.warn(text);
    return setInfo(text, false, true);
}

function schedule() {
    setTimeout(getInfo, interval);
}

function connect() {

    var wsUrl = getURL() + "/status";
    var ws = new WebSocket(wsUrl);

    ws.onmessage = function(e) {

        var pos = e.data.indexOf(":");
        var cmd = e.data.substring(0, pos);
        var msg = e.data.substring(pos + 2);

        switch (cmd) {
            case "s":
                setInfo(msg);
                break;
            case "c":
                switch (msg) {
                    case "vnc":
                        redirect();
                        break;
                    default:
                        console.warn("Unknown command: " + msg);
                        break;
                }
                break;
            case "e":
                setError(msg);
                break;
            default:
                console.warn("Unknown event: " + cmd);
                break;
        }
    };

    ws.onclose = function(e) {
        setTimeout(function() {
            connect();
        }, interval);
    };

    ws.onerror = function(e) {
        ws.close();
        window.location.reload();
    };
}

schedule();
connect();
