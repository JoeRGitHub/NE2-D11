import requests
from requests.auth import HTTPDigestAuth
import ctypes

URL = "http://192.168.194.152/cgi-bin/configManager.cgi?action=setConfig&RemoteChannel[4].Channel=0"
USERNAME = "admin"
PASSWORD = "H84@h84#h84"


def show_message(text, title, icon):
    # icon: 0x40 = info, 0x10 = error
    ctypes.windll.user32.MessageBoxW(0, text, title, icon)


try:
    response = requests.get(URL, auth=HTTPDigestAuth(
        USERNAME, PASSWORD), timeout=5)
    if response.status_code == 200:
        show_message("Day mode activated successfully.",
                     "Camera: Day Mode", 0x40)
    else:
        show_message(
            f"Request failed (HTTP {response.status_code}).", "Camera: Day Mode", 0x10)
except requests.exceptions.ConnectionError:
    show_message("Cannot reach the camera.\nCheck that you are on the correct network.",
                 "Camera: Day Mode", 0x10)
except Exception as e:
    show_message(f"Unexpected error:\n{e}", "Camera: Day Mode", 0x10)
