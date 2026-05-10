Create EXE files form the py files (run from windows OS!)

Step 1 — Install Python (if not already installed)

Go to python.org/downloads, download the latest version, and install it.
Important: During install, check the box "Add Python to PATH".

Step 2 — First install the packages:

pip install pyinstaller requests

Step 3 — Build using python -m instead:

python -m PyInstaller --onefile --noconsole camera-switch_88_day_mode.py

Do the same for night mode:
python -m PyInstaller --onefile --noconsole camera-switch_88_night_mode.py

The python -m PyInstaller form always works regardless of PATH settings.
