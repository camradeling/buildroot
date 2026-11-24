#!/usr/bin/env python3
"""Walk all 16 digital outputs on the voodooboard, one at a time, 500ms each."""

import socket
import struct
import sys
import time

SLAVE_ADDR = 0xFF
DO_REGISTER = 1  # MBHR_DISCRETE_OUTPUTS_LOW
NUM_DO = 16
DELAY_S = 0.5
MODBUS_TCP_PORT = 502


def build_write_register_request(transaction_id, slave_addr, register, value):
    """Build Modbus TCP Write Single Register (FC 06) request."""
    # MBAP header: transaction_id(2) + protocol_id(2) + length(2) + unit_id(1)
    # PDU: function_code(1) + register(2) + value(2)
    pdu = struct.pack('>BHH', 0x06, register, value)
    mbap = struct.pack('>HHHB', transaction_id, 0x0000, len(pdu) + 1, slave_addr)
    return mbap + pdu


def send_request(sock, transaction_id, register, value):
    req = build_write_register_request(transaction_id, SLAVE_ADDR, register, value)
    sock.sendall(req)
    resp = sock.recv(256)
    if len(resp) < 9:
        raise RuntimeError(f"Short response ({len(resp)} bytes)")
    fc = resp[7]
    if fc & 0x80:
        raise RuntimeError(f"Modbus exception: code {resp[8]}")


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else MODBUS_TCP_PORT

    print(f"Connecting to {host}:{port}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5.0)
    sock.connect((host, port))

    tid = 0
    try:
        # Clear all outputs first
        tid += 1
        send_request(sock, tid, DO_REGISTER, 0x0000)
        print("All DOs cleared")
        time.sleep(0.1)

        for i in range(NUM_DO):
            value = 1 << i
            tid += 1
            send_request(sock, tid, DO_REGISTER, value)
            print(f"DO{i:2d} ON  (reg={DO_REGISTER} val=0x{value:04X})")
            time.sleep(DELAY_S)

        # Clear all outputs at the end
        tid += 1
        send_request(sock, tid, DO_REGISTER, 0x0000)
        print("All DOs cleared — done")

    finally:
        sock.close()


if __name__ == "__main__":
    main()
