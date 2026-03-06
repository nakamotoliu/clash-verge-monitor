#!/usr/bin/env python3
"""Simple 126.com SMTP sender for Clash health alerts."""
import base64
import os
import socket
import ssl
import sys
from pathlib import Path
from datetime import datetime

SMTP_SERVER = "smtp.126.com"
SMTP_PORT = 465
FROM_EMAIL = os.getenv("FROM_EMAIL", "")
PASS_FILE = Path(os.getenv("EMAIL_126_PASS_FILE", str(Path.home() / ".api_keys/email126.password")))


def load_password() -> str:
    if PASS_FILE.exists():
        lines = PASS_FILE.read_text(encoding="utf-8").splitlines()
        if len(lines) >= 2 and lines[1].strip():
            return lines[1].strip()
        if lines and lines[0].strip():
            return lines[0].strip()
    env = os.getenv("EMAIL_126_PASSWORD", "").strip()
    if env:
        return env
    raise RuntimeError(f"No 126 password found: {PASS_FILE}")


def expect(conn: ssl.SSLSocket, prefixes, step: str):
    resp = conn.recv(4096)
    if not any(resp.startswith(p) for p in prefixes):
        raise RuntimeError(f"SMTP {step} failed: {resp.decode(errors='ignore').strip()}")


def send_mail(to_email: str, subject: str, body: str):
    if not FROM_EMAIL:
        raise RuntimeError("FROM_EMAIL is required (e.g. edmjason@126.com)")
    if not to_email:
        raise RuntimeError("Recipient email is required")

    password = load_password()
    date_hdr = datetime.now().strftime("%a, %d %b %Y %H:%M:%S +0800")
    msg = (
        f"From: {FROM_EMAIL}\r\n"
        f"To: {to_email}\r\n"
        f"Subject: {subject}\r\n"
        f"Date: {date_hdr}\r\n"
        f"MIME-Version: 1.0\r\n"
        f"Content-Type: text/plain; charset=UTF-8\r\n"
        f"Content-Transfer-Encoding: 8bit\r\n"
        "\r\n"
        f"{body}\r\n"
    )

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    conn = ssl.create_default_context().wrap_socket(s, server_hostname=SMTP_SERVER)
    conn.settimeout(15)
    conn.connect((SMTP_SERVER, SMTP_PORT))

    expect(conn, (b"220",), "connect")
    conn.sendall(b"EHLO localhost\r\n")
    expect(conn, (b"250",), "EHLO")

    conn.sendall(b"AUTH LOGIN\r\n")
    expect(conn, (b"334",), "AUTH LOGIN")
    conn.sendall(base64.b64encode(FROM_EMAIL.encode()) + b"\r\n")
    expect(conn, (b"334",), "username")
    conn.sendall(base64.b64encode(password.encode()) + b"\r\n")
    expect(conn, (b"235",), "password")

    conn.sendall(f"MAIL FROM:<{FROM_EMAIL}>\r\n".encode())
    expect(conn, (b"250",), "MAIL FROM")

    conn.sendall(f"RCPT TO:<{to_email}>\r\n".encode())
    expect(conn, (b"250", b"251"), "RCPT TO")

    conn.sendall(b"DATA\r\n")
    expect(conn, (b"354",), "DATA")
    conn.sendall(msg.encode("utf-8") + b"\r\n.\r\n")
    expect(conn, (b"250",), "message body")

    conn.sendall(b"QUIT\r\n")
    conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: send_email_126.py <to> <subject> <body>")
        sys.exit(2)
    to, sub, body = sys.argv[1], sys.argv[2], sys.argv[3]
    send_mail(to, sub, body)
    print("OK")
