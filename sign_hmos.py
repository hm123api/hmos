#!/usr/bin/env python3
"""HMOS Secure Boot signing / hashing / enrollment helper.

Pipeline (driven by build_hmos.bat):
  1. Compute BLAKE2B of the staged kernel -> append `#hash` to its limine.conf path.
  2. Compute BLAKE2B of the whole final limine.conf (on-disk bytes) and bake it
     into the Limine EFI via `limine enroll-config`.
  3. Authenticode-sign (DB key) the enrolled Limine BOOTX64.EFI and the HMOS.EFI.
  4. Export PK/KEK/DB as EFI signature lists (.esl) + DER certs for firmware enrolment.

Hash facts (verified against Limine 12.9.6 source common/lib/config.c and the
upstream checks/cases/host.py enrollment test):
  - config : blake2b over the WHOLE on-disk config file bytes. The loader loads
             f->size bytes into a buffer of f->size+2 and hashes config_size-2
             == f->size; upstream enroll test uses hashlib.blake2b(data) whole-file.
  - kernel : blake2b over the whole on-disk file bytes.
"""
import base64
import hashlib
import os
import re
import struct
import subprocess
import sys
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
KEYS = os.path.join(ROOT, "keys")
BUILD = os.path.join(ROOT, "build")
TOOLS = os.path.join(ROOT, "tools")
OSSIGN = os.path.join(TOOLS, "osslsigncode", "osslsigncode-2.16-windows-amd64",
                      "osslsigncode.exe")
LIMINE_TOOL = os.path.join(TOOLS, "efi", "limine", "limine-binary",
                           "limine-tool-windows-x86", "limine.exe")
OPENSSL = r"C:\Program Files\Git\usr\bin\openssl.exe"

# EFI GUIDs (UEFI 2.11), bytes_le handled via uuid.UUID.
CERT_X509 = "a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
# db variable GUID: EFI_IMAGE_SECURITY_DATABASE
IMAGE_SECURITY = "d719b2cb-3d3a-4596-a3bc-dad00e67656f"
# Signature owner GUID (placeholder; any GUID is allowed).
OWNER = "6106575a-aa8e-41ca-b306-52596bcf4244"


def b2b(data: bytes) -> str:
    return hashlib.blake2b(data, digest_size=64).hexdigest()


def pem_to_der(pem_path: str) -> bytes:
    txt = open(pem_path).read()
    body = re.search(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----",
                     txt, re.S).group(1)
    return base64.b64decode("".join(body.split()))


def write_esl(cert_pem: str, out_path: str) -> None:
    """EFI_SIGNATURE_LIST holding one X509 signature (UEFI 32.4.1)."""
    der = pem_to_der(cert_pem)
    entry = uuid.UUID(OWNER).bytes_le + der
    body = (uuid.UUID(CERT_X509).bytes_le
            + struct.pack("<III", 28 + len(entry), 0, len(entry))
            + entry)
    open(out_path, "wb").write(body)
    print(f"[esl] {os.path.basename(out_path)} ({len(body)} bytes)")


def sign_pe(inp: str, outp: str, key: str, crt: str) -> None:
    cmd = [OSSIGN, "sign", "-key", key, "-certs", crt, "-h", "sha256",
           "-in", inp, "-out", outp]
    r = subprocess.run(cmd, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        sys.exit(f"ERROR: osslsigncode failed on {inp}")
    print(f"[sign] {os.path.basename(inp)} -> {os.path.basename(outp)}")


def verify_pe(efi: str, crt: str) -> None:
    cmd = [OSSIGN, "verify", "-in", efi, "-CAfile", crt, "-ignore-timestamp"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = "Signature verification: ok" in r.stdout
    print(f"[verify] {os.path.basename(efi)}: {'OK' if ok else 'FAILED'}")
    if not ok:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(1)


def enroll_config(efi: str, cfg_hash: str) -> None:
    cmd = [LIMINE_TOOL, "enroll-config", "--quiet", efi, cfg_hash]
    r = subprocess.run(cmd, capture_output=True, text=True)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        sys.exit("ERROR: enroll-config failed")
    print(f"[enroll] config hash baked into {os.path.basename(efi)}")


def patch_kernel_hash(conf_path: str, kernel_path_in_conf: str, kernel_hash: str) -> None:
    """Replace the kernel path in limine.conf, appending '#<hash>'."""
    txt = open(conf_path, "r", newline="").read()
    lines = txt.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.strip().startswith("path:") and kernel_path_in_conf in line:
            base = line.split("path:", 1)[1].strip()
            base = base.split("#", 1)[0].strip()
            lines[i] = f"    path: {base}#{kernel_hash}\n"
            break
    else:
        sys.exit("ERROR: kernel path line not found in limine.conf")
    # Keep LF newlines (loader strips CR anyway; LF keeps hash stable).
    open(conf_path, "wb").write("".join(lines).replace("\r\n", "\n").encode())


def sign_stage(iso_root: str) -> None:
    """Run the Secure Boot stage against the staged ISO root.

    Order matters:
      kernel hash -> patch conf -> config hash -> enroll Limine EFI -> sign both EFI.
    """
    conf = os.path.join(iso_root, "limine.conf")
    kernel = os.path.join(iso_root, "boot", "hmoskernel")
    limine_efi = os.path.join(iso_root, "EFI", "BOOT", "BOOTX64.EFI")
    hmos_efi = os.path.join(iso_root, "EFI", "BOOT", "HMOS.EFI")
    db_key = os.path.join(KEYS, "db.key")
    db_crt = os.path.join(KEYS, "db.crt")

    # 1) Kernel hash (whole on-disk file), append to its conf path.
    kernel_hash = b2b(open(kernel, "rb").read())
    patch_kernel_hash(conf, "/boot/hmoskernel", kernel_hash)
    print(f"[hash] kernel  : {kernel_hash}")

    # 2) Config hash: whole on-disk file bytes (matches loader + upstream test).
    raw = open(conf, "rb").read()
    cfg_hash = b2b(raw)
    print(f"[hash] config  : {cfg_hash}")

    # 3) Bake config hash into the Limine EFI BEFORE signing it.
    enroll_config(limine_efi, cfg_hash)

    # 4) Authenticode-sign Limine EFI and HMOS app with the DB certificate.
    limine_tmp = os.path.join(BUILD, "BOOTX64.limine.signed.EFI")
    sign_pe(limine_efi, limine_tmp, db_key, db_crt)
    os.replace(limine_tmp, limine_efi)
    hmos_tmp = os.path.join(BUILD, "HMOS.signed.EFI")
    sign_pe(hmos_efi, hmos_tmp, db_key, db_crt)
    os.replace(hmos_tmp, hmos_efi)

    # 5) Verify.
    verify_pe(limine_efi, db_crt)
    verify_pe(hmos_efi, db_crt)


def _der_element(data, at):
    """(tag, content start, content end) of the DER element at offset `at`."""
    tag, length = data[at], data[at + 1]
    at += 2
    if length & 0x80:
        count = length & 0x7f
        length = int.from_bytes(data[at:at + count], "big")
        at += count
    return tag, at, at + length


def _der_not_before(der: bytes):
    """X.509 DER notBefore -> EFI_TIME tuple (matches Limine harness)."""
    def el(at):
        tag, length = der[at], der[at + 1]
        at += 2
        if length & 0x80:
            n = length & 0x7f
            length = int.from_bytes(der[at:at + n], "big")
            at += n
        return tag, at, at + length

    _, at, _ = el(0)
    _, at, _ = el(at)
    # version is optional tagged element; then skip serial, sigAlg, issuer.
    tag, _, end = el(at)
    if tag == 0xa0:
        at = end
    for _ in range(3):
        at = el(at)[2]
    _, at, _ = el(at)
    tag, start, end = el(at)
    text = der[start:end].decode()
    if tag == 0x17:  # UTCTime
        year = 2000 + int(text[:2]) if int(text[:2]) < 50 else 1900 + int(text[:2])
        text = text[2:]
    else:
        year = int(text[:4])
        text = text[4:]
    return (year, int(text[0:2]), int(text[2:4]), int(text[4:6]),
            int(text[6:8]), int(text[8:10]))


def _efi_time(y, m, d, hh=0, mm=0, ss=0):
    return struct.pack("<HBBBBBBIhBB", y, m, d, hh, mm, ss, 0, 0, 0, 0, 0)


def make_sb_vars(template: str, out_path: str, db_crt: str = None) -> None:
    """Copy a vars template and write PK/KEK/DB (ESL) + SecureBootEnable=1.

    Record layout mirrors the Limine test harness (PI variable store):
    28-byte record header, UTF-16 name, data, 4-byte aligned.

    If db_crt is given, use that certificate for the db ESL instead of the
    keys/db.crt (used to build a mismatch-vars control for testing).
    """
    import uuid as _uuid
    GLOBAL = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
    IMG_SEC = IMAGE_SECURITY
    NV_BS_RT = 7
    AUTHENTICATED = NV_BS_RT | 0x20
    NO_TIME = bytes(16)
    RECORD = struct.Struct("<HBBIQ16sIII16s")
    START = 0x55AA
    ADDED = 0x3f

    def utf16z(t):
        return (t + "\0").encode("utf-16-le")

    def record(name, guid, attr, timestamp, data):
        nm = utf16z(name)
        rec = (RECORD.pack(START, ADDED, 0, attr, 0, timestamp, 0,
                           len(nm), len(data), _uuid.UUID(guid).bytes_le)
               + nm + data)
        return rec + b"\xff" * (-len(rec) % 4)

    def cert_time(pem):
        der = pem_to_der(pem)
        return _efi_time(*_der_not_before(der)), der

    # Read existing template variables (keep built-in SB state: CustomMode,
    # certdb, VendorKeysNv, console, boot options ...) and merge on top.
    existing = {}
    tpl = bytearray(open(template, "rb").read())
    hdr_len = struct.unpack_from("<H", tpl, 48)[0]
    store_size = struct.unpack_from("<I", tpl, hdr_len + 16)[0]
    tstart = hdr_len + 28
    tend = hdr_len + store_size
    rp = tstart
    while rp + RECORD.size <= tend:
        st, state, _, attr, _, ts, _, ns, ds, guid = RECORD.unpack_from(tpl, rp)
        if st != START:
            break
        nm = bytes(tpl[rp + RECORD.size:rp + RECORD.size + ns]).decode(
            "utf-16-le", "ignore").rstrip("\0")
        data = bytes(tpl[rp + RECORD.size + ns:rp + RECORD.size + ns + ds])
        existing[(nm, str(_uuid.UUID(bytes_le=bytes(guid))))] = (attr, ts, data)
        rp = (rp + RECORD.size + ns + ds + 3) & ~3

    esl = {n: open(os.path.join(KEYS, f"{n}.esl"), "rb").read()
           for n in ("pk", "kek", "db")}
    times = {}
    for n in ("pk", "kek", "db"):
        times[n], _ = cert_time(os.path.join(KEYS, f"{n}.crt"))

    # Optional db override: build an ESL from an alternate cert (mismatch control).
    if db_crt:
        alt_der = pem_to_der(db_crt)
        alt_entry = uuid.UUID(OWNER).bytes_le + alt_der
        esl["db"] = (uuid.UUID(CERT_X509).bytes_le
                     + struct.pack("<III", 28 + len(alt_entry), 0, len(alt_entry))
                     + alt_entry)
        times["db"], _ = cert_time(db_crt)

    # dbx holds one hash, of nothing, which no image has (harness: empty-input
    # SHA256 = e3b0c442...b855). CustomMode=0, mirroring the harness.
    import hashlib as _hl
    SHA256_GUID = "c1c41626-504c-4092-aca9-41f936934328"
    DBX_OWNER = "a0baa8a3-041d-48a8-bc87-c36d121b5e3d"
    dbx_entry = _uuid.UUID(DBX_OWNER).bytes_le + _hl.sha256().digest()
    dbx_list = (_uuid.UUID(SHA256_GUID).bytes_le
                + struct.pack("<III", 28 + len(dbx_entry), 0, len(dbx_entry))
                + dbx_entry)
    dbx_time = _efi_time(2010, 1, 1)

    merged = dict(existing)
    merged[("PK", GLOBAL)] = (AUTHENTICATED, times["pk"], esl["pk"])
    merged[("KEK", GLOBAL)] = (AUTHENTICATED, times["kek"], esl["kek"])
    merged[("db", IMG_SEC)] = (AUTHENTICATED, times["db"], esl["db"])
    merged[("dbx", IMG_SEC)] = (AUTHENTICATED, dbx_time, dbx_list)
    merged[("SecureBootEnable", "f0a30bc7-af08-4556-99c4-001009c93a44")] = (
        3, NO_TIME, b"\x01")
    merged[("CustomMode", "c076ec0c-7028-4399-a072-71ee5c448b9f")] = (
        3, NO_TIME, b"\x00")

    records = b"".join(record(nm, g, attr, ts, data)
                       for (nm, g), (attr, ts, data) in sorted(merged.items()))
    if len(records) > tend - tstart:
        sys.exit("ERROR: SB variables do not fit vars template")
    tpl[tstart:tend] = records + b"\xff" * (tend - tstart - len(records))
    open(out_path, "wb").write(tpl)
    print(f"[vars] wrote {out_path} ({len(merged)} vars, {len(records)} bytes)")


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    os.makedirs(KEYS, exist_ok=True)

    if mode == "esl":
        for n in ("pk", "kek", "db"):
            pem = os.path.join(KEYS, f"{n}.crt")
            write_esl(pem, os.path.join(KEYS, f"{n}.esl"))
            # Also drop the DER cert next to it.
            der = pem_to_der(pem)
            open(os.path.join(KEYS, f"{n}.der"), "wb").write(der)
        return

    if mode == "hash-config":
        raw = open(sys.argv[2], "rb").read()
        print(b2b(raw))
        return

    if mode == "hash-file":
        print(b2b(open(sys.argv[2], "rb").read()))
        return

    if mode == "sign-stage":
        sign_stage(sys.argv[2])
        return

    if mode == "make-sb-vars":
        make_sb_vars(sys.argv[2], sys.argv[3])
        return

    if mode == "make-sb-vars-alt":
        make_sb_vars(sys.argv[2], sys.argv[3], db_crt=sys.argv[4])
        return

    sys.exit("unknown mode: " + mode)


if __name__ == "__main__":
    main()
