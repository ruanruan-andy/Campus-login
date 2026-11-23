"""Run on the selected server via SSH; credentials arrive over stdin."""
import base64
import binascii
import http.client
import ipaddress
import json
import re
import socket
import subprocess
import sys
import time
import urllib.parse


PORTAL_HOST = "10.9.1.3"
PORTAL_PORT = 801
CHECK_HOST = "connectivitycheck.gstatic.com"
CHECK_PATH = "/generate_204"


def public_probe(scheme, host, path):
    # curl's deadline includes DNS resolution. No local proxy or curlrc.
    try:
        result = subprocess.run(
            ["curl", "--disable", "--noproxy", "*", "--silent", "--max-time", "3",
             "--write-out", "\n%{http_code}\n%{redirect_url}",
             f"{scheme}://{host}{path}"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=4,
        )
    except subprocess.TimeoutExpired:
        return 0, "", b""
    if result.returncode:
        return 0, "", b""
    body, status, redirect = result.stdout.rsplit(b"\n", 2)
    return int(status), redirect.decode("ascii", "replace"), body


def online():
    for host, path, status, marker in (
        (CHECK_HOST, CHECK_PATH, 204, b""),
        ("www.apple.com", "/library/test/success.html", 200, b"<TITLE>Success</TITLE>"),
    ):
        received, _, body = public_probe("https", host, path)
        if received == status and marker.lower() in body.lower():
            return True
    return False


def captive_redirect():
    for host, path in (
        (CHECK_HOST, CHECK_PATH),
        ("www.msftconnecttest.com", "/connecttest.txt"),
    ):
        status, location, _ = public_probe("http", host, path)
        if 300 <= status < 400 and location:
            return urllib.parse.urlsplit(location)
    return None


def gateway_failure(address):
    try:
        with socket.create_connection((PORTAL_HOST, PORTAL_PORT), timeout=3,
                                      source_address=(address, 0)):
            return None
    except TimeoutError:
        return "gateway_timeout"
    except OSError:
        return "gateway_unreachable"


def submit(fields, wifi_address=None):
    source = (wifi_address, 0) if wifi_address else None
    connection = http.client.HTTPConnection(
        PORTAL_HOST, PORTAL_PORT, timeout=4, source_address=source
    )
    try:
        connection.request("GET", "/eportal/?" + urllib.parse.urlencode(fields))
        response = connection.getresponse()
        return response.status, response.read(8192)
    finally:
        connection.close()


PORTAL_REASONS = {
    "1": "网关报告账号或密码不匹配。请核对学号、密码和所选运营商。",
    "2": "网关报告这台服务器的 IP 已在线，请检查外网连接。",
    "3": "校园网认证系统繁忙，请稍后重试。",
    "4": "校园网网关报告未知错误。",
    "5": "校园网接入设备发起认证失败。",
    "6": "校园网接入设备等待认证响应超时。",
    "7": "学校的 RADIUS 认证服务拒绝了登录。",
    "8": "学校的 RADIUS 认证服务响应超时。",
    "9": "校园网网关报告下线失败。",
    "10": "校园网网关报告下线超时。",
    "11": "校园网网关报告其他认证错误。",
}
MESSAGE_REASONS = (
    ("mac, ip, nasip, port err(6)!", "首次登录须在学校认证页面修改密码。"),
    ("首次登录", "网关要求在学校认证页面完成首次登录设置。"),
    ("欠费|余额不足", "网关报告校园网账号欠费或余额不足。"),
    ("停机|停用|禁用|冻结|锁定|suspended|locked", "网关报告校园网账号已停用或锁定。"),
    ("账号不存在|用户不存在|user not found", "网关报告找不到这个校园网账号。"),
    ("在线人数|超过.*上限|终端数|设备数|session limit", "网关报告已达到账号的在线设备或会话数量限制。"),
    ("验证码|captcha", "网关要求验证码，请在学校认证页面完成。"),
    ("密码错误|密码不对|invalid password", "网关报告校园网密码不正确。"),
    ("运营商.*(?:错误|不匹配)|服务类型.*(?:错误|不匹配)", "网关报告所选运营商或服务类型不匹配。"),
)


def rejection(response):
    code = str(response.get("ret_code", ""))
    if not re.fullmatch(r"[0-9]{1,3}", code):
        code = ""
    message = response.get("msg")
    if not isinstance(message, str):
        message = ""
    try:
        decoded = base64.b64decode(message, validate=True)
        message += " " + decoded.decode("gb18030", "replace")
    except (ValueError, binascii.Error):
        pass
    # Match known gateway messages and return fixed text. The raw message may contain account data.
    reason = next((text for pattern, text in MESSAGE_REASONS if re.search(pattern, message, re.I)), None)
    radius_code = re.search(r"\bauth error([0-9]{1,3})\b", message, re.I)
    reason = reason or PORTAL_REASONS.get(code) or "网关拒绝了登录，未提供可识别的原因。"
    if code:
        reason += f" 网关错误码 {code}。"
    if radius_code:
        reason += f" RADIUS 错误码 {radius_code[1]}。"
    return {"outcome": "authentication_failed", "detail": reason}


def authenticate(credentials, redirect):
    query = urllib.parse.parse_qs(redirect.query)
    address = query.get("wlanuserip", [""])[0]
    try:
        ipaddress.IPv4Address(address)
    except ValueError:
        return "portal_changed"

    suffix = credentials["suffix"]
    account = credentials["username"]
    if suffix and not account.endswith(suffix):
        account += suffix
    fields = {
        "c": "Portal", "a": "login", "callback": "campusLogin",
        "login_method": 1, "user_account": ",0," + account,
        "user_password": credentials["password"],
        "wlan_user_ip": address, "wlan_user_ipv6": "",
        "wlan_user_mac": "000000000000",
        "wlan_ac_ip": query.get("wlanacip", [""])[0],
        "wlan_ac_name": query.get("wlanacname", [""])[0],
        "jsVersion": "3.3.3",
    }
    # Use only the observed official portal. Never follow a credentialed redirect.
    status, body = submit(fields, credentials.get("wifiAddress"))
    if status != 200:
        return {"outcome": "portal_error", "detail": f"网关返回 HTTP {status}。"}
    callback = re.fullmatch(r"campusLogin\s*\((.*)\)\s*;?\s*", body.decode("gb18030", "replace").strip(), re.S)
    if not callback:
        return "portal_error"
    response = json.loads(callback.group(1))
    if not isinstance(response, dict):
        return "portal_error"
    if str(response.get("result")) not in ("1", "ok"):
        return rejection(response)
    for attempt in range(3):
        if attempt:
            time.sleep(1)
        if online():
            return "restored"
    return "accepted_offline"


def run(credentials):
    if online():
        return "online"
    redirect = captive_redirect()
    if redirect is not None and (
        redirect.scheme != "http" or redirect.netloc != PORTAL_HOST
        or redirect.path.lower() != "/a79.htm"
    ):
        return "portal_changed"
    wifi_address = credentials.get("wifiAddress")
    if wifi_address:
        failure = gateway_failure(wifi_address)
        if failure:
            return failure
        if redirect is not None:
            query = urllib.parse.parse_qs(redirect.query)
            if query.get("wlanuserip", [None])[0] != wifi_address:
                return "portal_changed"
    if redirect is None:
        return "offline"
    if not credentials["password"]:
        return "credentials_required"
    return authenticate(credentials, redirect)


if __name__ == "__main__":
    try:
        result = run(json.load(sys.stdin))
        report = {"outcome": result} if isinstance(result, str) else result
        print(json.dumps(report), flush=True)
    except (OSError, ValueError, TypeError, KeyError, http.client.HTTPException, subprocess.TimeoutExpired):
        print(json.dumps({"outcome": "portal_error"}), flush=True)
