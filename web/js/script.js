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

function processInfo() {
    try {

        if (request.readyState != 4) {
            return true;
        }

        var msg = request.responseText;
        if (msg == null || msg.length == 0) {
            setError("Lost connection");
            schedule();
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
            setInfo("Connecting to VNC", true);

            var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
            var path = window.location.pathname.replace(/[^/]*$/, '').replace(/\/$/, '');
            var wsUrl = protocol + "//" + window.location.host + path + "/websockify";
            var webSocket = webSocketFactory.connect(wsUrl);

            return true;
        }

        setError("Error: Received statuscode " + request.status);
        schedule();
        return false;

    } catch (e) {
        var err = "Error: " + e.message;
        console.log(err);
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

function schedule() {
    setTimeout(getInfo, interval);
}

schedule();
