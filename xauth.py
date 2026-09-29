#!/usr/bin/env python3
"""Sign in with the user's own Microsoft account and cache Xbox tokens.

The browser login uses this game's Microsoft app id. Tokens are written
for the local runtime; they are never printed.
"""
import base64
import hashlib
import json
import os
import secrets
import struct
import subprocess
import sys
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request

CLIENT = "00000000497C1B94"
SCOPE = "service::user.auth.xboxlive.com::MBI_SSL"
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN_PATH = os.path.join(HERE, "tokens.txt")
CODE_PATH = os.path.join(HERE, "login-code.txt")


def post(url, form=None, payload=None, signed=False):
    if payload is not None:
        data = json.dumps(payload).encode()
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if signed:
            headers["x-xbl-contract-version"] = "1"
            headers["Signature"] = xbl_signature("/" + url.split("/", 3)[3], data)
    else:
        data = urllib.parse.urlencode(form).encode()
        headers = {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"error": body[:300]}
        parsed["_status"] = exc.code
        return parsed


def jwt_exp(token):
    try:
        if ";" in token:
            token = token.rsplit(";", 1)[1]
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        data = json.loads(base64.urlsafe_b64decode(part))
        return int(data.get("exp", 0))
    except Exception:
        return 0


def repair_stored_exp():
    if not os.path.isfile(TOKEN_PATH):
        return
    lines = []
    values = {}
    with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
        for line in handle:
            lines.append(line.rstrip("\n"))
            if "=" in line:
                key, value = line.rstrip("\n").split("=", 1)
                values[key] = value
    if int(values.get("exp") or "0") > time.time() + 120:
        return
    exp = 0
    for key in ("xbox", "mc"):
        got = jwt_exp(values.get(key, ""))
        if got:
            exp = min(exp, got) if exp else got
    if not exp:
        return
    replaced = False
    for i, line in enumerate(lines):
        if line.startswith("exp="):
            lines[i] = "exp=%s" % exp
            replaced = True
    if not replaced:
        lines.insert(0, "exp=%s" % exp)
    write_tokens([(line.split("=", 1)[0], line.split("=", 1)[1] if "=" in line else "") for line in lines])


def cached_ok():
    if not os.path.isfile(TOKEN_PATH):
        return False
    exp = 0
    has_playfab = False
    with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("exp="):
                exp = int(line[4:].strip() or "0")
            elif line.startswith("playfab="):
                has_playfab = True
    return has_playfab and exp > time.time() + 120


def rps_ticket(access):
    if access.startswith("t=") or access.startswith("d="):
        return access
    if access.startswith("eyJ"):
        return "d=" + access
    return "t=" + access


def xbox_user(access):
    result = post("https://user.auth.xboxlive.com/user/authenticate", payload={
        "Properties": {
            "AuthMethod": "RPS",
            "SiteName": "user.auth.xboxlive.com",
            "RpsTicket": rps_ticket(access),
        },
        "RelyingParty": "http://auth.xboxlive.com",
        "TokenType": "JWT",
    })
    if "Token" not in result:
        raise SystemExit("Xbox user auth failed: %s" % result.get("XErr", result.get("error")))
    return result["Token"]


EC_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
EC_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
EC_G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
        0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)
PROOF_KEY = secrets.randbelow(EC_N - 1) + 1


def ec_add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0] and (p[1] + q[1]) % EC_P == 0:
        return None
    if p == q:
        slope = (3 * p[0] * p[0] - 3) * pow(2 * p[1], -1, EC_P) % EC_P
    else:
        slope = (q[1] - p[1]) * pow(q[0] - p[0], -1, EC_P) % EC_P
    x = (slope * slope - p[0] - q[0]) % EC_P
    return x, (slope * (p[0] - x) - p[1]) % EC_P


def ec_mul(k, point):
    out = None
    while k:
        if k & 1:
            out = ec_add(out, point)
        point = ec_add(point, point)
        k >>= 1
    return out


def ec_sign(digest):
    z = int.from_bytes(digest, "big")
    while True:
        k = secrets.randbelow(EC_N - 1) + 1
        r = ec_mul(k, EC_G)[0] % EC_N
        s = pow(k, -1, EC_N) * (z + r * PROOF_KEY) % EC_N
        if r and s:
            return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def xbl_signature(path, body):
    filetime = (int(time.time()) + 11644473600) * 10000000
    version, stamp = struct.pack(">I", 1), struct.pack(">Q", filetime)
    signed = version + b"\0" + stamp + b"\0" + b"POST\0" + path.encode() + b"\0\0" + body + b"\0"
    return base64.b64encode(version + stamp + ec_sign(hashlib.sha256(signed).digest())).decode()


def device_token():
    def b64url(n):
        return base64.urlsafe_b64encode(n.to_bytes(32, "big")).rstrip(b"=").decode()
    x, y = ec_mul(PROOF_KEY, EC_G)
    result = post("https://device.auth.xboxlive.com/device/authenticate", payload={
        "Properties": {
            "AuthMethod": "ProofOfPossession",
            "Id": "{%s}" % uuid.uuid4(),
            "DeviceType": "Win32",
            "Version": "10.0.19045",
            "ProofKey": {"kty": "EC", "x": b64url(x), "y": b64url(y), "crv": "P-256", "alg": "ES256", "use": "sig"},
        },
        "RelyingParty": "http://auth.xboxlive.com",
        "TokenType": "JWT",
    }, signed=True)
    if "Token" not in result:
        return None, result.get("XErr", result.get("error", result.get("_status")))
    return result["Token"], None


def xsts(user_token, relying, device=None):
    props = {"SandboxId": "RETAIL", "UserTokens": [user_token]}
    if device:
        props["DeviceToken"] = device
    result = post("https://xsts.auth.xboxlive.com/xsts/authorize", payload={
        "Properties": props,
        "RelyingParty": relying,
        "TokenType": "JWT",
    }, signed=bool(device))
    if "Token" not in result:
        return None, result.get("XErr", result.get("error"))
    return result, None


def auth_header(doc):
    claim = doc["DisplayClaims"]["xui"][0]
    return "XBL3.0 x=%s;%s" % (claim["uhs"], doc["Token"]), claim


def write_tokens(fields):
    tmp = TOKEN_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        for key, value in fields:
            handle.write("%s=%s\n" % (key, value))
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_PATH)


def desktop_env():
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")
    env.setdefault("XDG_RUNTIME_DIR", "/run/user/%s" % os.getuid())
    return env


def open_browser(url, env):
    opener = ["open", url] if sys.platform == "darwin" else ["xdg-open", url]
    try:
        subprocess.Popen(opener, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def show_code(url, code):
    with open(CODE_PATH, "w", encoding="utf-8") as handle:
        handle.write(url + "\n" + code + "\n")
    env = desktop_env()
    open_browser(url, env)
    text = "Sign in with your Microsoft account.\n\nOpen %s\nCode: %s" % (url, code)
    if os.path.exists("/usr/bin/zenity"):
        subprocess.Popen(
            ["zenity", "--info", "--title=Minecraft Dungeons II sign-in", "--text", text, "--width=420"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def poll_msa(device_code, interval, expires_in):
    deadline = time.time() + max(30, expires_in - 5)
    while time.time() < deadline:
        time.sleep(max(int(interval), 5))
        result = post("https://login.live.com/oauth20_token.srf", form={
            "client_id": CLIENT,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": device_code,
        })
        if "access_token" in result:
            return result
        err = result.get("error", "")
        if err == "slow_down":
            interval = int(interval) + 5
            continue
        if err == "authorization_pending":
            continue
        raise SystemExit("Microsoft login failed: %s" % (result.get("error_description") or err or result.get("_status")))
    raise SystemExit("Microsoft login timed out")


def refresh_msa(refresh):
    result = post("https://login.live.com/oauth20_token.srf", form={
        "client_id": CLIENT,
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "scope": SCOPE,
    })
    if "access_token" not in result:
        return None
    return result


def load_refresh():
    if not os.path.isfile(TOKEN_PATH):
        return None
    with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("refresh="):
                return line[len("refresh="):].rstrip("\n")
    return None


def finish(msa):
    user_token = xbox_user(msa["access_token"])
    xbox, xerr = xsts(user_token, "http://xboxlive.com")
    if not xbox:
        raise SystemExit("Xbox token failed: %s" % xerr)
    minecraft, mc_err = xsts(user_token, "rp://api.minecraftservices.com/")
    device, pf_err = device_token()
    playfab = None
    if device:
        playfab, pf_err = xsts(user_token, "http://playfab.xboxlive.com/", device)
    header, claim = auth_header(xbox)
    mc_header = auth_header(minecraft)[0] if minecraft else header
    exp = jwt_exp(xbox["Token"])
    for extra in (minecraft, playfab):
        extra_exp = jwt_exp(extra["Token"]) if extra else 0
        if extra_exp:
            exp = min(exp, extra_exp) if exp else extra_exp
    if not exp:
        exp = int(time.time()) + 4 * 3600
    write_tokens([
        ("exp", str(exp)),
        ("xuid", claim.get("xid", "0")),
        ("uhs", claim.get("uhs", "")),
        ("gamertag", claim.get("gtg", "Player")),
        ("xbox", header),
        ("mc", mc_header),
        ("playfab", auth_header(playfab)[0] if playfab else ""),
        ("msa", msa["access_token"]),
        ("refresh", msa.get("refresh_token", "")),
        ("mc_error", "" if minecraft else str(mc_err or "")),
        ("playfab_error", "" if playfab else str(pf_err or "")),
    ])


def main():
    repair_stored_exp()
    if cached_ok():
        return
    refresh = load_refresh()
    if refresh:
        refreshed = refresh_msa(refresh)
        if refreshed:
            finish(refreshed)
            return
    started = post("https://login.live.com/oauth20_connect.srf", form={
        "client_id": CLIENT,
        "scope": SCOPE,
        "response_type": "device_code",
    })
    if "device_code" not in started:
        raise SystemExit("Could not start Microsoft login: %s" % started.get("error"))
    show_code(started.get("verification_uri") or "https://www.microsoft.com/link", started["user_code"])
    finish(poll_msa(started["device_code"], started.get("interval", 5), started.get("expires_in", 900)))


if __name__ == "__main__":
    try:
        main()
    except SystemExit as exc:
        if exc.code not in (0, None):
            with open(os.path.join(HERE, "login-error.txt"), "w", encoding="utf-8") as handle:
                handle.write(str(exc.code or exc)[:400])
        raise
