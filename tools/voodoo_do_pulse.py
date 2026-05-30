#!/usr/bin/env python3
"""Turn on a digital output on the voodooboard for a specified duration, then turn it off."""

import socket
import struct
import sys
import time

SLAVE_ADDR = 0xFF
DO_REGISTER = 1  # MBHR_DISCRETE_OUTPUTS_LOW
MODBUS_TCP_PORT = 502
DEFAULT_HOST = "192.168.100.1"
DEFAULT_DURATION = 2.0
DEFAULT_DO = 0


def write_do(sock, value, tid):
    pdu = struct.pack('>BHH', 0x06, DO_REGISTER, value)
    mbap = struct.pack('>HHHB', tid, 0x0000, len(pdu) + 1, SLAVE_ADDR)
    sock.sendall(mbap + pdu)
    resp = sock.recv(256)
    if len(resp) < 9:
        raise RuntimeError(f"Short response ({len(resp)} bytes)")
    if resp[7] & 0x80:
        raise RuntimeError(f"Modbus exception: code {resp[8]}")


def main():
    do_num = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DO
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_DURATION
    host = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_HOST
    port = int(sys.argv[4]) if len(sys.argv) > 4 else MODBUS_TCP_PORT

    value = 1 << do_num

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5.0)
    sock.connect((host, port))

    try:
        write_do(sock, value, 1)
        print(f"DO{do_num} ON")
        time.sleep(duration)
        write_do(sock, 0x0000, 2)
        print(f"DO{do_num} OFF (after {duration}s)")
    finally:
        sock.close()


if __name__ == "__main__":
    main()
