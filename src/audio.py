import os
import sys
import socket
import threading

FIFO = sys.argv[1]
SOCKET = sys.argv[2]

clients = set()
lock = threading.Lock()

try:
    os.unlink(SOCKET)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET)
os.chmod(SOCKET, 0o600)
server.listen(16)


def accept_loop():
    while True:
        client, _ = server.accept()
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
