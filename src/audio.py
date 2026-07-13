import os
import socket
import threading

PORT = 4712
FIFO = "/run/audio.fifo"

clients = set()
lock = threading.Lock()

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", PORT))
server.listen(16)

def accept_loop():
    while True:
        client, _ = server.accept()
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        with lock:
            clients.add(client)

threading.Thread(target=accept_loop, daemon=True).start()

while True:
    fd = os.open(FIFO, os.O_RDONLY)

    while True:
        data = os.read(fd, 4096)
        if not data:
            break

        with lock:
            for client in list(clients):
                try:
                    client.sendall(data)
                except Exception:
                    clients.discard(client)

                    try:
                        client.close()
                    except Exception:
                        pass

    os.close(fd)
