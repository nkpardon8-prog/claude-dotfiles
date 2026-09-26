#!/usr/bin/env python3
"""pickup-time.py - turn a /pickup argument (or the cached rate-limit data)
into a fire time, cron strings and human-readable text.

Usage:
    pickup-time.py            derive from ~/.claude/ratelimit.json (5-hour or
                               weekly reset, whichever is the actual blocker)
    pickup-time.py 5:40pm     an explicit clock time, today or tomorrow
    pickup-time.py 17:40      same, 24-hour form
    pickup-time.py +90m       relative: minutes or hours from now

Input is forgiving (see normalize()): "1 min", "in 5 minutes", "2 hours", "1h30m", "1.5h",
"half an hour", "5 30 am", "530am", "0530", "5.30pm", "5:30 a.m.", "noon", "midnight",
"at 5:30pm", "tomorrow 5:30am" all resolve.

Env (mainly for the test harness, scripts/hooks/test-pickup-time.sh):
    PICKUP_NOW              epoch seconds to use as "now" instead of time.time()
    PICKUP_RATELIMIT_FILE   path to use instead of ~/.claude/ratelimit.json
    PICKUP_NO_REFRESH=1     never shell out to ~/.claude/refresh-ratelimit.sh

stdout: one JSON object, exit 0.
stderr: one line, exit 2, on any error - nothing is scheduled when this exits
non-zero, so the error message is the whole contract with the caller.

Standard library only. All times are handled as timezone-aware local
datetimes (via naive-datetime.astimezone(), which asks the platform's tz
database what the correct UTC offset is for that specific local wall-clock
moment) so DST transitions resolve correctly. Never add 86400 to cross a day
- date arithmetic (timedelta(days=1) on a date, not a datetime-with-seconds)
is what stays correct across DST changes and month/year boundaries.
"""
import json
import math
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta

BUFFER = 180            # seconds after a reset before firing, so the reset has actually landed
BACKUP_OFFSET = 1200     # 20 minutes after the main fire time
MIN_LEAD = 60            # refuse anything closer than this (so "/pickup 1 min" works)
MAX_OUT = 7 * 86400      # refuse anything further than this
REFRESH_AFTER = 300      # auto mode refreshes cached data older than this
HARD_STALE = 3600        # ...but refuses data older than this even after a refresh attempt

STATUS_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
# Clock: "5", "5:40", "5.40", "5 40", each with optional am/pm/a/p; or compact "530", "0530", "1730".
CLOCK_RE = re.compile(r"(\d{1,2})(?:[:. ](\d{2}))?\s*(am|pm|a|p)?")
COMPACT_CLOCK_RE = re.compile(r"(\d{1,2})(\d{2})\s*(am|pm|a|p)?")
# Relative: one or more "<number> <unit>" parts, e.g. "90m", "1h30m", "1.5 hours", "2 hours 15 minutes".
REL_UNIT = r"(?:h|hr|hrs|hour|hours|m|min|mins|minute|minutes)"
RELATIVE_RE = re.compile(r"\+?\s*(?:\d+(?:\.\d+)?\s*%s\s*(?:and\s*|,\s*)?)+" % REL_UNIT)
REL_PART_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(%s)" % REL_UNIT)

warnings = []


def err(msg):
    sys.stderr.write("pickup-time: %s\n" % msg)
    sys.exit(2)


def warn(msg):
    warnings.append(msg)


def now_epoch():
    override = os.environ.get("PICKUP_NOW")
    if override:
        try:
            return int(override)
        except ValueError:
            err("PICKUP_NOW must be an integer epoch")
    return int(time.time())


def ratelimit_path():
    return os.environ.get("PICKUP_RATELIMIT_FILE") or os.path.expanduser("~/.claude/ratelimit.json")


def coerce_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def coerce_float(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None  # NaN/Infinity would crash round() later


def coerce_status(v):
    return v if isinstance(v, str) and STATUS_RE.match(v) else "unknown"


def read_ratelimit(path):
    """Read + coerce the ratelimit cache. Every field off disk is untrusted -
    a reset can be JSON null, and a status can be "unknown" when its header
    was missing (scripts/refresh-ratelimit.sh:126-127). Returns a dict, or
    None if the file is missing, unreadable, not JSON, or has no usable
    fetched_at (fetched_at is the one field everything else is measured
    against, so without it the whole record is unusable)."""
    try:
        with open(path, "r") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None
    fetched_at = coerce_int(raw.get("fetched_at"))
    if fetched_at is None:
        return None
    return {
        "fetched_at": fetched_at,
        "five_h_reset": coerce_int(raw.get("five_h_reset")),
        "five_h_util": coerce_float(raw.get("five_h_util")),
        "five_h_status": coerce_status(raw.get("five_h_status")),
        "seven_d_reset": coerce_int(raw.get("seven_d_reset")),
        "seven_d_util": coerce_float(raw.get("seven_d_util")),
        "seven_d_status": coerce_status(raw.get("seven_d_status")),
    }


def load_rl(now, refresh):
    """Returns the coerced ratelimit dict, or None if it is unusable. When
    `refresh` is set and the cached data is older than REFRESH_AFTER, runs
    the same refresher the statusline uses and re-reads - but only once, and
    never when PICKUP_NO_REFRESH is set (the test harness always sets it)."""
    path = ratelimit_path()
    rl = read_ratelimit(path)
    no_refresh = os.environ.get("PICKUP_NO_REFRESH")
    if refresh and rl and (now - rl["fetched_at"] > REFRESH_AFTER) and not no_refresh:
        refresher = os.path.expanduser("~/.claude/refresh-ratelimit.sh")
        try:
            subprocess.run(
                [refresher],
                timeout=30,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.TimeoutExpired, subprocess.SubprocessError):
            pass  # fall through on the cached data; the HARD_STALE check below still applies
        rl = read_ratelimit(path)
    return rl


def local_dt_from_epoch(epoch):
    return datetime.fromtimestamp(epoch).astimezone()


def local_dt(date_obj, hour, minute):
    """Build an aware local datetime for a wall-clock time on a given date.
    astimezone() on a naive datetime asks the platform tz database what the
    correct UTC offset is for THAT local moment, which is what keeps this
    correct across a DST transition - there is no manual offset math here."""
    return datetime(date_obj.year, date_obj.month, date_obj.day, hour, minute).astimezone()


def ceil_to_minute(epoch):
    rem = epoch % 60
    return epoch if rem == 0 else epoch + (60 - rem)


def human(dt, ref_dt):
    """'5:43 PM' today, '5:43 PM tomorrow', or 'Tue Sep 30 5:43 PM' further out."""
    time_str = dt.strftime("%-I:%M %p")
    delta_days = (dt.date() - ref_dt.date()).days
    if delta_days == 0:
        return time_str
    if delta_days == 1:
        return "%s tomorrow" % time_str
    return "%s %s" % (dt.strftime("%a %b %d"), time_str)


def cron_string(dt):
    return "%d %d %d %d *" % (dt.minute, dt.hour, dt.day, dt.month)


def resolve_auto(now):
    rl = load_rl(now, refresh=True)
    if not rl:
        err("no rate-limit data; pass a time, e.g. /pickup 5:40pm")
    if now - rl["fetched_at"] > HARD_STALE:
        err("rate-limit data is stale; pass a time")

    weekly = rl["seven_d_status"] == "rejected" or (rl["seven_d_util"] or 0) >= 0.98
    reset = rl["seven_d_reset"] if weekly else rl["five_h_reset"]
    if reset is None:
        err("reset time unknown; pass a time")
    if reset <= now:
        err("that limit window has already reset; pass a time")

    fire = reset + BUFFER
    source = "weekly limit reset" if weekly else "5-hour limit reset"
    if weekly:
        warn("weekly limit: resume is days out; it only fires if this tab stays open and the Mac stays on")
    elif (rl["five_h_util"] or 0) < 0.5:
        warn(
            "usage is only %d%% - you may not hit the limit before this reset; the resume could fire early"
            % round((rl["five_h_util"] or 0) * 100)
        )
    if not weekly and (rl["seven_d_util"] or 0) >= 0.9:
        warn(
            "weekly limit is %d%% used - if THAT runs out first, this resume lands while still blocked "
            "(weekly resets %s)"
            % (round(rl["seven_d_util"] * 100), human(local_dt_from_epoch(rl["seven_d_reset"]), local_dt_from_epoch(now))
               if rl["seven_d_reset"] else "unknown")
        )
    return fire, source


def normalize(arg):
    """Lowercase + strip filler so natural phrasings reach the two parsers.
    Returns (text, day) where day is None, "today" or "tomorrow"."""
    a = arg.strip().lower()
    a = a.replace("a.m.", "am").replace("p.m.", "pm").replace("a.m", "am").replace("p.m", "pm")
    a = re.sub(r"\s+", " ", a)
    day = None
    for d in ("tomorrow", "tmrw", "tmr", "today"):
        if re.search(r"\b%s\b" % d, a):
            day = "today" if d == "today" else "tomorrow"
            a = re.sub(r"\b%s\b" % d, " ", a)
    a = re.sub(r"^(?:at|in|for|after|resume|around|about|by)\b", " ", a.strip()).strip()
    a = re.sub(r"\b(?:from now|later)\b", " ", a).strip()
    a = a.replace("half an hour", "30 minutes").replace("half hour", "30 minutes")
    a = re.sub(r"\b(?:an|a|one) hour\b", "1 hour", a)
    a = re.sub(r"\b(?:a|one) minute\b", "1 minute", a)
    a = re.sub(r"\s*o'?clock\b", "", a)
    a = re.sub(r"\s+", " ", a).strip()
    return a, day


def resolve_relative(now, arg):
    total = 0.0
    for n, unit in REL_PART_RE.findall(arg):
        total += float(n) * (3600 if unit.startswith("h") else 60)
    if total <= 0:
        err("a relative time must be more than zero")
    return now + int(round(total)), "relative"


def resolve_clock(now, arg, day=None):
    if arg == "noon":
        arg = "12:00pm"
    elif arg == "midnight":
        arg = "12:00am"
    m = CLOCK_RE.fullmatch(arg) or COMPACT_CLOCK_RE.fullmatch(arg)
    if not m:
        err("unrecognized time %r; try '5:40pm', '5 30 am', '17:40', '10 min', '2 hours', "
            "or run /pickup with no argument" % arg)
    h = int(m.group(1))
    mi = int(m.group(2)) if m.group(2) else 0
    ap = m.group(3)
    if ap in ("a", "p"):
        ap += "m"
    if mi > 59:
        err("minutes must be 00-59")

    if ap:
        if not (1 <= h <= 12):
            err("hour must be 1-12 when am/pm is given")
        hours = [(h % 12) + (12 if ap == "pm" else 0)]
    elif h > 12 or h == 0 or (len(m.group(1)) == 2 and m.group(1).startswith("0")):
        # "0530" / "05:30": a leading zero means 24-hour time, not "5:30 AM or PM"
        if h > 23:
            err("hour must be 0-23")
        hours = [h]
    else:
        hours = [h % 12, h % 12 + 12]

    local_now = local_dt_from_epoch(now)
    today = local_now.date()
    tomorrow = today + timedelta(days=1)
    days = {"today": (today,), "tomorrow": (tomorrow,)}.get(day, (today, tomorrow))
    candidates = [
        local_dt(d, hh, mi).timestamp()
        for d in days
        for hh in hours
    ]
    valid = [c for c in candidates if c >= now + MIN_LEAD]
    if not valid:
        err("that time has already passed (or is under a minute away)")
    fire = min(valid)
    if any(now < c < now + MIN_LEAD for c in candidates):
        warn("that time is under a minute away, so it was scheduled for the next occurrence instead")

    rl = load_rl(now, refresh=False)
    if rl and rl.get("five_h_reset") and (now - rl["fetched_at"] <= HARD_STALE) and fire < rl["five_h_reset"]:
        reset_human = human(local_dt_from_epoch(rl["five_h_reset"]), local_now)
        warn("that is before your limit resets at %s" % reset_human)
    if mi in (0, 30):
        warn("the scheduler may fire up to 90s early on :00/:30; the backup 20 min later covers it")

    return fire, "your time"


def main():
    now = now_epoch()
    arg, day = normalize(" ".join(sys.argv[1:]))

    if arg == "" and day is None:
        fire, source = resolve_auto(now)
    elif arg == "":
        err("give a time with that, e.g. '/pickup tomorrow 5:30am'")
    elif RELATIVE_RE.fullmatch(arg) and re.search(r"[a-z]", arg):
        if day:
            err("use either a duration ('2 hours') or a day + time ('tomorrow 5:30am'), not both")
        fire, source = resolve_relative(now, arg)
    else:
        fire, source = resolve_clock(now, arg.lstrip("+"), day)

    fire = ceil_to_minute(int(fire))
    # CronCreate fires one-shots on :00/:30 up to 90s EARLY (observed live 2026-09-26: a 12:30 job
    # ran at 12:28:42). For a COMPUTED time (auto / relative) that could land before the reset, so
    # step one minute off. A time the user typed stays exact by their choice (it only warns).
    if source != "your time" and local_dt_from_epoch(fire).minute in (0, 30):
        fire += 60
    if fire - now < MIN_LEAD:
        err("too soon - at least 1 minute out")
    if fire - now > MAX_OUT:
        err("more than 7 days out")
    backup = fire + BACKUP_OFFSET

    now_dt = local_dt_from_epoch(now)
    fire_dt = local_dt_from_epoch(fire)
    backup_dt = local_dt_from_epoch(backup)

    out = {
        "fire_epoch": fire,
        "fire_human": human(fire_dt, now_dt),
        "cron": cron_string(fire_dt),
        "backup_epoch": backup,
        "backup_human": human(backup_dt, now_dt),
        "backup_cron": cron_string(backup_dt),
        "source": source,
        "warnings": warnings,
    }
    print(json.dumps(out))
    sys.exit(0)


if __name__ == "__main__":
    main()
