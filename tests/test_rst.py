#!/usr/bin/env python3
import socket, struct

HOST, PORT = "127.0.0.1", 8080

if __name__ == "__main__":
    with socket.create_connection((HOST, PORT), timeout=1.0) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        s.sendall(b"kattijengi")
        s.shutdown(socket.SHUT_RDWR)
        print("ok")