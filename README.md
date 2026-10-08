# ConBee II on a UGREEN NAS (DXP2800 / Intel N100) via ser2net

Makes a **ConBee II** Zigbee stick work reliably with **Home Assistant ZHA** on a UGREEN NAS running UGOS Pro. The stick stays plugged into the NAS and is shared over the network with **ser2net** in a Docker container. Home Assistant connects to it over TCP.

One script does the whole setup: [`setup-conbee-ser2net-en.sh`](setup-conbee-ser2net-en.sh).

## The problem

I moved my ConBee II to a UGREEN DXP2800 (Intel N100, UGOS Pro) and Home Assistant could no longer use it. The NAS detected the stick fine (it showed up as `/dev/ttyACM0`), but Home Assistant couldn't talk to it:

- ZHA kept failing with `No response to 'CommandId.version'` and `Failed to connect to Zigbee adapter` (`Kan geen verbinding maken` in the Dutch UI).
- Passing the stick through by USB to my Home Assistant OS VM on the NAS didn't work either.
- The same stick with the same firmware worked fine on a Windows PC, so the stick itself was OK.

So the stick was detected and powered, and it answered, but its answers never arrived when they should.

## Root cause

**USB2 Link Power Management (LPM, L1).** The NAS puts the USB link into a power-saving state right after each command it sends. The ConBee II can't wake the link itself, so its reply waits on the stick until the host sends something else and wakes the link.

A `usbmon` trace showed this exactly: the reply to command *N* only reached the host right after command *N+1* was sent. Every answer was one step behind, so ZHA timed out on its very first command (`version`). Turning LPM off for the stick fixed it straight away.

You can check and fix it by hand (`<port>` is the stick's USB device, e.g. `1-3`):

```bash
cat /sys/bus/usb/devices/<port>/power/usb2_hardware_lpm   # 'enabled' = the problem
echo n | sudo tee /sys/bus/usb/devices/<port>/power/usb2_hardware_lpm
```

That only lasts until the stick is replugged or the NAS reboots. The script makes it permanent with a udev rule.

### Why ser2net instead of USB passthrough

LPM is set on the host (the NAS), so the stick has to stay on the NAS where the setting can be controlled. ser2net shares the serial port over TCP, so Home Assistant can use the stick wherever it runs: in a VM on the same NAS, in Docker, or on another machine.

## Setup

### Requirements

- UGREEN NAS with UGOS Pro, with Docker and SSH enabled
- ConBee II plugged into the NAS (**not** passed through to a VM)
- `python3` on the NAS (used for the final test only)
- Home Assistant ZHA (or any other Zigbee software) **disabled** while the script runs, so the test can use the stick

### Run the script

Copy the script to the NAS, log in over SSH and run:

```bash
sudo bash setup-conbee-ser2net-en.sh
```

Both settings are optional:

```bash
sudo DIR=/volume1/docker/ser2net PORT=20108 bash setup-conbee-ser2net-en.sh
```

| Variable | Default                  | Meaning                                     |
|----------|--------------------------|---------------------------------------------|
| `DIR`    | `/volume1/docker/ser2net` | Where `ser2net.yaml` and `docker-compose.yml` go |
| `PORT`   | `20108`                  | TCP port ser2net listens on                 |

### What the script does

1. Loads the `cdc_acm` USB serial driver.
2. Finds the stick under `/dev/serial/by-id/` (stops with a hint if it's missing, which usually means it's passed through to a VM).
3. Disables and masks ModemManager, if it's installed, because it can probe and block USB serial sticks.
4. Turns off USB LPM and USB autosuspend for the stick now, and adds a udev rule so they stay off after replugging and reboots: `/etc/udev/rules.d/99-conbee2-nolpm.rules` (matches vendor `1cf1`, product `0030`).
5. Creates `ser2net.yaml` and `docker-compose.yml` in `$DIR` and starts the `ser2net-conbee` container.
6. Waits for ser2net to listen, then sends 5 test commands and checks that each one gets its own answer. It should print `Result: 5/5 correct`.

You can run it again at any time. It overwrites the files and recreates the container.

### Files it creates

**`$DIR/ser2net.yaml`**

```yaml
connection: &conbee
  accepter: tcp,20108
  enable: on
  options:
    kickolduser: true
  connector: serialdev,/dev/ttyACM0,115200n81,local,nobreak
```

`kickolduser: true` lets a new client take over the connection, so Home Assistant can reconnect after a restart even if the old session is still open. ser2net only serves one client at a time.

**`$DIR/docker-compose.yml`**

```yaml
services:
  ser2net:
    image: debian:bookworm-slim
    container_name: ser2net-conbee
    restart: unless-stopped
    network_mode: host
    devices:
      - /dev/serial/by-id/usb-dresden_elektronik_ingenieurtechnik_GmbH_ConBee_II_<SERIAL>-if00:/dev/ttyACM0
    volumes:
      - ./ser2net.yaml:/etc/ser2net/ser2net.yaml:ro
    command: >
      sh -c "apt-get update &&
             apt-get install -y --no-install-recommends ser2net &&
             exec ser2net -d -c /etc/ser2net/ser2net.yaml"
```

The `by-id` path keeps working if the stick gets a different `ttyACM` number. The container installs ser2net on every start, so it needs internet access when it starts.

**`/etc/udev/rules.d/99-conbee2-nolpm.rules`**

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1cf1", ATTR{idProduct}=="0030", TEST=="power/usb2_hardware_lpm", ATTR{power/usb2_hardware_lpm}="n"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1cf1", ATTR{idProduct}=="0030", ATTR{power/control}="on"
```

## Home Assistant (ZHA) configuration

| Setting      | Value                                          |
|--------------|------------------------------------------------|
| Radio type   | ConBee / RaspBee (deCONZ), chosen manually     |
| Serial path  | `socket://<NAS-IP>:20108`                      |
| Speed        | `115200`                                       |
| Flow control | `none`                                         |
| Network      | **Keep / restore from backup**, never erase    |

ZHA uses `socket://`. Zigbee2MQTT uses `tcp://` (`serial: port: tcp://<NAS-IP>:20108`, `adapter: deconz`). Both point to the same ser2net port, but only one of them can use it at a time.

If ZHA is already set up, you only need to change the path: *Settings → Devices & services → Zigbee Home Automation → ⋮ → Reconfigure → Reconfigure current radio → Enter manually*.

## Home Assistant as a VM on the same NAS

UGOS VMs use **Bridge Mode-MacVTap** by default. With MacVTap, **the VM can't reach the NAS's own LAN IP**: `nc` returns `Host is unreachable`, even though other machines on the LAN can reach port 20108 fine.

Fix: add a **second network adapter** to the VM on **`vnet-host`** (Host-only).

1. Shut down the VM, then go to *Virtual Machine → VM → Edit → Network → Add* and pick `vnet-host`. Keep the original adapter.
2. Start the VM and look under *Settings → System → Network* in Home Assistant for the new interface (e.g. `192.100.1.x`).
3. Optional but recommended: give that interface a static IP with **no gateway and no DNS**, so normal traffic keeps using the LAN adapter.
4. Test it from the HA Terminal add-on:

   ```bash
   nc -vz 192.100.1.1 20108     # should say "open"
   ```

5. In ZHA, use `socket://192.100.1.1:20108` (the `.1` address on the host-only subnet is the NAS).

Alternatively you can switch the bridge to **Bridge Mode-LinuxBridge**. That changes the NAS's own network config and may drop your connection to the NAS for a moment.

## Verify

```bash
# LPM off for the ConBee (should print 'disabled')
d=$(dirname "$(grep -l 1cf1 /sys/bus/usb/devices/*/idVendor)"); cat "$d/power/usb2_hardware_lpm"

# Container running and restarting automatically
sudo docker ps | grep ser2net
sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' ser2net-conbee   # unless-stopped

# ser2net listening
sudo ss -tlnp | grep 20108

# Container log
sudo docker logs --tail 50 ser2net-conbee
```

**Check again after every NAS reboot and UGOS update.** It isn't documented whether UGOS updates keep `/etc/udev/rules.d/`. If the rule is gone, just run the script again.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `No response to 'CommandId.version'` or other `No response to ...` in ZHA | LPM is back on. Check `usb2_hardware_lpm` (see *Verify*) and set it to `n`, or run the script again. |
| Script says `No ConBee found in /dev/serial/by-id/` | The stick is passed through to a VM, or not plugged in. Remove the USB passthrough from the VM and replug the stick. |
| Test shows fewer than `5/5` | Another program (ZHA, Zigbee2MQTT, deCONZ) was connected to the stick. Stop it and run the script again. |
| ZHA config wizard says "New adapter not found" | The running ZHA integration already holds the socket (ser2net allows one client). Close the wizard and use **Reload** on ZHA. |
| `Host is unreachable` from HA | MacVTap isolation. See *Home Assistant as a VM on the same NAS*. |
| `MAC_CHANNEL_ACCESS_FAILURE` when switching lights | Radio congestion or interference. Normal for a few minutes after startup while devices rejoin. If it keeps happening, use a **USB extension cable** to move the stick away from the NAS, USB 3 drives and Wi-Fi. |
| Stick resets periodically (pairs of disconnects in `dmesg`) | The deCONZ firmware watchdog. Expected when no software keeps the stick alive; stops once ZHA is connected. |
| `ser2net.yaml: Is a directory` | Docker created a folder because the file didn't exist when the container started (happens with a manual setup). Run `docker compose down`, remove the folder, create the file, then run `docker compose up -d`. |
| Container keeps restarting | It couldn't install ser2net (no internet), or the stick's `by-id` path changed. Check `sudo docker logs ser2net-conbee`. |

### Manual stick test (ZHA disabled)

Run on the NAS. It sends 5 `version` requests through ser2net and prints each reply:

```bash
python3 - <<'EOF'
import socket,time
s=socket.create_connection(('127.0.0.1',20108));s.settimeout(2)
for n in range(1,6):
    b=bytes([0x0D,n,0,9,0,0,0,0,0]);c=(-sum(b))&0xFFFF
    s.send(b'\xc0'+b+c.to_bytes(2,'little')+b'\xc0')
    try: print(n,s.recv(100).hex())
    except Exception: print(n,'TIMEOUT')
    time.sleep(0.2)
EOF
```

- **Good:** line *n* starts with `c00d0n…` (`1 c00d01…`, `2 c00d02…`, and so on).
- **Bad:** line 2 is empty or `TIMEOUT`, and every answer after it is one step behind. That means LPM is the problem.

## Undo

```bash
cd /volume1/docker/ser2net && sudo docker compose down
sudo rm /etc/udev/rules.d/99-conbee2-nolpm.rules && sudo udevadm control --reload
sudo systemctl unmask ModemManager   # only if you want it back
```

Replug the stick (or reboot) to get the default power settings back.

## Notes

- Tested with ConBee II firmware `0x26780700`, Home Assistant Core 2026.10, HAOS 18.3, UGOS Pro on a DXP2800.
- If none of this works on your hardware, a network coordinator such as the **SMLIGHT SLZB-06** avoids USB altogether. ZHA can migrate the network to it from a backup without re-pairing devices.
