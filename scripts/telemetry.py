#!/usr/bin/env python3
"""
Telemetry collector for Omarchy Resources+ plugin.
Collects system performance metrics, hardware sensors, and top processes.
Supports summary mode (~1ms) and full dashboard mode (~10ms).
"""

import sys
import os
import glob
import json
import time
import subprocess

def get_cpu_info():
    model = "Unknown CPU"
    cores = 0
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("model name"):
                    model = line.split(":", 1)[1].strip()
                elif line.startswith("processor"):
                    cores += 1
    except Exception:
        pass

    # Read /proc/stat for overall and per-core
    cpu_overall = None
    cpu_cores = []
    try:
        with open("/proc/stat", "r") as f:
            for line in f:
                if line.startswith("cpu "):
                    parts = [int(x) for x in line.split()[1:]]
                    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                    total = sum(parts)
                    cpu_overall = {"idle": idle, "total": total}
                elif line.startswith("cpu") and line[3:4].isdigit():
                    parts = [int(x) for x in line.split()[1:]]
                    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                    total = sum(parts)
                    core_id = int(line.split()[0][3:])
                    cpu_cores.append({"id": core_id, "idle": idle, "total": total})
    except Exception:
        pass

    # CPU frequencies in MHz
    freqs = []
    for p in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"):
        try:
            with open(p, "r") as f:
                freqs.append(int(f.read().strip()) // 1000)
        except Exception:
            pass
    avg_freq = int(sum(freqs) / len(freqs)) if freqs else 0

    return {
        "model": model,
        "cores_count": cores or len(cpu_cores) or 1,
        "overall": cpu_overall or {"idle": 0, "total": 0},
        "cores": cpu_cores,
        "avg_freq_mhz": avg_freq,
        "freqs_mhz": freqs
    }

def get_memory_info():
    data = {}
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    parts = v.strip().split()
                    data[k] = int(parts[0]) # in kB
    except Exception:
        pass

    total = data.get("MemTotal", 1)
    avail = data.get("MemAvailable", 0)
    used = max(0, total - avail)
    swap_total = data.get("SwapTotal", 0)
    swap_free = data.get("SwapFree", 0)
    swap_used = max(0, swap_total - swap_free)

    return {
        "total_kb": total,
        "avail_kb": avail,
        "used_kb": used,
        "used_percent": round(100.0 * used / total, 1),
        "free_kb": data.get("MemFree", 0),
        "cached_kb": data.get("Cached", 0),
        "buffers_kb": data.get("Buffers", 0),
        "slab_kb": data.get("Slab", 0),
        "swap_total_kb": swap_total,
        "swap_used_kb": swap_used,
        "swap_percent": round(100.0 * swap_used / swap_total, 1) if swap_total > 0 else 0
    }

def get_gpu_info(force_fresh=False):
    cache_file = "/tmp/omarchy_gpu_cache.json"
    if not force_fresh and os.path.exists(cache_file):
        try:
            mtime = os.path.getmtime(cache_file)
            if (time.time() - mtime) < 10.0:
                with open(cache_file, "r") as cf:
                    return json.load(cf)
        except Exception:
            pass

    gpus = []

    # 1. NVIDIA
    try:
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=0.6
        )
        if res.returncode == 0 and res.stdout.strip():
            for line in res.stdout.strip().splitlines():
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 5:
                    gpus.append({
                        "vendor": "nvidia",
                        "name": parts[0],
                        "util_percent": int(parts[1]) if parts[1].isdigit() else 0,
                        "temp_c": int(parts[2]) if parts[2].isdigit() else 0,
                        "vram_used_mb": int(parts[3]) if parts[3].isdigit() else 0,
                        "vram_total_mb": int(parts[4]) if parts[4].isdigit() else 0,
                    })
    except Exception:
        pass

    # 2. AMD GPU (sysfs)
    for p in glob.glob("/sys/class/drm/card*/device/gpu_busy_percent"):
        try:
            with open(p, "r") as f:
                val = int(f.read().strip())
            # Find AMD temp
            amd_temp = 0
            for h in glob.glob("/sys/class/hwmon/hwmon*"):
                try:
                    with open(f"{h}/name", "r") as nf:
                        if "amdgpu" in nf.read():
                            with open(f"{h}/temp1_input", "r") as tf:
                                amd_temp = int(int(tf.read().strip()) / 1000)
                            break
                except Exception:
                    pass
            gpus.append({
                "vendor": "amd",
                "name": "AMD Radeon Graphics",
                "util_percent": val,
                "temp_c": amd_temp,
                "vram_used_mb": 0,
                "vram_total_mb": 0
            })
            break
        except Exception:
            pass

    # Active / Primary GPU summary
    active_gpu = gpus[0] if gpus else {"vendor": "none", "name": "None", "util_percent": 0, "temp_c": 0}
    # If multiple, prefer the one with highest util or discrete nvidia
    for g in gpus:
        if g["vendor"] == "nvidia" and g["util_percent"] > 0:
            active_gpu = g
            break
        elif g["util_percent"] > active_gpu["util_percent"]:
            active_gpu = g

    res = {
        "available": len(gpus) > 0,
        "primary": active_gpu,
        "list": gpus
    }
    try:
        with open(cache_file, "w") as cf:
            json.dump(res, cf)
    except Exception:
        pass
    return res

def get_disk_info():
    # Root filesystem statvfs
    st = os.statvfs("/")
    total_bytes = st.f_blocks * st.f_frsize
    free_bytes = st.f_bavail * st.f_frsize
    used_bytes = total_bytes - free_bytes
    used_pct = round(100.0 * used_bytes / total_bytes, 1) if total_bytes > 0 else 0

    # Disk I/O bytes from /proc/diskstats
    read_bytes = 0
    write_bytes = 0
    try:
        with open("/proc/diskstats", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 14:
                    dev = parts[2]
                    # Filter for actual disk devices (nvme0n1, sda, dm-0, etc.)
                    if dev.startswith(("sd", "nvme", "vd", "dm-")):
                        # parts[5] = sectors read, parts[9] = sectors written (sector=512B)
                        read_bytes += int(parts[5]) * 512
                        write_bytes += int(parts[9]) * 512
    except Exception:
        pass

    return {
        "root": {
            "total_bytes": total_bytes,
            "used_bytes": used_bytes,
            "free_bytes": free_bytes,
            "used_percent": used_pct
        },
        "io_read_bytes": read_bytes,
        "io_write_bytes": write_bytes
    }

def get_mounted_filesystems():
    mounts = []
    seen = set()
    try:
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3:
                    dev, path, fstype = parts[0], parts[1], parts[2]
                    if dev.startswith(("/dev/sd", "/dev/nvme", "/dev/mapper", "/dev/vd")):
                        if path in seen:
                            continue
                        seen.add(path)
                        try:
                            st = os.statvfs(path)
                            total = st.f_blocks * st.f_frsize
                            free = st.f_bavail * st.f_frsize
                            used = total - free
                            if total > 0:
                                mounts.append({
                                    "device": dev,
                                    "mount": path,
                                    "fstype": fstype,
                                    "total_bytes": total,
                                    "used_bytes": used,
                                    "free_bytes": free,
                                    "percent": round(100.0 * used / total, 1)
                                })
                        except Exception:
                            continue
    except Exception:
        pass
    return sorted(mounts, key=lambda x: x["mount"])

def get_network_info():
    rx_total = 0
    tx_total = 0
    interfaces = []
    try:
        with open("/proc/net/dev", "r") as f:
            for line in f:
                if ":" in line:
                    iface, rest = line.split(":", 1)
                    iface = iface.strip()
                    if iface == "lo":
                        continue
                    parts = rest.split()
                    if len(parts) >= 9:
                        rx = int(parts[0])
                        tx = int(parts[8])
                        rx_total += rx
                        tx_total += tx
                        if rx > 0 or tx > 0:
                            interfaces.append({"name": iface, "rx_bytes": rx, "tx_bytes": tx})
    except Exception:
        pass

    return {
        "rx_total_bytes": rx_total,
        "tx_total_bytes": tx_total,
        "interfaces": interfaces
    }

def get_sensors_info():
    temps = {}
    fans = {}
    for p in glob.glob("/sys/class/hwmon/hwmon*"):
        name = ""
        try:
            with open(f"{p}/name", "r") as f:
                name = f.read().strip()
        except Exception:
            pass

        # Temps
        for t in glob.glob(f"{p}/temp*_input"):
            try:
                base = os.path.basename(t)
                with open(t, "r") as f:
                    val = round(int(f.read().strip()) / 1000.0, 1)
                # Label
                label_path = t.replace("_input", "_label")
                lbl = ""
                if os.path.exists(label_path):
                    with open(label_path, "r") as lf:
                        lbl = lf.read().strip()
                temps[f"{name}_{lbl or base}"] = {"name": name, "label": lbl or base, "temp_c": val}
            except Exception:
                pass

        # Fans
        for fn in glob.glob(f"{p}/fan*_input"):
            try:
                base = os.path.basename(fn)
                with open(fn, "r") as f:
                    val = int(f.read().strip())
                fans[f"{name}_{base}"] = {"name": name, "label": base, "rpm": val}
            except Exception:
                pass

    # Find primary CPU temp
    cpu_temp = 0
    for k, v in temps.items():
        if "k10temp" in k or "coretemp" in k or "Tctl" in k or "Package" in k:
            cpu_temp = v["temp_c"]
            break
    if not cpu_temp and temps:
        # fallback to any acpitz or first temp
        for k, v in temps.items():
            if "acpi" in k:
                cpu_temp = v["temp_c"]
                break

    return {
        "cpu_temp_c": cpu_temp,
        "temps": list(temps.values()),
        "fans": list(fans.values())
    }

def get_system_overview():
    uname = os.uname()
    uptime_sec = 0
    try:
        with open("/proc/uptime", "r") as f:
            uptime_sec = int(float(f.read().split()[0]))
    except Exception:
        pass

    days = uptime_sec // 86400
    hours = (uptime_sec % 86400) // 3600
    minutes = (uptime_sec % 3600) // 60
    if days > 0:
        uptime_str = f"{days}d {hours}h {minutes}m"
    elif hours > 0:
        uptime_str = f"{hours}h {minutes}m"
    else:
        uptime_str = f"{minutes}m"

    return {
        "hostname": uname.nodename,
        "kernel": uname.release,
        "uptime_seconds": uptime_sec,
        "uptime_str": uptime_str
    }

def get_top_processes():
    # Hyprland window client PIDs
    window_pids = {}
    try:
        res = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=0.6)
        if res.returncode == 0:
            for c in json.loads(res.stdout):
                pid = c.get("pid")
                if pid:
                    window_pids[pid] = {
                        "title": c.get("title", ""),
                        "class": c.get("class", ""),
                        "initialClass": c.get("initialClass", "")
                    }
    except Exception:
        pass

    procs = []
    try:
        res = subprocess.run(["ps", "-eo", "pid,ppid,comm,%cpu,%mem,rss", "--sort=-%cpu"], capture_output=True, text=True, timeout=0.8)
        if res.returncode == 0:
            lines = res.stdout.strip().splitlines()
            for line in lines[1:45]: # top 45 by CPU
                parts = line.split(None, 5)
                if len(parts) >= 6:
                    try:
                        pid = int(parts[0])
                        ppid = int(parts[1])
                        comm = parts[2]
                        cpu_pct = float(parts[3])
                        mem_pct = float(parts[4])
                        rss_kb = int(parts[5])

                        is_win = pid in window_pids
                        win_info = window_pids.get(pid, {})

                        procs.append({
                            "pid": pid,
                            "ppid": ppid,
                            "name": win_info.get("initialClass") or comm,
                            "comm": comm,
                            "cpu_pct": cpu_pct,
                            "mem_pct": mem_pct,
                            "rss_kb": rss_kb,
                            "is_window": is_win,
                            "win_title": win_info.get("title", "")
                        })
                    except Exception:
                        continue
    except Exception:
        pass

    # Sort top by CPU and top by MEM
    by_cpu = sorted(procs, key=lambda x: x["cpu_pct"], reverse=True)[:15]
    by_mem = sorted(procs, key=lambda x: x["rss_kb"], reverse=True)[:15]

    return {
        "by_cpu": by_cpu,
        "by_mem": by_mem
    }

def main():
    mode = "summary"
    if len(sys.argv) > 1 and sys.argv[1] in ("--full", "full"):
        mode = "full"

    cpu = get_cpu_info()
    mem = get_memory_info()
    gpu = get_gpu_info(force_fresh=(mode == "full"))
    disk = get_disk_info()
    net = get_network_info()
    sensors = get_sensors_info()

    data = {
        "timestamp": time.time(),
        "mode": mode,
        "cpu": cpu,
        "mem": mem,
        "gpu": gpu,
        "disk": disk,
        "net": net,
        "sensors": sensors
    }

    if mode == "full":
        data["system"] = get_system_overview()
        data["mounts"] = get_mounted_filesystems()
        data["processes"] = get_top_processes()

    sys.stdout.write(json.dumps(data))
    sys.stdout.flush()

if __name__ == "__main__":
    main()
