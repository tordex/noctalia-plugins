# Some code was taken from ps_mem.py, which is licensed under LGPLv2.
# Licence: LGPLv2
# Author:  P@draigBrady.com
# Source:  https://www.pixelbeat.org/scripts/ps_mem.py

import os
import sys
import errno
import io
import json
import time
import subprocess
import gi
import psutil
import draw_graph

gi.require_version('Gio', '2.0')
gi.require_version('GioUnix', '2.0')
gi.require_version('Gtk', '3.0')

from gi.repository import Gio, GioUnix
from gi.repository import Gtk

# The following exits cleanly on Ctrl-C or EPIPE
# while treating other exceptions as before.
def std_exceptions(etype, value, tb):
    sys.excepthook = sys.__excepthook__
    if issubclass(etype, KeyboardInterrupt) or issubclass(etype, IOError) and value.errno == errno.EPIPE:
        if os.path.exists("/dev/shm/noctalia_tordex_procs.json"):
            os.remove("/dev/shm/noctalia_tordex_procs.json")
        if os.path.exists("/dev/shm/noctalia_tordex_procs_cpu_usage.png"):
            os.remove("/dev/shm/noctalia_tordex_procs_cpu_usage.png")
        if os.path.exists("/dev/shm/noctalia_tordex_procs_mem_usage.png"):
            os.remove("/dev/shm/noctalia_tordex_procs_mem_usage.png")
    else:
        sys.__excepthook__(etype, value, tb)

sys.excepthook = std_exceptions

PAGESIZE = os.sysconf("SC_PAGE_SIZE") / 1024 #KiB
self_pid = os.getpid()


def get_icon_path(icon_name, size=24):
    theme = Gtk.IconTheme.get_default()
    icon_info = theme.lookup_icon(icon_name, size, Gtk.IconLookupFlags.USE_BUILTIN)
    if icon_info:
        return icon_info.get_filename()
    return None

def icon_path(icon_name, size=24):
    path = get_icon_path(icon_name, size)
    if path:
        return path

    parts = icon_name.split('-')
    if len(parts) > 1:
        # Try to find a more generic icon by removing the last part
        generic_icon_name = '-'.join(parts[:-1])
        path = get_icon_path(generic_icon_name, size)
        if path:
            return path
    if len(parts) > 2:
        # Try to find a more generic icon by removing the last two parts
        generic_icon_name = '-'.join(parts[:-2])
        path = get_icon_path(generic_icon_name, size)
        if path:
            return path

    # Fallback to a default icon if the specific icon is not found
    default_icon_name = "application-x-executable"  # You can change this to any default icon you prefer
    return get_icon_path(default_icon_name, size)  # Return None if no icon is found


class Unbuffered(io.TextIOBase):
   def __init__(self, stream):
       super().__init__()
       self.stream = stream
   def write(self, data):
       self.stream.write(data)
       self.stream.flush()
   def close(self):
       self.stream.close()

class Proc:
    def __init__(self):
        uname = os.uname()
        if uname[0] == "FreeBSD":
            self.proc = '/compat/linux/proc'
        else:
            self.proc = '/proc'

    def path(self, *args):
        return os.path.join(self.proc, *(str(a) for a in args))

    def open(self, *args):
        try:
            return open(self.path(*args), errors='ignore')
        except OSError:
            if type(args[0]) is not int:
                raise
            val = sys.exc_info()[1]
            if (val.errno == errno.ENOENT or # kernel thread or process gone
                val.errno == errno.EPERM or
                val.errno == errno.EACCES):
                raise LookupError
            raise

    def get_exe(self, pid):
        path = self.path(pid, 'exe')
        try:
            path = os.readlink(path)
            # Some symlink targets were seen to contain NULs on RHEL 5 at least
            path = path.split('\0')[0]
        except OSError:
            return None
        return path

    def get_cmdline(self, pid):
        try:
            with self.open(pid, 'cmdline') as f:
                cmdline = f.read().split("\0")
                while cmdline[-1] == '' and len(cmdline) > 1:
                    cmdline = cmdline[:-1]
                return cmdline
        except LookupError:
            return []

    def get_mem_stats(self, pid):
        have_swap_pss = False
        have_pss = False
        private_lines = []
        shared_lines = []
        pss_lines = []
        rss = (int(proc.open(pid, 'statm').readline().split()[1]) * PAGESIZE)
        swap_lines = []
        swap_pss_lines = []

        swap = 0

        try:
            if os.path.exists(proc.path(pid, 'smaps')):  # stat
                smaps = 'smaps'
                if os.path.exists(proc.path(pid, 'smaps_rollup')):
                    smaps = 'smaps_rollup' # faster to process
                lines = proc.open(pid, smaps).readlines()  # open
                for line in lines:
                    if line.startswith("Shared"):
                        shared_lines.append(line)
                    elif line.startswith("Private"):
                        private_lines.append(line)
                    elif line.startswith("Pss:"):
                        pss_lines.append(line)
                        have_pss = True
                    elif line.startswith("Swap:"):
                        swap_lines.append(line)
                    elif line.startswith("SwapPss:"):
                        have_swap_pss = True
                        swap_pss_lines.append(line)

                shared = sum([int(line.split()[1]) for line in shared_lines])
                private = sum([int(line.split()[1]) for line in private_lines])
                if have_pss:
                    pss_adjust = 0.5 # add 0.5KiB as this avg error due to truncation
                    pss = sum([float(line.split()[1])+pss_adjust for line in pss_lines])
                    shared = pss - private
                if have_swap_pss:
                    swap = sum([int(line.split()[1]) for line in swap_pss_lines])
                else:
                    swap = sum([int(line.split()[1]) for line in swap_lines])
            else:
                shared = int(proc.open(pid, 'statm').readline().split()[2])
                shared *= PAGESIZE
                private = rss - shared
                swap = 0

            return {
                "private": int(private * 1024),
                "shared": int(shared * 1024),
                "swap": int(swap * 1024),
            }
        except LookupError:
            return {
                "private": None,
                "shared": None,
                "swap": None,
            }

    def get_cpu_ticks(self, pid: int):
        """Reads the system's total CPU time and the specific process's ticks."""
        try:
            # 1. System time (the first line of /proc/stat: user, nice, system, idle, ...)
            with self.open("stat") as f:
                fields = f.readline().split()[1:]
                total_system_ticks = sum(int(x) for x in fields)

            # 2. Process time (the 14th and 15th fields in /proc/<pid>/stat: utime and stime)
            with self.open(pid, "stat") as f:
                stat_content = f.read()
                # The process name field (comm) may contain spaces and parentheses,
                # so parse everything strictly after the last closing parenthesis ')'
                post_comm = stat_content[stat_content.rfind(")") + 2 :].split()
                utime = int(post_comm[11])  # field 14 (index 11)
                stime = int(post_comm[12])  # field 15 (index 12)
                proc_ticks = utime + stime
                return {
                    "system_ticks": total_system_ticks,
                    "ticks": proc_ticks
                }
        except LookupError as e:
            return {
                "system_ticks": None,
                "ticks": None
            }


    def get_ppid(self, pid: int):
        """Reads the parent process ID (PPID) of the specific process."""
        try:
            with self.open(pid, "stat") as f:
                stat_content = f.read()
                # The process name field (comm) may contain spaces and parentheses,
                # so parse everything strictly after the last closing parenthesis ')'
                post_comm = stat_content[stat_content.rfind(")") + 2 :].split()
                return int(post_comm[1])  # field 4 (index 1)
        except LookupError as e:
            return None

    def get_io_bytes(self, pid: int):
        """Reads disk read and write bytes from /proc/<pid>/io."""
        try:
            read_b, write_b = 0, 0
            with self.open(pid, "io") as f:
                for line in f:
                    if line.startswith("read_bytes:"):
                        read_b = int(line.split()[1])
                    elif line.startswith("write_bytes:"):
                        write_b = int(line.split()[1])
            return {
                "read_b": read_b,
                "write_b": write_b
            }
        except LookupError:
            return {
                "read_b": None,
                "write_b": None
            }

    def get_cpu_times(self):
        try:
            with self.open("stat") as f:
                fields = [int(column) for column in f.readline().strip().split()[1:]]
            idle_time = fields[3] + fields[4]  # idle + iowait
            total_time = sum(fields)
            return idle_time, total_time
        except LookupError:
            return None, None

proc = Proc()

proc_disk_io = {}
proc_ticks = {}
num_cpus = os.cpu_count() or 1
cpu_idle_time = 0
cpu_total_time = 0

cpu_idle_time, cpu_total_time = proc.get_cpu_times()


def get_distro_info():
    distro_name = None
    distro_version = None
    pretty_name = None
    icon_path = None
    try:
        candidates = ["/etc/os-release", "/usr/lib/os-release"]
        for file_path in candidates:
            if os.path.exists(file_path):
                with open(file_path, "r") as f:
                    for line in f:
                        if line.startswith("NAME="):
                            distro_name = line.strip().split("=")[1].strip('"')
                        elif line.startswith("VERSION="):
                            distro_version = line.strip().split("=")[1].strip('"')
                        elif line.startswith("PRETTY_NAME="):
                            pretty_name = line.strip().split("=")[1].strip('"')
                        elif line.startswith("LOGO="):
                            icon_path = line.strip().split("=")[1].strip('"')
                break
    except FileNotFoundError:
        pass
    if icon_path is not None:
        icon_path = get_icon_path(icon_path, 100)

    if pretty_name is None and distro_name is not None:
        pretty_name = distro_name
        if distro_version is not None:
            pretty_name += f" {distro_version}"

    return {
        "distro_name": distro_name,
        "distro_version": distro_version,
        "pretty_name": pretty_name,
        "icon_path": icon_path
    }


def get_system_stats():
    global cpu_idle_time, cpu_total_time
    # CPU Load
    idle_time, total_time = proc.get_cpu_times()
    idle_delta = idle_time - cpu_idle_time
    total_delta = total_time - cpu_total_time

    if total_delta == 0:
        cpu_percent = 0.0
    else:
        cpu_percent = (1.0 - idle_delta / total_delta) * 100

    cpu_idle_time = idle_time
    cpu_total_time = total_time

    cpu_temp = "N/A"
    try:
        temps = psutil.sensors_temperatures()
        if temps:
            # Look for a CPU sensor among the available ones
            for name in ("coretemp", "k10temp", "cpu_thermal", "cpu-thermal"):
                if name in temps and temps[name]:
                    cpu_temp = f"{int(temps[name][0].current)}°"
                    break
            if cpu_temp == "N/A":
                first_entry = next(iter(temps.values()))[0]
                cpu_temp = f"{int(first_entry.current)}°"
    except (AttributeError, KeyError, IndexError):
        pass

    # Memory
    mem = psutil.virtual_memory()

    # Get system uptime
    try:
        with open("/proc/uptime", "r") as f:
            uptime_seconds = float(f.readline().split()[0])
    except (FileNotFoundError, ValueError):
        uptime_seconds = None

    # Get kernel version
    try:
        kernel_version = os.uname().release
    except AttributeError:
        kernel_version = None

    # Get CPU name
    cpu_name = None
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("model name"):
                    cpu_name = line.split(":", 1)[1].strip()
                    break
    except FileNotFoundError:
        pass

    # Get board name (if available)
    board_name = None
    try:
        with open("/sys/devices/virtual/dmi/id/board_name", "r") as f:
            board_name = f.readline().strip()
    except FileNotFoundError:
        pass

    # Get board vendor (if available)
    board_vendor = None
    try:
        with open("/sys/devices/virtual/dmi/id/board_vendor", "r") as f:
            board_vendor = f.readline().strip()
    except FileNotFoundError:
        pass

    board = f"{board_vendor} {board_name}" if board_vendor and board_name else None
    if board is None and board_name is not None:
        board = board_name

    return {
        "cpu_percent": cpu_percent,
        "cpu_temp": cpu_temp,
        "mem_percent": mem.percent,
        "mem_used": mem.used,
        "mem_free": mem.total - mem.used,
        "uptime": uptime_seconds,
        "kernel_version": kernel_version,
        "cpu_name": cpu_name,
        "board": board,
    }


def fetch_processes(interval: float):
    processes = {}
    for pid in os.listdir(proc.path("")):
        if not pid.isdigit():
            continue
        pid = int(pid)

        if pid == self_pid:
            continue

        exe = proc.get_exe(pid)
        cmdline = proc.get_cmdline(pid)
        if exe is None or cmdline is None:
            continue

        cpu_ticks = proc.get_cpu_ticks(pid)
        if cpu_ticks["system_ticks"] is None or cpu_ticks["ticks"] is None:
            continue

        io_bytes = proc.get_io_bytes(pid)
        if io_bytes["read_b"] is None or io_bytes["write_b"] is None:
            continue

        ppid = proc.get_ppid(pid)
        if ppid is None:
            continue

        # Calculate CPU usage percentage based on the difference in ticks since the last measurement
        if pid in proc_ticks:
            prev_ticks = proc_ticks[pid]["ticks"]
            prev_system_ticks = proc_ticks[pid]["system_ticks"]
            delta_ticks = cpu_ticks["ticks"] - prev_ticks
            delta_system_ticks = cpu_ticks["system_ticks"] - prev_system_ticks
            if delta_system_ticks > 0:
                cpu_usage_percent = (delta_ticks / delta_system_ticks) * 100 #* num_cpus
            else:
                cpu_usage_percent = 0.0
        else:
            cpu_usage_percent = 0.0
        proc_ticks[pid] = {
            "ticks": cpu_ticks["ticks"],
            "system_ticks": cpu_ticks["system_ticks"]
        }

        if pid in proc_disk_io:
            prev_read_b = proc_disk_io[pid]["read_b"]
            prev_write_b = proc_disk_io[pid]["write_b"]
            delta_read_b = io_bytes["read_b"] - prev_read_b
            delta_write_b = io_bytes["write_b"] - prev_write_b
        else:
            delta_read_b = 0
            delta_write_b = 0
        proc_disk_io[pid] = {
            "read_b": io_bytes["read_b"],
            "write_b": io_bytes["write_b"]
        }

        proc_data = proc.get_mem_stats(pid)
        proc_data.update({
            "pid": pid,
            "ppid": ppid,
            "exe": exe,
            "name": os.path.basename(exe),
            "icon": icon_path(os.path.basename(exe), 24),
            "cmdline": cmdline,
            "mem": proc_data["private"] + proc_data["shared"],
            "cpu": round(cpu_usage_percent, 1),
            "io_read": int(delta_read_b / interval),
            "io_write": int(delta_write_b / interval)
        })
        processes[pid] = proc_data
    return processes

app_name_cache = {}

def get_app_name(app_id: str):
    if app_id in app_name_cache:
        return app_name_cache[app_id]

    desktop_file = f"{app_id}.desktop" if not app_id.endswith(".desktop") else app_id

    try:
        app_info = GioUnix.DesktopAppInfo.new(desktop_file)
    except TypeError:
        app_name_cache[app_id] = app_id
        return app_id

    if app_info:
        app_name_cache[app_id] = app_info.get_name()
        return app_name_cache[app_id]
    else:
        for app in Gio.AppInfo.get_all():
            if isinstance(app, GioUnix.DesktopAppInfo):
                wm_class = app.get_startup_wm_class()
                if wm_class and wm_class.lower() == app_id.lower():
                    app_name_cache[app_id] = app.get_name()
                    return app_name_cache[app_id]
    app_name_cache[app_id] = app_id
    return app_name_cache[app_id]


def fill_app_processes(pid: int, app_procs: dict, processes: dict):
    if pid in app_procs or pid not in processes:
        return

    app_procs[pid] = processes[pid]

    for proc_pid, proc_data in processes.items():
        if proc_data["ppid"] == pid:
            fill_app_processes(proc_pid, app_procs, processes)


def fetch_applications(processes: dict):
    p = subprocess.run(["niri", "msg", "--json", "windows"], capture_output=True)
    if p.returncode != 0:
        return []

    try:
        niri_windows = json.loads(p.stdout.decode())
    except json.JSONDecodeError:
        return []

    ret = {}
    for window in niri_windows:
        app_id = window.get("app_id") or window.get("title") or "Unknown"
        if app_id not in ret:
            ret[app_id] = {
                "name": get_app_name(app_id),
                "app_id": app_id,
                "icon": icon_path(app_id, 24),
                "processes": {}
            }
        fill_app_processes(window["pid"], ret[app_id]["processes"], processes)

    for _, app_data in ret.items():
        app_data["processes"] = list(app_data["processes"].values())

    return ret

def update_apps_metrics(apps: dict):
    for _, app_data in apps.items():
        total_mem = 0
        total_cpu = 0.0
        total_read_b_sec = 0
        total_write_b_sec = 0

        for proc_data in app_data["processes"]:
            total_mem += proc_data.get("mem", 0)
            total_cpu += proc_data.get("cpu", 0.0)
            total_read_b_sec += proc_data.get("io_read", 0)
            total_write_b_sec += proc_data.get("io_write", 0)

        app_data["mem"] = total_mem
        app_data["cpu"] = round(total_cpu, 1)
        app_data["io_read"] = total_read_b_sec
        app_data["io_write"] = total_write_b_sec

def main():
    interval = 1.0

    while True:
        processes = fetch_processes(interval)
        apps = fetch_applications(processes)
        update_apps_metrics(apps)
        output_data = {
            "processes": list(processes.values()),
            "applications": list(apps.values())
        }
        output_data["system_stats"] = get_system_stats()
        output_data["distro_info"] = get_distro_info()

        cpu_graph_path = f"/dev/shm/noctalia_tordex_procs_cpu_usage.png"
        mem_graph_path = f"/dev/shm/noctalia_tordex_procs_mem_usage.png"


        # Draw CPU Usage Graph
        cpu_temp = output_data["system_stats"]["cpu_temp"]
        ret = draw_graph.draw_graph(
            percent=output_data["system_stats"]["cpu_percent"],
            val_text=f"{int(output_data['system_stats']['cpu_percent'])}%",
            label_text="CPU",
            sub_text=f"{cpu_temp}",
            filename=cpu_graph_path)
        if not ret:
            cpu_graph_path = None

        ret = draw_graph.draw_graph(
            percent=output_data["system_stats"]["mem_percent"],
            val_text=f"{round(output_data['system_stats']['mem_used'] / (1024 * 1024 * 1024), 1)}G",
            label_text="Memory",
            sub_text=f"+{round(output_data['system_stats']['mem_free'] / (1024 * 1024 * 1024), 1)}G",
            filename=mem_graph_path
        )
        if not ret:
            mem_graph_path = None

        if cpu_graph_path is not None:
            output_data["system_stats"]["cpu_graph_path"] = cpu_graph_path
        if mem_graph_path is not None:
            output_data["system_stats"]["mem_graph_path"] = mem_graph_path

        filename = "/dev/shm/noctalia_tordex_procs.json"
        try:
            with open(filename, "w") as f:
                json.dump(output_data, f, sort_keys=True)
            print(f"tordex/procs:ready:{filename}", flush=True)
        except FileNotFoundError as e:
            print(f"tordex/procs:error:Failed to write JSON file: {e}", flush=True)

        processes = []
        time.sleep(interval)

if __name__ == '__main__':
    #sys.stdout = Unbuffered(sys.stdout)
    #sys.stderr = Unbuffered(sys.stderr)

    print(f"tordex/procs:pid:{self_pid}")
    main()
