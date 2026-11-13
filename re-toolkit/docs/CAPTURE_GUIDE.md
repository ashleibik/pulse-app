# Capturing BLE traffic

There are three ways to see what the band says, from easiest to most complete.

| Method | Sees | Needs | Good for |
|---|---|---|---|
| **A. Our own sniff.py** | everything the band sends **to us** | laptop with Bluetooth | 90% of the work: mapping fields in data the band already sends |
| **B. Android HCI snoop log** | everything between **the official app** and the band | Android phone + official WHOOP app | learning commands we don't know yet |
| **C. nRF52840 sniffer** | raw radio traffic between any two devices | ~$10–40 USB dongle | when you can't use B; advertising; low-level debugging |

> ⚠️ **Methods B and C need the official WHOOP app connected to the band.** The app can push a firmware update, and
> [OpenStrap reports](https://github.com/OpenStrap/edge) that newer firmware can withhold data from third-party apps.
> **Don't do B or C with this band** unless you accept that risk. Because of the risk, this project relies on A plus
> captures other researchers already published.

---

## A. sniff.py (start here)

From `re-toolkit/` with the venv active:

```powershell
python -m tools.sniff --scan                                       # find the band
python -m tools.sniff --label resting --hr-broadcast --realtime    # 5 minutes sitting still
#   ...type "walking" + Enter, walk around 5 min, type "resting" + Enter, sit 5 min, type q + Enter
python -m tools.decode_helper summary captures/*.jsonl
python -m tools.decode_helper hr captures/<file>.jsonl --type 0x28
```

### A good mapping experiment
1. **Change one thing at a time.** Rest → walk → rest. If a byte changes with the label, it's tied to that activity.
2. **Repeat the switch.** Rest, walk, rest, walk. A byte that only *trends over time* (counters, timestamps) correlates
   with "walking happened later". A byte that follows the *switches* is the real signal. `decode_helper hr` shows this
   trap: counters get r ≈ 0.85 in the synthetic test just because walking came second.
3. **Have ground truth.** `--hr-broadcast` gives the standard 0x2A37 HR next to the custom packets, so you know the
   right answer and can search for it.
4. **Write down every finding in PROTOCOL.md** with its confidence tag, and add the packet to
   `tests/fixtures/sample_frames.json` as `mine_*`.

---

## B. Android HCI snoop log + Wireshark

Android can record every Bluetooth packet the phone sends and receives (the "Host Controller Interface" log).

1. **Enable developer options:** Settings → About phone → tap *Build number* 7 times.
2. Settings → System → Developer options → **Enable Bluetooth HCI snoop log** → *Enabled* (not "filtered").
3. **Toggle Bluetooth off and on** (logging starts on restart).
4. Use the official app: open it, let it sync, toggle HR broadcast, and so on. **Write down the time of each action.**
5. Get the log out. The easiest way works on any phone:
   ```powershell
   adb bugreport bugreport.zip      # needs Android platform-tools + USB debugging enabled
   ```
   Inside the zip: `FS/data/misc/bluetooth/logs/btsnoop_hci.log`.
6. Open it in **Wireshark**. Useful display filters:
   ```
   btatt                                   # only GATT traffic
   btatt.handle == 0x0010                  # writes to CMD_TO_STRAP ([BW] handle)
   btatt.opcode == 0x1b                    # notifications
   btatt.value contains aa:08:00:a8        # 8-byte-inner command frames
   ```
7. Copy the hex of an interesting value (right-click → Copy → …as Hex Stream), then check it in Python:
   ```python
   from protocol.frames import parse_frame
   from protocol.parser import decode
   f = parse_frame(bytes.fromhex("aa0800a823080e016c935474")); print(f.valid, decode(f))
   ```
8. **Turn the snoop log off afterwards.** It keeps recording every Bluetooth device you use (headphones, car, etc.).

**iPhone equivalent:** Apple's PacketLogger (in *Additional Tools for Xcode*) plus the Bluetooth logging
profile from developer.apple.com. This needs a **Mac**.

---

## C. nRF52840 sniffer (hardware)

A sniffer listens to the radio directly, so it also sees traffic between two *other* devices.

1. Buy a **Nordic nRF52840 Dongle** (PCA10059, ~$10) or a board with Adafruit's nRF Sniffer firmware.
2. Flash the **nRF Sniffer for Bluetooth LE** firmware with nRF Connect for Desktop → Programmer.
3. Install the Wireshark extcap plugin from Nordic's nRF Sniffer package. *nRF Sniffer for Bluetooth LE* then
   shows up as a Wireshark capture interface.
4. Start capturing, pick the band from the device dropdown, **then** connect the phone. The sniffer has to see the
   connection start to follow the frequency hopping.
5. **Encryption:** if the band and phone are bonded, traffic is encrypted. You need the LTK (long-term key) from the
   phone or a capture of the pairing itself (legacy pairing only). This is why method B is usually easier: the HCI log
   is captured *above* the encryption.

---

## Privacy checklist for captures
- `captures/` and `*.jsonl` are **gitignored**. Keep it that way. They contain your heart rate, sleep times and location-ish metadata.
- Before sharing a capture publicly (e.g. a GitHub issue), strip it down to the few frames you need.
- HCI snoop logs contain **every** Bluetooth device you used. Never share a whole one.
