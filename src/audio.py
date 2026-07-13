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
        client.settimeout(1)

        with lock:
            clients.add(client)


def remove_client(client):
    with lock:
        clients.discard(client)

    try:
        client.close()
    except OSError:
        pass


def read_exact(fd, size):
    data = bytearray()

    while len(data) < size:
        chunk = os.read(fd, size - len(data))
        if not chunk:
            raise RuntimeError("Unexpected end of WAV stream")

        data.extend(chunk)

    return bytes(data)


def read_wav_header(fd):
    header = read_exact(fd, 12)

    if header[:4] != b"RIFF" or header[8:] != b"WAVE":
        raise RuntimeError("Invalid WAV header")

    while True:
        chunk = read_exact(fd, 8)
        chunk_id = chunk[:4]
        chunk_size = int.from_bytes(chunk[4:], "little")

        if chunk_id == b"data":
            return

        remaining = chunk_size + (chunk_size & 1)

        while remaining:
            skipped = os.read(fd, min(remaining, 4096))
            if not skipped:
                raise RuntimeError("Incomplete WAV chunk")

            remaining -= len(skipped)


threading.Thread(target=accept_loop, daemon=True).start()

while True:
    fd = os.open(FIFO, os.O_RDONLY)

    try:
        read_wav_header(fd)

        while True:
            data = os.read(fd, 4096)
            if not data:
                break

            with lock:
                current_clients = list(clients)

            for client in current_clients:
                try:
                    client.sendall(data)
                except OSError:
                    remove_client(client)
    finally:
        os.close(fd)
