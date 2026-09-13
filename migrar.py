#!/usr/bin/env python3
"""Migra los datos exportados del artifact (carpeta migracion/) a Supabase.
Uso: python3 migrar.py URL_SUPABASE CLAVE_ANON [PIN_ADMIN_ACTUAL_EN_SUPABASE]
"""
import json, sys, os, urllib.request
if len(sys.argv) < 3: print(__doc__); sys.exit(1)
URL, KEY = sys.argv[1].rstrip('/'), sys.argv[2]
PIN = sys.argv[3] if len(sys.argv) > 3 else '1234'
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'migracion')

def rpc(fn, p):
    req = urllib.request.Request(f"{URL}/rest/v1/rpc/{fn}", data=json.dumps({"p": p}).encode(),
        headers={"Content-Type": "application/json", "apikey": KEY, "Authorization": "Bearer " + KEY})
    with urllib.request.urlopen(req, timeout=60) as r: j = json.load(r)
    if not j.get("ok"): raise SystemExit(f"{fn}: {j.get('error')} ({j.get('code')})")
    return j.get("data")

print("ping:", rpc("ping", {}))
config = json.load(open(os.path.join(D, "config", "main.json"), encoding="utf-8"))
config = config.get("data", config)
rpc("save_config", {"pin": PIN, "config": config})
PIN = config.get("pinAdmin") or PIN
print("config guardada · empleados:", ", ".join(e["nombre"] for e in config["empleados"] if e.get("nombre")))

def full(e):
    return {"src": e.get("src"), "in": e.get("in"), "out": e.get("out"), "min": e.get("min"), "fin": e.get("fin"), "fout": e.get("fout")}

total = 0
for f in sorted(os.listdir(os.path.join(D, "meses"))):
    doc = json.load(open(os.path.join(D, "meses", f), encoding="utf-8")); doc = doc.get("data", doc)
    changes = {}
    for fecha, emps in (doc.get("turnos") or {}).items():
        for emp, shifts in (emps or {}).items():
            for s, en in (shifts or {}).items():
                if en and isinstance(en, dict) and en.get("src"):
                    changes.setdefault(fecha, {}).setdefault(emp, {})[s] = full(en)
    n = rpc("set_turnos", {"pin": PIN, "changes": changes}) if changes else 0
    for emp, a in (doc.get("ajustes") or {}).items():
        rpc("set_ajuste", {"pin": PIN, "key": f[:-5], "emp": emp, "data": a})
    total += n; print(f"{f[:-5]}: {n} turnos")
print("listo ·", total, "turnos migrados")
