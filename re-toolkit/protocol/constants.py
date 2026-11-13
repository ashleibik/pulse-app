"""
Protocol constants for the WHOOP 4.0 ("gen4") band.

Every value here is a FACT gathered from community reverse-engineering. We don't copy
anyone's code. Confidence tags match docs/PROTOCOL.md:

    VERIFIED   we checked it ourselves (math on real packets / capture from my band)
    CONFIRMED  two independent sources agree
    REPORTED   one source says so
    UNKNOWN    nobody knows / sources conflict

Sources:
    [BW] https://github.com/bWanShiTong/reverse-engineering-whoop-post
    [OS] https://github.com/OpenStrap/protocol  (lib/src/constants.dart, band.dart)
    [CM] https://github.com/christianmeurer/whoop-reader
"""

from enum import IntEnum

# --------------------------------------------------------------------------------------
# BLE identifiers
# --------------------------------------------------------------------------------------

# Every WHOOP gen4 UUID shares this base; only the first 8 hex chars change.
UUID_SUFFIX = "-8d6d-82b8-614a-1c8cb0f8dcc6"

# UNKNOWN: your notes and [CM] say 61080000, [OS] band.dart says 61080001.
# sniff.py prints the real GATT table, so we don't depend on either. We match by prefix.
SERVICE_UUID_CANDIDATES = ("61080000" + UUID_SUFFIX, "61080001" + UUID_SUFFIX)
WHOOP_UUID_PREFIX = "6108"

CHAR_CMD_TO_STRAP = "61080002" + UUID_SUFFIX     # write (with response)  CONFIRMED [BW][OS]
CHAR_CMD_FROM_STRAP = "61080003" + UUID_SUFFIX   # notify: command responses  CONFIRMED [BW][OS]
CHAR_EVENTS = "61080004" + UUID_SUFFIX           # notify: events  CONFIRMED [BW][OS] ([CM] disagrees)
CHAR_DATA = "61080005" + UUID_SUFFIX             # notify: realtime + history  CONFIRMED [BW][OS]
CHAR_MEMFAULT = "61080007" + UUID_SUFFIX         # notify: crash/diagnostic logs  REPORTED [BW]

# Standard Bluetooth SIG Heart Rate Measurement. Only sends data after "HR broadcast"
# is enabled via SET_GENERIC_HR_PROFILE (0x0E).  CONFIRMED [BW] + your whoop_live.py
CHAR_HEART_RATE_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"

# Friendly short names for logs.
CHAR_NAMES = {
    CHAR_CMD_TO_STRAP: "CMD_TO",
    CHAR_CMD_FROM_STRAP: "CMD_FROM",
    CHAR_EVENTS: "EVENTS",
    CHAR_DATA: "DATA",
    CHAR_MEMFAULT: "MEMFAULT",
    CHAR_HEART_RATE_MEASUREMENT: "HRM_2A37",
}


def char_name(uuid: str) -> str:
    """Short readable name for a characteristic UUID (falls back to the first 8 hex chars)."""
    return CHAR_NAMES.get(uuid.lower(), uuid.lower()[:8])


# --------------------------------------------------------------------------------------
# Frame-level constants (VERIFIED, see tests/test_crc.py)
# --------------------------------------------------------------------------------------

SOF = 0xAA           # start-of-frame byte
HEADER_LEN = 4       # AA | len_lo | len_hi | crc8(len)
CRC32_LEN = 4
MAX_FRAME_LEN = 4096  # sanity cap for the reassembler (from [OS] behaviour)


class PacketType(IntEnum):
    """inner[0]: what kind of packet this is. Source: [OS]; ✅ = also seen in [BW] samples."""
    COMMAND = 0x23              # phone -> band  ✅
    COMMAND_RESPONSE = 0x24     # band -> phone
    REALTIME_DATA = 0x28        # compact live HR + RR  ✅
    REALTIME_RAW = 0x2B
    HISTORICAL_DATA = 0x2F      # stored 1 Hz records  ✅
    EVENT = 0x30                # ✅
    METADATA = 0x31             # history start/end/complete markers  ✅
    CONSOLE_LOGS = 0x32
    REALTIME_IMU = 0x33
    HISTORICAL_IMU = 0x34


class Cmd(IntEnum):
    """inner[2] of a COMMAND packet: the opcode. Source: [OS] constants.dart, cross-checked with [BW]."""
    LINK_VALID = 0x01
    TOGGLE_REALTIME_HR = 0x03       # [BW] called it "start activity": payload 01 on / 00 off
    REPORT_VERSION_INFO = 0x07
    SET_CLOCK = 0x0A
    GET_CLOCK = 0x0B
    SET_GENERIC_HR_PROFILE = 0x0E   # "HR broadcast": turns on standard 0x2A37  [BW] verified frames
    FORGET_BONDS = 0x0F
    ABORT_HISTORICAL = 0x14
    SEND_HISTORICAL_DATA = 0x16
    HISTORICAL_DATA_RESULT = 0x17   # the ack for one history batch
    FORCE_TRIM = 0x19               # ERASES stored data  [BW] "erase device"
    GET_BATTERY_LEVEL = 0x1A
    REBOOT = 0x1D
    POWER_CYCLE = 0x20
    SET_READ_POINTER = 0x21
    GET_DATA_RANGE = 0x22
    GET_HELLO_HARVARD = 0x23
    START_UPDATE_LOAD = 0x24        # firmware update
    LOAD_UPDATE_DATA = 0x25         # firmware update
    PROCESS_UPDATE_IMAGE = 0x26     # firmware update
    SET_ALARM_TIME = 0x42
    GET_ALARM_TIME = 0x43
    GET_ADVERTISING_NAME = 0x4C
    GET_BODY_LOCATION_AND_STATUS = 0x54
    GET_EXTENDED_BATTERY_INFO = 0x62
    GET_CONFIG_KEY_COUNT = 0x73
    GET_CONFIG_KEY_NAME = 0x74
    SET_SIGNAL_CONFIG = 0x8A
    GET_HELLO = 0x91
    WEAR_DETECT_OVERRIDE = 0x94
    SET_LED_ACCESSIBILITY = 0x95
    PERSISTENT_OPTICAL_SAVE = 0x99
    TOGGLE_PERSISTENT_R21 = 0x9A


# --------------------------------------------------------------------------------------
# SAFETY: which commands our code is ever allowed to build.
#
# Security idea: ALLOWLIST, not blocklist. Anything not listed here is refused, including
# opcodes nobody has discovered yet. To add a command you must edit this file on purpose,
# and that change shows up in a git diff.
# --------------------------------------------------------------------------------------

# Read-only queries: they ask the band something and change nothing.
READ_ONLY_COMMANDS = frozenset({
    Cmd.LINK_VALID,
    Cmd.REPORT_VERSION_INFO,
    Cmd.GET_CLOCK,
    Cmd.GET_BATTERY_LEVEL,
    Cmd.GET_DATA_RANGE,
    Cmd.GET_HELLO_HARVARD,
    Cmd.GET_ALARM_TIME,
    Cmd.GET_ADVERTISING_NAME,
    Cmd.GET_BODY_LOCATION_AND_STATUS,
    Cmd.GET_EXTENDED_BATTERY_INFO,
    Cmd.GET_HELLO,
})

# Normal things the official app also does. They change band state, so tools only send
# them behind an explicit command-line flag.
STATEFUL_COMMANDS = frozenset({
    Cmd.TOGGLE_REALTIME_HR,        # temporary, turned off on exit
    Cmd.SET_GENERIC_HR_PROFILE,    # persistent setting! ([OS] lists it as dangerous). Ask the user first
    Cmd.SET_CLOCK,                 # fixes the band's clock
    Cmd.SEND_HISTORICAL_DATA,      # start history download
    Cmd.HISTORICAL_DATA_RESULT,    # ack a batch. The band may then free that flash space
    Cmd.ABORT_HISTORICAL,          # stop a history download
})

ALLOWED_COMMANDS = READ_ONLY_COMMANDS | STATEFUL_COMMANDS

# Documented for humans. Code never needs this list because the allowlist already
# excludes these. Source: [OS] dangerousCmds + [BW] erase/reboot captures.
KNOWN_DANGEROUS_COMMANDS = frozenset({
    Cmd.FORGET_BONDS, Cmd.FORCE_TRIM, Cmd.REBOOT, Cmd.POWER_CYCLE, Cmd.SET_READ_POINTER,
    Cmd.START_UPDATE_LOAD, Cmd.LOAD_UPDATE_DATA, Cmd.PROCESS_UPDATE_IMAGE,
    Cmd.SET_SIGNAL_CONFIG, Cmd.WEAR_DETECT_OVERRIDE, Cmd.SET_LED_ACCESSIBILITY,
    Cmd.PERSISTENT_OPTICAL_SAVE, Cmd.TOGGLE_PERSISTENT_R21,
})


# --------------------------------------------------------------------------------------
# Response / event / metadata codes
# --------------------------------------------------------------------------------------

class ResponseStatus(IntEnum):
    """inner[4] of a COMMAND_RESPONSE.  REPORTED [OS]"""
    FAILED = 0
    OK = 1
    DEFERRED = 2
    NOT_IMPLEMENTED = 3


class MetaType(IntEnum):
    """inner[2] of a METADATA packet.  HISTORY_END CONFIRMED ([BW] sample + [OS]); others REPORTED [OS]"""
    HISTORY_START = 1
    HISTORY_END = 2       # end of one batch: carries the 8-byte ack token
    HISTORY_COMPLETE = 3  # nothing more to send


class EventId(IntEnum):
    """u16 at inner[2:4] of an EVENT packet.  REPORTED [OS]"""
    BATTERY_LEVEL = 3
    CHARGING_ON = 7
    CHARGING_OFF = 8
    WRIST_ON = 9
    WRIST_OFF = 10
    RTC_LOST = 13
    DOUBLE_TAP = 14
    BOOT = 15
    SET_RTC = 16
    BATTERY_PACK_CONNECTED = 21
    BATTERY_PACK_REMOVED = 22
    TRIM_ALL_DATA = 26
    TRIM_ALL_DATA_ENDED = 27
    FLASH_INIT_COMPLETE = 28
    STRAP_CONDITION_REPORT = 29
    BLE_BONDED = 31
    BLE_REALTIME_HR_ON = 33
    BLE_REALTIME_HR_OFF = 34
    STRAP_DRIVEN_ALARM_SET = 56
    STRAP_DRIVEN_ALARM_EXECUTED = 57
    APP_DRIVEN_ALARM_EXECUTED = 58
    STRAP_DRIVEN_ALARM_DISABLED = 59
    HAPTICS_FIRED = 60
    EXTENDED_BATTERY_INFORMATION = 63
    HIGH_FREQ_SYNC_PROMPT = 96
    HIGH_FREQ_SYNC_ENABLED = 97
    HIGH_FREQ_SYNC_DISABLED = 98
    HAPTICS_TERMINATED = 100
    BATTERY_PACK_INFO = 109
    TEMPERATURE_LEVEL = 111
    GENERIC_FIRMWARE_EVENT = 123


def enum_name(enum_cls, value: int) -> str:
    """'GET_BATTERY_LEVEL' for a known value, '0x5a?' for an unknown one."""
    try:
        return enum_cls(value).name
    except ValueError:
        return f"0x{value:02x}?"


# Unix timestamps outside this window are treated as garbage (e.g. unset band clock).
PLAUSIBLE_UNIX_MIN = 1_600_000_000   # Sep 2020 (WHOOP 4.0 launched 2021)
PLAUSIBLE_UNIX_MAX = 4_102_444_800   # year 2100


def plausible_unix(ts: int) -> bool:
    return PLAUSIBLE_UNIX_MIN <= ts <= PLAUSIBLE_UNIX_MAX
