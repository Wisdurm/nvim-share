import socket

HOST, PORT = "127.0.0.1", 8080

if __name__ == "__main__":
    try:
        with socket.create_connection((HOST, PORT), timeout=1.0) as client:
            print("connected")
            client.sendall(b"mirrit")
            client.shutdown(socket.SHUT_RDWR)
            print("disconnected")
            print("ok")
    except Exception as e:
        print(e)
        exit(1)
