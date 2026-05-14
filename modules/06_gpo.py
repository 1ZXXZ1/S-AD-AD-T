#!/usr/bin/env python3
"""
Samba AD Toolkit — Unified GPO Manager
ALT Server 11.1 | Samba 4

Creates and manages Group Policy Objects:
  - USB Storage Restriction
  - Audit Logon/Logoff
  - Drive Maps
  - Folder Redirection
  - Apps Auto-Install

Usage:
  python3 06_gpo.py --config /path/to/config.cfg --gpo <gpo_name>
  gpo_name: usb | audit | drive-maps | folder-redir | apps-install | all
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

import ldb
from samba.auth import system_session
from samba.dcerpc import preg
from samba.dcerpc.misc import REG_DWORD, REG_EXPAND_SZ
from samba.ndr import ndr_pack
from samba.provision import create_gpo_struct, getpolicypath
from samba.samdb import SamDB
from samba.samba3 import param as s3param

REGISTRY_CSE_GUID = "{35378EAC-683F-11D2-A89A-00C04FBBCFA2}"


# ── Config parser ────────────────────────────────────────────
def load_config(path: str) -> dict[str, str]:
    cfg = load_config_via_bash(path)
    if cfg:
        return cfg

    return load_config_fallback(path)


def load_config_via_bash(path: str) -> dict[str, str]:
    """Read bash config exactly as the shell sees it, including multiline values."""
    try:
        proc = subprocess.run(
            [
                "bash",
                "-c",
                'set -a; source "$1"; env -0',
                "bash",
                path,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError):
        return {}

    cfg: dict[str, str] = {}
    for item in proc.stdout.split(b"\0"):
        if not item or b"=" not in item:
            continue
        key_b, val_b = item.split(b"=", 1)
        key = key_b.decode("utf-8", errors="surrogateescape")
        if not re.match(r"^[A-Z][A-Z0-9_]*$", key):
            continue
        cfg[key] = val_b.decode("utf-8", errors="surrogateescape")
    return cfg


def load_config_fallback(path: str) -> dict[str, str]:
    cfg: dict[str, str] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            # Skip comments after value
            if "#" in val:
                val = val[: val.index("#")].strip()
            cfg[key] = val
    return cfg


def derive_dn(domain: str) -> str:
    return "DC=" + ",DC=".join(domain.split("."))


# ── Database helpers ─────────────────────────────────────────
def load_db(cfg: dict[str, str]) -> SamDB:
    lp = s3param.get_context()
    lp.load(cfg.get("SMB_CONF", "/etc/samba/smb.conf"))
    return SamDB(
        url="/var/lib/samba/private/sam.ldb",
        session_info=system_session(),
        lp=lp,
    )


def ensure_child_container(db: SamDB, parent_dn: str, cn: str) -> None:
    child_dn = f"CN={cn},{parent_dn}"
    try:
        db.search(base=child_dn, scope=ldb.SCOPE_BASE, attrs=["cn"])
        return
    except ldb.LdbError:
        pass
    db.add({"dn": child_dn, "objectclass": "container", "cn": cn, "name": cn})


def get_template_sd(db: SamDB, domain_dn: str) -> bytes:
    template_dn = (
        f"CN={{31B2F340-016D-11D2-945F-00C04FB984F9}},"
        f"CN=Policies,CN=System,{domain_dn}"
    )
    return (
        db.search(base=template_dn, scope=ldb.SCOPE_BASE, attrs=["nTSecurityDescriptor"])[
            0
        ]["nTSecurityDescriptor"][0]
    )


# ── GPO CRUD ─────────────────────────────────────────────────
def ensure_gpo(
    db: SamDB,
    domain_dn: str,
    display_name: str,
    sysvol_root: Path,
    dns_domain: str,
) -> tuple[str, str]:
    """Return (gpo_guid, gpo_dn). Create if missing."""
    search_base = f"CN=Policies,CN=System,{domain_dn}"
    matches = db.search(
        base=search_base,
        scope=ldb.SCOPE_ONELEVEL,
        expression=f"(displayName={display_name})",
        attrs=["cn", "displayName", "gPCFileSysPath", "nTSecurityDescriptor"],
    )
    if matches:
        guid = str(matches[0]["cn"][0]).strip("{}")
        dn = str(matches[0].dn)
        return guid, dn

    sd_bytes = get_template_sd(db, domain_dn)
    gpo_guid = str(uuid.uuid4()).upper()
    gpo_dn = f"CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn}"
    gpo_path = getpolicypath(str(sysvol_root), dns_domain, gpo_guid)
    create_gpo_struct(gpo_path)

    db.add(
        {
            "dn": gpo_dn,
            "objectclass": ["top", "container", "groupPolicyContainer"],
            "cn": f"{{{gpo_guid}}}",
            "name": f"{{{gpo_guid}}}",
            "displayName": display_name,
            "gPCFileSysPath": f"\\\\{dns_domain}\\sysvol\\{dns_domain}\\Policies\\{{{gpo_guid}}}",
            "gPCFunctionalityVersion": "2",
            "flags": "0",
            "versionNumber": "1",
            "nTSecurityDescriptor": sd_bytes,
        }
    )
    ensure_child_container(db, gpo_dn, "Machine")
    ensure_child_container(db, gpo_dn, "User")
    return gpo_guid, gpo_dn


def link_to_root(db: SamDB, gpo_guid: str, domain_dn: str) -> None:
    gpo_link = f"[LDAP://CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn};0]"
    current = db.search(base=domain_dn, scope=ldb.SCOPE_BASE, attrs=["gPLink"])[0]
    existing = str(current["gPLink"][0]) if "gPLink" in current else ""
    if gpo_link not in existing:
        db.modify_ldif(
            f"dn: {domain_dn}\n"
            f"changetype: modify\n"
            f"replace: gPLink\n"
            f"gPLink: {existing}{gpo_link}\n-\n"
        )


def update_gpt_ini(
    gpo_path: Path,
    machine_version: int = 0,
    user_version: int = 0,
) -> None:
    """Write GPT.INI with correct version encoding.

    The Version field in GPT.INI encodes two counters:
        Version = (user_version << 16) | machine_version
    Windows clients use the upper 16 bits to decide whether to read
    the User/ subtree, and the lower 16 bits for the Machine/ subtree.
    If the corresponding half is zero, that half is skipped entirely.

    IMPORTANT: every time you change a policy file, bump the relevant
    version so clients detect the change on next gpupdate.
    """
    version = (user_version << 16) | machine_version
    p = gpo_path / "GPT.INI"
    p.write_text(f"[General]\r\nVersion={version}\r\n", encoding="utf-8")


def write_reg_pol(pol_path: Path, entries: list[preg.entry]) -> None:
    pol_path.parent.mkdir(parents=True, exist_ok=True)
    policy = preg.file()
    policy.entries = entries
    policy.num_entries = len(entries)
    pol_path.write_bytes(ndr_pack(policy))


# ── Individual GPO creators ──────────────────────────────────

def create_usb_gpo(cfg: dict[str, str]) -> None:
    db = load_db(cfg)
    domain_dn = derive_dn(cfg["DOMAIN"])
    sysvol = Path(cfg["SYSVOL_ROOT"])
    dns_domain = cfg["DOMAIN"]
    display = cfg.get("GPO_USB_RESTRICTION_DISPLAY", "USB Storage Restriction")
    ext_name = REGISTRY_CSE_GUID

    gpo_guid, _ = ensure_gpo(db, domain_dn, display, sysvol, dns_domain)
    gpo_path = Path(getpolicypath(str(sysvol), dns_domain, gpo_guid))

    entry = preg.entry()
    entry.keyname = r"Software\Policies\Microsoft\Windows\RemovableStorageDevices"
    entry.valuename = "Deny_All"
    entry.type = REG_DWORD
    entry.data = 1
    write_reg_pol(gpo_path / "Machine" / "Registry.pol", [entry])
    update_gpt_ini(gpo_path, machine_version=1)

    db.modify_ldif(
        f"dn: CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn}\n"
        f"changetype: modify\n"
        f"replace: gPCMachineExtensionNames\n"
        f"gPCMachineExtensionNames: [{ext_name}]\n-\n"
    )
    link_to_root(db, gpo_guid, domain_dn)

    print(f"[OK] USB GPO: {display} -> {{{gpo_guid}}}")


def create_audit_gpo(cfg: dict[str, str]) -> None:
    db = load_db(cfg)
    domain_dn = derive_dn(cfg["DOMAIN"])
    sysvol = Path(cfg["SYSVOL_ROOT"])
    dns_domain = cfg["DOMAIN"]
    display = cfg.get("GPO_AUDIT_DISPLAY", "Audit Logon Logoff")
    logon_val = cfg.get("GPO_AUDIT_LOGON_EVENTS", "3")
    sec_cse = (
        "{827D319E-6EAC-11D2-A4EA-00C04F79F83A}"
        "{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}"
    )

    gpo_guid, _ = ensure_gpo(db, domain_dn, display, sysvol, dns_domain)
    gpo_path = Path(getpolicypath(str(sysvol), dns_domain, gpo_guid))

    secedit_dir = gpo_path / "Machine" / "Microsoft" / "Windows NT" / "SecEdit"
    secedit_dir.mkdir(parents=True, exist_ok=True)
    tmpl = (
        "[Unicode]\r\n"
        "Unicode=yes\r\n"
        "[Version]\r\n"
        'signature="$CHICAGO$"\r\n'
        "Revision=1\r\n"
        "[Event Audit]\r\n"
        "AuditSystemEvents = 0\r\n"
        f"AuditLogonEvents = {logon_val}\r\n"
        "AuditObjectAccess = 0\r\n"
        "AuditPrivilegeUse = 0\r\n"
        "AuditPolicyChange = 0\r\n"
        "AuditAccountManage = 0\r\n"
        "AuditProcessTracking = 0\r\n"
        "AuditDSAccess = 0\r\n"
        "AuditAccountLogonEvents = 0\r\n"
    )
    (secedit_dir / "GptTmpl.inf").write_text(tmpl, encoding="utf-8")
    update_gpt_ini(gpo_path, machine_version=1)

    db.modify_ldif(
        f"dn: CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn}\n"
        f"changetype: modify\n"
        f"replace: gPCMachineExtensionNames\n"
        f"gPCMachineExtensionNames: [{sec_cse}]\n-\n"
    )
    link_to_root(db, gpo_guid, domain_dn)

    print(f"[OK] Audit GPO: {display} -> {{{gpo_guid}}}")


def create_drive_maps_gpo(cfg: dict[str, str]) -> None:
    db = load_db(cfg)
    domain_dn = derive_dn(cfg["DOMAIN"])
    sysvol = Path(cfg["SYSVOL_ROOT"])
    dns_domain = cfg["DOMAIN"]
    dc_host = cfg.get("FQDN", cfg.get("HOST_SHORTNAME", "") + "." + cfg["DOMAIN"])
    display = cfg.get("GPO_DRIVE_MAPS_DISPLAY", "Shared Folders Drive Maps")
    maps_cse = (
        "{5794DAFD-BE60-433f-88A2-1A31939AC1700F}"
        "{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}"
    )
    drives_cls = "{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}"
    item_cls = "{935D1B74-9CB8-4e3c-9914-7DD559B7A417}"

    gpo_guid, _ = ensure_gpo(db, domain_dn, display, sysvol, dns_domain)
    gpo_path = Path(getpolicypath(str(sysvol), dns_domain, gpo_guid))

    # Parse drive maps from config
    maps_raw = cfg.get("GPO_DRIVE_MAPS_LIST", "")
    root = ET.Element("Drives", {"clsid": drives_cls})
    for line in maps_raw.strip().splitlines():
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            continue
        letter, label, share_path = parts[0], parts[1], parts[2]
        unc = f"\\\\{dc_host}\\{share_path}"
        item = ET.Element(
            "Drive",
            {
                "clsid": item_cls,
                "name": f"{letter}:",
                "status": f"{letter}:",
                "image": "0",
                "changed": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
                "uid": f"{{{str(uuid.uuid4()).upper()}}}",
                "userContext": "1",
                "removePolicy": "1",
            },
        )
        ET.SubElement(
            item,
            "Properties",
            {
                "action": "U",
                "thisDrive": "NOCHANGE",
                "allDrives": "NOCHANGE",
                "userName": "",
                "path": unc,
                "label": label,
                "persistent": "1",
                "useLetter": "1",
                "letter": letter,
            },
        )
        root.append(item)

    drives_xml = gpo_path / "User" / "Preferences" / "Drives" / "Drives.xml"
    drives_xml.parent.mkdir(parents=True, exist_ok=True)
    xml_bytes = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    drives_xml.write_bytes(xml_bytes)
    # FIX: user-level policy — must set user_version > 0
    update_gpt_ini(gpo_path, user_version=1)

    db.modify_ldif(
        f"dn: CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn}\n"
        f"changetype: modify\n"
        f"replace: gPCUserExtensionNames\n"
        f"gPCUserExtensionNames: [{maps_cse}]\n-\n"
    )
    link_to_root(db, gpo_guid, domain_dn)

    print(f"[OK] Drive Maps GPO: {display} -> {{{gpo_guid}}}")


def create_folder_redir_gpo(cfg: dict[str, str]) -> None:
    db = load_db(cfg)
    domain_dn = derive_dn(cfg["DOMAIN"])
    sysvol = Path(cfg["SYSVOL_ROOT"])
    dns_domain = cfg["DOMAIN"]
    dc_host = cfg.get("FQDN", cfg.get("HOST_SHORTNAME", "") + "." + cfg["DOMAIN"])
    display = cfg.get("GPO_FOLDER_REDIR_DISPLAY", "Folder Redirection Policy")
    ext_name = REGISTRY_CSE_GUID
    redir_root = f"\\\\{dc_host}\\redirected\\%USERNAME%"

    gpo_guid, _ = ensure_gpo(db, domain_dn, display, sysvol, dns_domain)
    gpo_path = Path(getpolicypath(str(sysvol), dns_domain, gpo_guid))

    folders = {
        "Desktop": "Desktop",
        "Personal": "Documents",
        "{374DE290-123F-4565-9164-39C4925E467B}": "Downloads",
        "My Music": "Music",
        "My Pictures": "Pictures",
        "My Video": "Videos",
        "Public": "Public",
        "Templates": "Templates",
    }

    entries = []
    for valuename, folder in folders.items():
        e = preg.entry()
        e.keyname = r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        e.valuename = valuename
        e.type = REG_EXPAND_SZ
        e.data = f"{redir_root}\\{folder}"
        entries.append(e)

    write_reg_pol(gpo_path / "User" / "Registry.pol", entries)
    # FIX: user-level policy — must set user_version > 0
    update_gpt_ini(gpo_path, user_version=4)

    db.modify_ldif(
        f"dn: CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn}\n"
        f"changetype: modify\n"
        f"replace: gPCUserExtensionNames\n"
        f"gPCUserExtensionNames: [{ext_name}]\n-\n"
    )
    link_to_root(db, gpo_guid, domain_dn)

    print(f"[OK] Folder Redirection GPO: {display} -> {{{gpo_guid}}}")


def create_apps_install_gpo(cfg: dict[str, str]) -> None:
    db = load_db(cfg)
    domain_dn = derive_dn(cfg["DOMAIN"])
    sysvol = Path(cfg["SYSVOL_ROOT"])
    dns_domain = cfg["DOMAIN"]
    display = cfg.get("GPO_APPS_INSTALL_DISPLAY", "Apps Auto Install")
    scripts_cse = (
        "{42B5FAAE-6536-11D2-AE5A-0000F87571E3}"
        "{40B6664F-4972-11D1-A7CA-0000F87571E3}"
    )
    workstations_dn = f"OU=Workstations,{domain_dn}"

    gpo_guid, _ = ensure_gpo(db, domain_dn, display, sysvol, dns_domain)
    gpo_path = Path(getpolicypath(str(sysvol), dns_domain, gpo_guid))

    # Ensure OU exists
    try:
        db.search(base=workstations_dn, scope=ldb.SCOPE_BASE, attrs=["cn"])
    except ldb.LdbError:
        db.add({
            "dn": workstations_dn,
            "objectclass": "organizationalUnit",
            "ou": "Workstations",
        })

    # Write scripts.ini for startup
    startup_dir = gpo_path / "Machine" / "Scripts" / "Startup"
    startup_dir.mkdir(parents=True, exist_ok=True)
    startup_script = startup_dir / "install-apps.cmd"
    startup_script.write_text(
        "\r\n".join(
            [
                "@echo off",
                "setlocal EnableExtensions EnableDelayedExpansion",
                r"set LOG=%SystemRoot%\Temp\samba-ad-apps-install.log",
                r"set MARKER_DIR=%ProgramData%\SambaADToolkit\Apps",
                'if not exist "%MARKER_DIR%" mkdir "%MARKER_DIR%"',
                f'for %%I in ("\\\\{dns_domain}\\apps\\*.msi") do (',
                r"  set APP_MARKER=%MARKER_DIR%\%%~nI.installed",
                '  if not exist "!APP_MARKER!" (',
                '    echo Installing %%~nxI >> "%LOG%"',
                '    msiexec.exe /i "%%~fI" /qn /norestart >> "%LOG%" 2>&1',
                '    if not errorlevel 1 echo %%DATE%% %%TIME%% > "!APP_MARKER!"',
                "  )",
                ")",
                "exit /b 0",
                "",
            ]
        ),
        encoding="utf-8",
        newline="",
    )
    scripts_ini = gpo_path / "Machine" / "Scripts" / "scripts.ini"
    scripts_ini.parent.mkdir(parents=True, exist_ok=True)
    scripts_ini.write_text(
        "[Startup]\r\n0CmdLine=install-apps.cmd\r\n0Parameters=\r\n",
        encoding="utf-16",
    )
    update_gpt_ini(gpo_path, machine_version=1)

    db.modify_ldif(
        f"dn: CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn}\n"
        f"changetype: modify\n"
        f"replace: gPCMachineExtensionNames\n"
        f"gPCMachineExtensionNames: [{scripts_cse}]\n-\n"
    )

    # Link to Workstations OU
    gpo_link = f"[LDAP://CN={{{gpo_guid}}},CN=Policies,CN=System,{domain_dn};0]"
    current = db.search(base=workstations_dn, scope=ldb.SCOPE_BASE, attrs=["gPLink"])[0]
    existing = str(current["gPLink"][0]) if "gPLink" in current else ""
    if gpo_link not in existing:
        db.modify_ldif(
            f"dn: {workstations_dn}\n"
            f"changetype: modify\n"
            f"replace: gPLink\n"
            f"gPLink: {existing}{gpo_link}\n-\n"
        )

    link_to_root(db, gpo_guid, domain_dn)

    print(f"[OK] Apps Install GPO: {display} -> {{{gpo_guid}}}, linked to domain root and {workstations_dn}")


# ── Main ─────────────────────────────────────────────────────
GPO_HANDLERS = {
    "usb": create_usb_gpo,
    "audit": create_audit_gpo,
    "drive-maps": create_drive_maps_gpo,
    "folder-redir": create_folder_redir_gpo,
    "apps-install": create_apps_install_gpo,
}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Samba AD GPO Manager")
    parser.add_argument("--config", required=True, help="Path to config.cfg")
    parser.add_argument(
        "--gpo",
        required=True,
        choices=list(GPO_HANDLERS.keys()) + ["all"],
        help="Which GPO to create",
    )
    args = parser.parse_args(argv)

    cfg = load_config(args.config)

    if args.gpo == "all":
        for name, handler in GPO_HANDLERS.items():
            try:
                handler(cfg)
            except Exception as exc:
                print(f"[ERROR] {name}: {exc}", file=sys.stderr)
    else:
        GPO_HANDLERS[args.gpo](cfg)


if __name__ == "__main__":
    main()
