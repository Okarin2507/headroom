--!nonstrict
-- The Python program the analytics run (lib/analytics.luau). It lives here, as a
-- string, so the plugin needs no file path to find it: it is run as
--   python3 -I -c <this> <provider> <session start> <folder>...
-- It only reads the token counts Claude Code (<folder>/projects/**/*.jsonl),
-- Antigravity (<folder>/*.db conversations) and opencode (<folder>/opencode.db)
-- already keep, and prints one small
-- JSON document. It writes nothing and makes no network call.

return [==[
import sys, os, json, glob, time, datetime, sqlite3

# Headroom usage analytics. Read-only: aggregates the token counts Claude Code,
# Antigravity and opencode already keep on disk and prints one small JSON document.
# usage: python3 -c <this> <provider> <session_start_epoch|0> <dir> [<dir>...]

WEEK = 7 * 86400
MONTH = 30 * 86400
KEYS = ("input", "output", "messages")


def blank():
    return {"input": 0, "output": 0, "messages": 0}


def add(bucket, rec):
    for k in KEYS:
        bucket[k] += rec[k]


def clean_model(name):
    name = (name or "unknown").strip()
    if name.endswith(")") and " (" in name:
        name = name[: name.rindex(" (")]
    return name or "unknown"


def claude_records(dirs, cutoff):
    seen = {}
    sessions = {}
    for root in dirs:
        for path in glob.glob(os.path.join(root, "projects", "**", "*.jsonl"), recursive=True):
            try:
                if os.path.getmtime(path) < cutoff:
                    continue
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if '"usage"' not in line or '"assistant"' not in line:
                            continue
                        try:
                            obj = json.loads(line)
                        except ValueError:
                            continue
                        msg = obj.get("message")
                        if obj.get("type") != "assistant" or not isinstance(msg, dict):
                            continue
                        usage = msg.get("usage")
                        model = msg.get("model")
                        if not isinstance(usage, dict) or not model or model.startswith("<"):
                            continue
                        try:
                            ts = datetime.datetime.fromisoformat(obj["timestamp"].replace("Z", "+00:00")).timestamp()
                        except Exception:
                            continue
                        key = (msg.get("id") or "", obj.get("requestId") or "", path if not msg.get("id") else "")
                        seen[key] = (
                            ts,
                            model,
                            {
                                # Input is what the model read anew: prompt tokens not
                                # re-served from the prompt cache.
                                "input": int(usage.get("input_tokens") or 0) + int(usage.get("cache_creation_input_tokens") or 0),
                                "output": int(usage.get("output_tokens") or 0),
                                "messages": 1,
                            },
                            path,
                        )
            except OSError:
                continue
    for ts, model, rec, path in seen.values():
        yield ts, clean_model(model), rec, path


def varint(buf, i):
    result = shift = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if b < 0x80:
            return result, i
        shift += 7


def fields(buf):
    """Top-level protobuf fields as (number, wire, value); raises on garbage."""
    i, out = 0, []
    while i < len(buf):
        key, i = varint(buf, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            val, i = varint(buf, i)
        elif wire == 2:
            n, i = varint(buf, i)
            val = buf[i : i + n]
            i += n
        elif wire == 1:
            val = buf[i : i + 8]
            i += 8
        elif wire == 5:
            val = buf[i : i + 4]
            i += 4
        else:
            raise ValueError("wire")
        out.append((num, wire, val))
    return out


def first(parsed, num, wire):
    for n, w, v in parsed:
        if n == num and w == wire:
            return v
    return None


def agy_records(dirs, cutoff):
    seen = set()
    for root in dirs:
        for path in glob.glob(os.path.join(root, "*.db")):
            try:
                if os.path.getmtime(path) < cutoff:
                    continue
                db = sqlite3.connect("file:" + path + "?mode=ro", uri=True, timeout=2)
                names = {}
                for (blob,) in db.execute("select data from gen_metadata"):
                    try:
                        top = fields(blob)
                        inner = fields(first(top, 1, 2) or b"")
                        enum = first(inner, 3, 0)
                        label = first(inner, 21, 2)
                        if enum is not None and label:
                            names[enum] = label.decode("utf-8", "replace")
                    except Exception:
                        continue
                for (blob,) in db.execute("select metadata from steps where metadata is not null"):
                    try:
                        meta = fields(blob)
                        stamp = first(meta, 1, 2)
                        usage = first(meta, 9, 2)
                        if stamp is None or usage is None:
                            continue
                        ts = first(fields(stamp), 1, 0)
                        u = fields(usage)
                        enum = first(u, 1, 0)
                        prompt = first(u, 2, 0) or 0
                        out_tokens = first(u, 3, 0) or 0
                        cached = first(u, 5, 0) or 0
                        ident = first(u, 11, 2)
                        if ts is None or (not prompt and not out_tokens):
                            continue
                        if ident is not None:
                            if ident in seen:
                                continue
                            seen.add(ident)
                        rec = {
                            "input": max(prompt - cached, 0),
                            "output": out_tokens,
                            "messages": 1,
                        }
                        yield float(ts), clean_model(names.get(enum, "Gemini")), rec, path
                    except Exception:
                        continue
                db.close()
            except Exception:
                continue


def opencode_records(dirs, cutoff):
    """opencode keeps one row per assistant reply in <dir>/opencode.db."""
    for root in dirs:
        path = os.path.join(root, "opencode.db")
        try:
            if not os.path.exists(path):
                continue
            db = sqlite3.connect("file:" + path + "?mode=ro", uri=True, timeout=2)
            rows = db.execute(
                "select session_id, data from session_message where type = 'assistant' and time_created >= ?",
                (int(cutoff * 1000),),
            )
            for session_id, blob in rows:
                try:
                    obj = json.loads(blob)
                    tokens = obj.get("tokens")
                    if not isinstance(tokens, dict):
                        continue
                    stamp = obj.get("time") or {}
                    ms = stamp.get("completed") or stamp.get("created")
                    cache = tokens.get("cache") or {}
                    rec = {
                        # Input is what the model read anew (cache reads excluded);
                        # opencode counts reasoning apart from output, so add it back.
                        "input": int(tokens.get("input") or 0) + int(cache.get("write") or 0),
                        "output": int(tokens.get("output") or 0) + int(tokens.get("reasoning") or 0),
                        "messages": 1,
                    }
                    if not ms or (not rec["input"] and not rec["output"]):
                        continue
                    model = (obj.get("model") or {}).get("id")
                    yield ms / 1000.0, clean_model(model), rec, "opencode:" + str(session_id)
                except Exception:
                    continue
            db.close()
        except Exception:
            continue


def main():
    provider, start = sys.argv[1], int(sys.argv[2])
    dirs = [os.path.expanduser(d) for d in sys.argv[3:]]
    now = time.time()
    cutoff = now - MONTH - 86400
    source = {"claude": claude_records, "opencode": opencode_records}.get(provider, agy_records)

    local_today = datetime.datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0)
    today_start = local_today.timestamp()
    day_starts = [(local_today - datetime.timedelta(days=n)) for n in range(6, -1, -1)]

    periods = {name: blank() for name in ("session", "today", "week", "month")}
    models, days, sessions = {}, [blank() for _ in day_starts], set()
    last = 0
    if not start or start > now:
        start = now - 5 * 3600

    for ts, model, rec, path in source(dirs, cutoff):
        age = now - ts
        if age < 0 or age > MONTH:
            continue
        last = max(last, ts)
        add(periods["month"], rec)
        if ts >= now - WEEK:
            add(periods["week"], rec)
            sessions.add(path)
            slot = models.setdefault(model, blank())
            add(slot, rec)
        if ts >= today_start:
            add(periods["today"], rec)
        if ts >= start:
            add(periods["session"], rec)
        for idx, day in enumerate(day_starts):
            lo = day.timestamp()
            hi = day_starts[idx + 1].timestamp() if idx < 6 else now + 1
            if lo <= ts < hi:
                add(days[idx], rec)
                break

    for p in list(periods.values()) + list(models.values()) + days:
        p["total"] = p["input"] + p["output"]
    top = sorted(models.items(), key=lambda kv: kv[1]["total"], reverse=True)[:6]
    print(
        json.dumps(
            {
                "generatedAt": int(now),
                "sessionStart": int(start),
                "lastActivity": int(last),
                "periods": periods,
                "models": [dict(m, name=n) for n, m in top],
                "days": [dict(d, date=day_starts[i].strftime("%Y-%m-%d"), weekday=day_starts[i].strftime("%a")) for i, d in enumerate(days)],
                "sessions": len(sessions),
            },
            separators=(",", ":"),
        )
    )


main()
]==]
