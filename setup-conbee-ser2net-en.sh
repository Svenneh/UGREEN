#!/usr/bin/env bash
# =============================================================================
#  Expose a ConBee II via ser2net (Docker) on a UGREEN NAS (UGOS Pro)
#  - disables USB2 LPM (link power management) for the ConBee II (persistent via udev)
#  - disables ModemManager (it can interfere with USB serial sticks)
#  - creates ser2net.yaml + docker-compose.yml and starts the container
#  - tests that the stick answers reliably through the socket
#
#  Usage:    sudo bash setup-conbee-ser2net-en.sh
#  Optional: sudo DIR=/volume1/docker/ser2net PORT=20108 bash setup-conbee-ser2net-en.sh
# =============================================================================
set -euo pipefail

DIR="${DIR:-/volume1/docker/ser2net}"
PORT="${PORT:-20108}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script with sudo:  sudo bash $0"
  exit 1
fi

COMPOSE="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"
  else echo "Docker Compose not found. Install/enable Docker in UGOS first."; exit 1; fi
fi

echo "== 1/6  Loading USB serial driver"
modprobe cdc_acm 2>/dev/null || true
sleep 2

echo "== 2/6  Looking for the ConBee II"
DEV="$(ls /dev/serial/by-id/ 2>/dev/null | grep -i 'ConBee' | head -n1 || true)"
if [ -z "$DEV" ]; then
  echo "No ConBee found in /dev/serial/by-id/."
  echo "Check: is the stick plugged into the NAS and NOT passed through to a VM?"
  exit 1
fi
DEV="/dev/serial/by-id/$DEV"
echo "   Found: $DEV"

echo "== 3/6  Disabling ModemManager (if present)"
if systemctl list-unit-files 2>/dev/null | grep -q '^ModemManager'; then
  systemctl disable --now ModemManager 2>/dev/null || true
  systemctl mask ModemManager 2>/dev/null || true
  echo "   ModemManager disabled"
else
  echo "   Not present, skipped"
fi

echo "== 4/6  Disabling USB power saving (LPM), now and persistently"
cat > /etc/udev/rules.d/99-conbee2-nolpm.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1cf1", ATTR{idProduct}=="0030", TEST=="power/usb2_hardware_lpm", ATTR{power/usb2_hardware_lpm}="n"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1cf1", ATTR{idProduct}=="0030", ATTR{power/control}="on"
EOF
udevadm control --reload
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] || continue
  if [ "$(cat "$d/idVendor")" = "1cf1" ] && [ "$(cat "$d/idProduct")" = "0030" ]; then
    [ -w "$d/power/usb2_hardware_lpm" ] && echo n > "$d/power/usb2_hardware_lpm" || true
    echo on > "$d/power/control" 2>/dev/null || true
    echo "   $(basename "$d"): LPM = $(cat "$d/power/usb2_hardware_lpm" 2>/dev/null || echo 'n/a')"
  fi
done

echo "== 5/6  Creating ser2net config and container in $DIR"
mkdir -p "$DIR"
cat > "$DIR/ser2net.yaml" <<EOF
connection: &conbee
  accepter: tcp,$PORT
  enable: on
  options:
    kickolduser: true
  connector: serialdev,/dev/ttyACM0,115200n81,local,nobreak
EOF

cat > "$DIR/docker-compose.yml" <<EOF
services:
  ser2net:
    image: debian:bookworm-slim
    container_name: ser2net-conbee
    restart: unless-stopped
    network_mode: host
    devices:
      - $DEV:/dev/ttyACM0
    volumes:
      - ./ser2net.yaml:/etc/ser2net/ser2net.yaml:ro
    command: >
      sh -c "apt-get update &&
             apt-get install -y --no-install-recommends ser2net &&
             exec ser2net -d -c /etc/ser2net/ser2net.yaml"
EOF

cd "$DIR"
$COMPOSE up -d --force-recreate

echo "== 6/6  Waiting for ser2net to listen and testing the stick"
for i in $(seq 1 90); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
  sleep 2
done

python3 - "$PORT" <<'EOF' || true
import socket, sys, time
port = int(sys.argv[1])
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
except Exception as e:
    print("   Cannot connect to ser2net:", e); sys.exit(1)
s.settimeout(2)
ok = 0
for n in range(1, 6):
    b = bytes([0x0D, n, 0, 9, 0, 0, 0, 0, 0]); c = (-sum(b)) & 0xFFFF
    s.send(b"\xc0" + b + c.to_bytes(2, "little") + b"\xc0")
    try:
        r = s.recv(100)
        good = len(r) > 2 and r[1] == 0x0D and r[2] == n
        ok += good
        print(f"   {n}: {'OK  ' if good else 'FAIL'} {r.hex()}")
    except Exception:
        print(f"   {n}: TIMEOUT")
    time.sleep(0.2)
print(f"   Result: {ok}/5 correct")
print("   " + ("Stick answers reliably via ser2net." if ok == 5
              else "Not all answers correct: make sure ZHA/other software was not connected, then run again."))
EOF

cat <<EOF

Done.
  Config dir : $DIR
  Stick      : $DEV
  Port       : $PORT

In Home Assistant (ZHA):
  Radio type : ConBee / RaspBee (deCONZ)
  Path       : socket://<NAS-IP>:$PORT
  Speed      : 115200, flow control: none
  Network    : KEEP / restore from backup (never erase)

Note for HA running as a VM on the same NAS with 'Bridge Mode-MacVTap':
  the VM cannot reach the NAS's own LAN IP. Give the VM a second network
  adapter on 'vnet-host' and use the NAS's host-only address
  (e.g. socket://192.100.1.1:$PORT). Test from HA with: nc -vz <ip> $PORT

Check after a NAS reboot or UGOS update:
  cat /sys/bus/usb/devices/*/power/usb2_hardware_lpm   (ConBee should show 'disabled')
EOF
