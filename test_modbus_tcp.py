import socket
import struct
from contextlib import closing

HOST = "192.168.1.7"
PORT = 502
SLAVE_ID = 1
TIMEOUT = 3.0


def build_modbus_tcp_request(trans_id: int, unit_id: int, func: int, addr: int, qty: int) -> bytes:
    """Build standard Modbus TCP request (with MBAP header, no CRC)"""
    # MBAP Header: Transaction ID (2) + Protocol ID (2) + Length (2) + Unit ID (1)
    length = 6  # Unit ID + Function + Address + Quantity
    mbap = struct.pack(">H H H B", trans_id, 0, length, unit_id)

    # PDU: Function + Address + Quantity
    pdu = struct.pack(">B H H", func, addr, qty)

    return mbap + pdu


def parse_modbus_tcp_response(resp: bytes):
    """Parse standard Modbus TCP response"""
    if len(resp) < 9:
        raise RuntimeError(f"Response too short: {len(resp)} bytes")

    # Parse MBAP header
    trans_id = struct.unpack(">H", resp[0:2])[0]
    proto_id = struct.unpack(">H", resp[2:4])[0]
    length = struct.unpack(">H", resp[4:6])[0]
    unit_id = resp[6]

    # Parse PDU
    func = resp[7]
    if func & 0x80:
        error_code = resp[8]
        raise RuntimeError(
            f"Modbus exception: func=0x{func:02X}, error=0x{error_code:02X}")

    byte_count = resp[8]
    data = resp[9:9+byte_count]

    # Convert to registers
    regs = []
    for i in range(0, len(data), 2):
        regs.append((data[i] << 8) | data[i+1])

    return regs


def main():
    print("Testing NE2-D11 with STANDARD Modbus TCP (no CRC)...")
    print(f"Connecting to {HOST}:{PORT}\n")

    try:
        with closing(socket.create_connection((HOST, PORT), timeout=TIMEOUT)) as sock:
            print("✓ Connected")

            # Try reading PV voltage (register 0x3100 = 12544)
            print("\nSending standard Modbus TCP request:")
            print("  Function: 0x04 (Read Input Registers)")
            print("  Address: 0x3100 (12544)")
            print("  Quantity: 1 register")

            req = build_modbus_tcp_request(
                trans_id=1,
                unit_id=SLAVE_ID,
                func=0x04,
                addr=0x3100,
                qty=1
            )

            print(f"\nRequest bytes: {req.hex()}")
            sock.sendall(req)

            # Wait for response
            resp = sock.recv(1024)
            print(f"Response bytes: {resp.hex()}")
            print(f"Response length: {len(resp)} bytes")

            # Parse response
            regs = parse_modbus_tcp_response(resp)
            pv_voltage = regs[0] * 0.01

            print(f"\n✓ SUCCESS!")
            print(f"PV Voltage: {pv_voltage:.2f}V (raw: {regs[0]})")
            print("\n→ NE2-D11 SUPPORTS standard Modbus TCP!")
            print("→ TRB901 should work with proper configuration")

    except socket.timeout:
        print("\n✗ TIMEOUT - No response received")
        print("\n→ NE2-D11 does NOT support standard Modbus TCP")
        print("→ It only speaks Modbus RTU over TCP (with CRC)")
        print("→ You need a gateway/proxy for TRB901 to work")

    except Exception as e:
        print(f"\n✗ ERROR: {e}")
        print("\n→ NE2-D11 may not support standard Modbus TCP")


if __name__ == "__main__":
    main()
