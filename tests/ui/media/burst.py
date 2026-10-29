# Sends a burst of pings and prints the round trips.
import socket, time

def ping(host, port=7):
    s = socket.create_connection((host, port), timeout=2)
    t = time.monotonic()
    s.sendall(b"ping")
    s.recv(4)
    return (time.monotonic() - t) * 1000

if __name__ == "__main__":
    for i in range(10):
        print(f"{i}: {ping('localhost'):.2f} ms")
