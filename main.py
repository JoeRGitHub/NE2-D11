import socket
import struct
from contextlib import closing

HOST = "192.168.1.7"   # כתובת ה-NE2
PORT = 502            # פורט ה-NE2
SLAVE_ID = 1
TIMEOUT = 3.0

# ---------- CRC16 Modbus ----------


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 0x0001:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def build_req(slave_id: int, func: int, addr: int, qty: int) -> bytes:
    pdu = struct.pack(">B B H H", slave_id, func, addr, qty)
    crc = crc16_modbus(pdu)
    return pdu + struct.pack("<H", crc)


def parse_resp(resp: bytes, qty: int):
    if len(resp) < 5:
        raise RuntimeError(f"short response: {resp!r}")
    func = resp[1]
    if func & 0x80:
        code = resp[2]
        raise RuntimeError(
            f"Modbus exception: func=0x{func:02X}, code=0x{code:02X}")
    byte_count = resp[2]
    expected = qty * 2
    if byte_count != expected:
        raise RuntimeError(f"byte_count={byte_count}, expected={expected}")
    data = resp[3:3+byte_count]
    # (אפשר לוותר על בדיקת CRC כאן אם אתה רוצה עוד יותר קצר)
    regs = []
    for i in range(0, len(data), 2):
        regs.append((data[i] << 8) | data[i+1])
    return regs


def read_inputs(sock, addr, qty):
    req = build_req(SLAVE_ID, 0x04, addr, qty)
    sock.sendall(req)
    resp = sock.recv(5 + qty*2 + 2)
    return parse_resp(resp, qty)


def read_holdings(sock, addr, qty):
    req = build_req(SLAVE_ID, 0x03, addr, qty)
    sock.sendall(req)
    resp = sock.recv(5 + qty*2 + 2)
    return parse_resp(resp, qty)


def u16_to_s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


def u_dword_r(low: int, high: int) -> int:
    # לפי המסמך: Low ברגיסטר הראשון, High בשני
    return (high << 16) | low


def main():
    status = {}

    with closing(socket.create_connection((HOST, PORT), timeout=TIMEOUT)) as sock:
        print("Connected to NE2 / EPEVER.\n")

        # ----- 3000: נתונים נומינליים -----
        r3000 = read_inputs(sock, 0x3000, 4)
        status["array_rated_voltage_V"] = r3000[0] * 0.01
        status["array_rated_current_A"] = r3000[1] * 0.01
        status["array_rated_power_W"] = u_dword_r(r3000[2], r3000[3]) * 0.01

        # ----- 3100: PV + טעינה -----
        r3100 = read_inputs(sock, 0x3100, 8)
        status["pv_voltage_V"] = r3100[0] * 0.01
        status["pv_current_A"] = r3100[1] * 0.01
        status["pv_power_W"] = u_dword_r(r3100[2], r3100[3]) * 0.01
        status["charge_voltage_V"] = r3100[4] * 0.01
        status["charge_current_A"] = r3100[5] * 0.01
        status["charge_power_W"] = u_dword_r(r3100[6], r3100[7]) * 0.01

        # ----- 3110/311A: טמפרטורות + SOC -----
        r3110 = read_inputs(sock, 0x3110, 3)   # 3110..3112
        status["battery_temp_C"] = u16_to_s16(r3110[0]) * 0.01
        status["device_temp_C"] = u16_to_s16(r3110[1]) * 0.01
        status["power_components_temp_C"] = u16_to_s16(r3110[2]) * 0.01

        r311a = read_inputs(sock, 0x311A, 2)  # 311A..311B
        status["battery_soc_pct"] = r311a[0]
        status["remote_batt_temp_C"] = u16_to_s16(r311a[1]) * 0.01

        # ----- 3200: סטטוסים -----
        r3200 = read_inputs(sock, 0x3200, 2)
        status["battery_status_raw"] = r3200[0]
        status["charger_status_raw"] = r3200[1]

        # ----- 3300: מתחים מקס/מינ -----
        r3300 = read_inputs(sock, 0x3300, 4)
        status["max_pv_voltage_today_V"] = r3300[0] * 0.01
        status["min_pv_voltage_today_V"] = r3300[1] * 0.01
        status["max_batt_voltage_today_V"] = r3300[2] * 0.01
        status["min_batt_voltage_today_V"] = r3300[3] * 0.01

        # ----- 330C: אנרגיה -----
        r330c = read_inputs(sock, 0x330C, 4)
        status["generated_energy_today_kWh"] = u_dword_r(
            r330c[0], r330c[1]) * 0.01
        status["generated_energy_month_kWh"] = u_dword_r(
            r330c[2], r330c[3]) * 0.01

        # ----- 331A: מתח/זרם סוללה -----
        r331a = read_inputs(sock, 0x331A, 3)
        status["battery_voltage_V"] = r331a[0] * 0.01
        raw_u = u_dword_r(r331a[1], r331a[2])
        if raw_u & 0x80000000:
            raw_s = raw_u - 0x100000000
        else:
            raw_s = raw_u
        status["battery_current_A"] = raw_s * 0.01

        # ----- 9000..9008: הגדרות סוללה -----
        r9000 = read_holdings(sock, 0x9000, 9)  # 9000..9008
        status["battery_type"] = r9000[0]
        status["battery_capacity_Ah"] = r9000[1]
        status["temp_comp_mV_perC_2V"] = r9000[2] * 0.01
        status["over_voltage_disconnect_V"] = r9000[3] * 0.01
        status["charging_limit_V"] = r9000[4] * 0.01
        status["over_voltage_reconnect_V"] = r9000[5] * 0.01
        status["equalize_voltage_V"] = r9000[6] * 0.01
        status["boost_voltage_V"] = r9000[7] * 0.01
        status["float_voltage_V"] = r9000[8] * 0.01

    # הדפסה
    for k, v in status.items():
        print(f"{k}: {v}")


if __name__ == "__main__":
    main()
