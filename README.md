# 🕒 Su Scheduler 🚀

> **A Modern Automation Powerhouse for Android** ⚡📱

![Status](https://img.shields.io/badge/Status-Stable-brightgreen.svg?style=for-the-badge) ![Root](https://img.shields.io/badge/Root-REQUIRED-red.svg?style=for-the-badge) ![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge) ![Version](https://img.shields.io/badge/Version-1.6.9-blue.svg?style=for-the-badge)

---

## 🌟 Overview

**Su Scheduler** is a premium, systemless automation tool for Android power users. It allows you to schedule scripts and commands with precision, offering advanced features like process isolation, interactive shells, and native Termux integration.

**📍 Configuration File:** `/sdcard/Documents/su-scheduler/config.txt`
**📂 Data Directory:** `/data/adb/su-scheduler/`

---

## 📋 Requirements

- **Root Access**: Magisk, KernelSU, or APatch.
- **BusyBox**: Recommended for full shell command compatibility.
- **Termux**: Required only if using the `: --termux` modifier.

---

## 💎 Key Features

-   **Systemless Design**: Fully compatible with Magisk/KernelSU modules ecosystem.
-   **Advanced Scheduling**:
    -   **Boot**: Run on device startup (`boot`).
    -   **Time**: Minute-precision daily schedules (`HH:MM`).
    -   **Weekly/Monthly/Yearly**: Complex recurring schedules.
-   **Process Isolation**: Every task runs in its own isolated process.
-   **Interactive Shells**: Persistent shell sessions you can attach to live 🎮.
-   **Termux Integration**: Native execution within the Termux environment 🐧.
-   **Smart Execution**: Automatically fixes script permissions and handles interpreters.
-   **Hot Reload**: Edit config and changes apply instantly.
-   **Notifications**: Integrated Android notifications for task status.

### 📅 Advanced Scheduling Formats

-   `weekly:DAY:HHMM` → Every week on specified day (1=Mon, 7=Sun)
    - Example: `weekly:1:0800` = Every Monday at 8 AM
-   `nweekly:N:DAY:HHMM` → Every N weeks on specified day
    - Example: `nweekly:2:5:1400` = Every 2 weeks on Friday at 2 PM
-   `monthly:DD:HHMM` → Every month on specified day
    - Example: `monthly:15:1200` = 15th of every month at noon
-   `nmonthly:N:DD:HHMM` → Every N months on specified day
    - Example: `nmonthly:3:01:0900` = Every 3 months on the 1st at 9 AM
-   `yearly:MM:DD:HHMM` → Once per year on specified date
    - Example: `yearly:01:01:0000` = New Year's Day at midnight

### 🧠 Intelligent Script Execution

When you schedule a script file (e.g., `/sdcard/myscript.sh`), Su Scheduler automatically:

1. **Detects** if the command is a script file
2. **Fixes permissions** with `chmod +x` if needed
3. **Attempts multiple execution methods** if direct execution fails:
   - Direct execution (`./script`)
   - Bash execution (`bash script`)
   - Shell execution (`sh script`)
   - Source execution (`. script`)

This means you can schedule scripts without worrying about execute permissions!

### 🎯 Advanced Modifiers

-   `: --run-once-now` → Execute immediately, then continue as a regular task. ⚡
-   `: --delete` → Run once and self-destruct. 💥
-   `: --boot` → Run on time AND on every boot. 👯‍♂️
-   `: --notify` → Notify on start & completion 📢
-   `: --notify-start` → Notify only when starting 🚀
-   `: --notify-end` → Notify only when complete ✅
-   `: --msg="text"` → Custom notification message 💬
-   `: --interactive` → Run in interactive shell mode 🎮
-   `: --termux` → Execute in Termux environment 🐧

---

## 🎮 Command Your Destiny

Use the `su-scheduler` command in your favorite terminal (Termux, etc.) to manage your tasks.

### 📋 Core Commands

| Command | Action |
| :--- | :--- |
| `add <trigger> <cmd>` | Add a new mission 📝 |
| `list [pattern]` | Show your scheduled tasks 🧐 |
| `remove <num\|pattern>` | Nuke a task 💥 |
| `edit [editor]` | Open the config in your editor 🎨 |
| `log [-f\|-n NUM]` | View logs (follow or last N lines) 🕵️ |
| `status` | Check the daemon pulse 💓 |
| `restart` | Restart the daemon 🔄 |
| `stop` | Stop the daemon 💀 |

### 🔧 Task Management

| Command | Action |
| :--- | :--- |
| `tasks` | List all running tasks 📋 |
| `task-info <id>` | Get detailed task information 🔍 |
| `task-output <id>` | View task output 📄 |
| `task-kill <id>` | Terminate a task 💀 |
| `chain [<chain-id>]` | Read-only DAG chain query: roots, runs, closure, catch-up headroom (P6-09) 🔗 |
| `run <cmd : mods>` | Execute command directly with modifiers 🔧 |
| `exec <cmd>` | Execute command directly 🔧 |

### 🎮 Interactive Shell

| Command | Action |
| :--- | :--- |
| `shell-attach <id>` | Attach to interactive shell 🎮 |
| `shell-send <id> <cmd>` | Send command to shell 📤 |

---

## 💖 Configuration

*File Location:* `/sdcard/Documents/su-scheduler/config.txt` 📂

You can edit this file directly or use `su-scheduler add/edit`.

```bash
# 🏁 Run on Boot
boot touch /sdcard/boot_success.txt

# 🌙 Night mode at 10 PM with notification
22:00 settings put system screen_brightness 10; : --notify-end

# ☀️ Morning routine with custom message
06:00 settings put system screen_brightness 255; : --boot --msg="Good Morning!"

# 💥 One-time reboot with notification
14:30 reboot; : --delete --notify

# 🎮 Interactive shell session
boot sh; : --interactive

# 📢 Notify on both start and completion
08:00 logcat -c; : --notify --msg="Clearing logs"

# 🧠 Smart script execution (auto-fixes permissions!)
14:30 /storage/emulated/0/myscript.sh; : --notify

# 📜 Multiline code block (heredoc syntax)
boot sh <<EOF; : --notify
echo "Starting backup"
cd /sdcard
tar -czf backup-$(date +%Y%m%d).tar.gz Documents/
echo "Backup complete"
EOF
```

---

## 🛠️ Installation

1.  Download the `su-scheduler-v1.0.0.zip`.
2.  Install via Magisk App, KernelSU App, or APatch.
3.  Reboot.
4.  Open terminal and type `su-scheduler` to start commanding!

### 🧷 Mounting & Mountify Compatibility

This module **delegates mounting entirely to the host mount system** — it
never opts out (no `skip_mount`), never bind-mounts, and never overlays
`/system/bin` itself. KernelSU / Magisk / APatch magic mount places the
module's `system/bin` files at `/system/bin` natively, and
[Mountify](https://github.com/backslashxx/mountify) — a metamodule — takes
over when installed, re-staging them as a fresh per-boot copy. Both mean
**module updates take effect on reboot, not live** (no live-edit). The
installer labels the binaries `u:object_r:system_file:s0` so the mounter
binds/copies them with the correct SELinux context (a raw unzip can leave a
stale `shell_data_file` label). If `/system/bin` is not yet mounted (e.g.
early boot), `service.sh` falls back to running the daemon straight from the
module directory. `su-schedulerd` logs a one-line **Runtime version drift**
warning when the mounted runtime and the module-directory copy differ, as a
"reboot to propagate" hint.

---

## 📖 Usage Examples

### Basic Scheduling
```bash
# Add a boot task
su-scheduler add boot "echo 'System booted' > /sdcard/boot.log"

# Schedule a time-based task
su-scheduler add 23:30 reboot

# Add with notification
su-scheduler add 08:00 "logcat -c; : --notify"

# Schedule a script (permissions auto-fixed!)
su-scheduler add 14:30 "/sdcard/backup.sh; : --notify-end"
```

### Smart Script Execution
```bash
# Even if dd has no execute permission, it will be fixed automatically!
su-scheduler add 14:30 "/storage/emulated/0/dd"

# The daemon will:
# 1. Detect it's a script file
# 2. Try chmod +x /storage/emulated/0/dd
# 3. Attempt direct execution
# 4. If that fails, try: bash /storage/emulated/0/dd
# 5. If that fails, try: sh /storage/emulated/0/dd
# 6. If that fails, try: . /storage/emulated/0/dd
```

### Task Management
```bash
# List all running tasks
su-scheduler tasks

# Get task details
su-scheduler task-info boot_1_1673634567

# View task output
su-scheduler task-output time_0800_1_1673634890

# Kill a task
su-scheduler task-kill boot_1_1673634567

# Query DAG chains (P6-09, read-only; managed mode; no daemon required)
su-scheduler chain                 # all chain roots + latest run state + RUNS_MAX headroom
su-scheduler chain backup_root     # one chain detail (accepts root OR member id)

# Production task status (P2-08+; shows chain_*/note/reason + catch-up lines for
# chain-related tasks; existing fields unchanged, new info appended)
su-scheduler task status backup_sync
```

### Direct Execution (with modifiers)
```bash
# Execute a command immediately with Termux bridge
su-scheduler run "pkg list-installed : --termux"

# Run with notification
su-scheduler run "echo 'Hello' : --notify"

# Plain execution (alias of run)
su-scheduler exec "pm list packages | grep google"
```

### 🧪 System Health Check
Verify your installation and configuration with the built-in test suite:
```bash
su-scheduler test
```
*This safely backs up your config, runs a suite of tests (Boot, Time, Termux, Multiline, etc.), and restores everything automatically.*

### 🎮 Interactive Shell Sessions

Interactive shells let you run persistent sessions and interact with them in real-time.

```bash
# 1. Start an interactive shell on boot (recommended)
su-scheduler add boot "sh; : --interactive"

# 2. Find your shell's task ID
su-scheduler tasks
# Output shows: Task ID: boot_1_1705167890

# 3. Connect to the shell (view live output)
su-scheduler shell-attach boot_1_1705167890
# Press Ctrl+C to detach (shell keeps running)

# 4. Send commands to the shell
su-scheduler shell-send boot_1_1705167890 "ls -la /sdcard"
su-scheduler shell-send boot_1_1705167890 "cd /data && pwd"

# 5. View shell output
su-scheduler task-output boot_1_1705167890

# Interactive shell in Termux environment
su-scheduler add boot "sh; : --interactive --termux"
```

**Why use interactive shells?**
- 🔍 Debug scripts in real-time
- 📊 Monitor long-running processes
- 🎯 Send commands on-demand
- 🔧 Test code interactively

**See [Interactive Shell Guide](#-interactive-shell-guide---su-scheduler) below for complete documentation.**

### Viewing Logs
```bash
# View last 20 log entries (colored)
su-scheduler log

# Follow logs in real-time
su-scheduler log -f

# View last 50 entries
su-scheduler log -n 50
```

### 🐧 Termux Environment Execution
```bash
# Run Python script in Termux environment
su-scheduler add 09:00 "python /sdcard/script.py; : --termux --notify"

# Use Termux packages (pkg, apt, etc.)
su-scheduler add boot "pkg update && pkg upgrade -y; : --termux"

# Execute Node.js script
su-scheduler add weekly:1:1000 "node /sdcard/backup.js; : --termux --notify-end"

# Use Termux utilities
su-scheduler add 08:00 "termux-battery-status > /sdcard/battery.log; : --termux"

# The --termux modifier:
# - Sets up full Termux environment (PATH, LD_LIBRARY_PATH, etc.)
# - Handles User 0 decryption automatically
# - Uses Termux's preferred shell (zsh/bash)
# - Enables access to all Termux packages and tools
```

### 📜 Multiline Code Blocks

Execute complex scripts using heredoc syntax (`<<EOF`):

```bash
# Edit your config file
su-scheduler edit

# Add multiline task
boot sh <<EOF; : --notify --msg="Backup Complete"
echo "Starting daily backup..."
cd /sdcard

# Create backup directory
mkdir -p Backups/$(date +%Y%m%d)

# Backup important files
tar -czf Backups/$(date +%Y%m%d)/documents.tar.gz Documents/
tar -czf Backups/$(date +%Y%m%d)/pictures.tar.gz DCIM/

# Clean old backups (older than 30 days)
find Backups/ -type f -mtime +30 -delete

echo "Backup complete!"
EOF

# Multiline with Termux
08:00 python <<EOF; : --termux --notify
import os
import datetime

print(f"Running at {datetime.datetime.now()}")
os.system("pkg update")
print("Update complete")
EOF

# Complex shell script
weekly:1:0900 sh <<EOF; : --notify
#!/system/bin/sh
# Weekly maintenance script

echo "=== Weekly Maintenance ==="
echo "Date: $(date)"

# Clear caches
echo "Clearing caches..."
find /sdcard -name ".cache" -type d -exec rm -rf {} + 2>/dev/null

# Update logs
echo "Rotating logs..."
logcat -c

# System info
echo "Disk usage:"
df -h | grep /sdcard

echo "=== Maintenance Complete ==="
EOF
```

**Benefits of multiline blocks:**
- ✅ Write complex scripts directly in config
- ✅ No need for separate script files
- ✅ Easy to edit and maintain
- ✅ Supports any language (sh, python, etc.)
- ✅ Works with all modifiers

---

## 🎨 Features Showcase

### 🔥 Hot Config Reload
Edit your config file and changes are detected instantly - no daemon restart needed!

### 📢 Smart Notifications
Get Android notifications when tasks start, complete, or fail. Customize messages for each task.

### 🎮 Interactive Shell Mode
Run persistent shell sessions and interact with them live - perfect for monitoring or debugging.

### 🌈 Beautiful Logging
All events are logged with timestamps and color coding for easy reading and debugging.

### 🔒 Process Isolation
Each task runs in its own isolated process with lockfiles - one task can't block another.

### 🧠 Intelligent Execution
Automatically detects scripts, fixes permissions, and tries multiple execution methods until one succeeds!

---

---
# 🎮 Interactive Shell Guide - Su Scheduler

## What is Interactive Mode?

Interactive mode allows you to run **persistent shell sessions** that stay alive and can be interacted with in real-time. This is perfect for:

- 🔍 **Debugging** - Watch commands execute live
- 📊 **Monitoring** - Keep long-running processes active
- 🎯 **Interactive Tasks** - Send commands on-demand
- 🔧 **Development** - Test scripts interactively

---

## Quick Start

### 1. Start an Interactive Shell

```bash
# Start on boot (recommended)
su-scheduler add boot "sh; : --interactive"

# Start at specific time
su-scheduler add 09:00 "sh; : --interactive"

# Start in Termux environment
su-scheduler add boot "sh; : --interactive --termux"
```

### 2. Find Your Shell's Task ID

```bash
su-scheduler tasks
```

Output:
```
📋 Active Tasks:
------------------------------------------------------------
Task ID: boot_1_1705167890
  Status: RUNNING | PID: 12345
  Command: sh

Task ID: boot_2_1705167891
  Status: RUNNING | PID: 12346
  Command: python server.py
------------------------------------------------------------
```

### 3. Connect to the Shell

```bash
# Attach to see live output
su-scheduler shell-attach boot_1_1705167890
```

**Press Ctrl+C to detach** (shell continues running)

### 4. Send Commands

```bash
# Send a single command
su-scheduler shell-send boot_1_1705167890 "ls -la /sdcard"

# Send multiple commands
su-scheduler shell-send boot_1_1705167890 "cd /sdcard && pwd"

# Run a script
su-scheduler shell-send boot_1_1705167890 "./backup.sh"
```

---

## Detailed Usage

### Starting Interactive Shells

#### Basic Shell
```bash
# System shell (sh)
su-scheduler add boot "sh; : --interactive"

# Bash shell
su-scheduler add boot "bash; : --interactive"
```

#### Termux Shell
```bash
# Termux environment (uses zsh/bash from Termux)
su-scheduler add boot "sh; : --interactive --termux"

# With notification
su-scheduler add boot "sh; : --interactive --termux --notify --msg='Termux Shell Ready'"
```

#### Scheduled Interactive Sessions
```bash
# Start at 9 AM daily
su-scheduler add 09:00 "sh; : --interactive"

# Weekly on Monday
su-scheduler add weekly:1:0900 "sh; : --interactive"
```

### Finding Active Shells

```bash
# List all running tasks
su-scheduler tasks

# Filter for interactive shells
su-scheduler tasks | grep "sh"

# Get detailed info
su-scheduler task-info boot_1_1705167890
```

Output:
```
🔍 Task Information: boot_1_1705167890
============================================================
Command: sh
Status: RUNNING
PID: 12345
Started: 2026-01-13 23:00:00
============================================================
```

### Connecting to Shells

#### Method 1: Attach (View Live Output)

```bash
su-scheduler shell-attach boot_1_1705167890
```

**What you'll see:**
- Real-time output from the shell
- All commands executed
- Any errors or messages

**To detach:**
- Press `Ctrl+C` (shell keeps running)

#### Method 2: Send Commands

```bash
# Basic command
su-scheduler shell-send boot_1_1705167890 "echo 'Hello World'"

# Change directory and list
su-scheduler shell-send boot_1_1705167890 "cd /sdcard && ls -la"

# Run a script
su-scheduler shell-send boot_1_1705167890 "/sdcard/backup.sh"

# Pipe commands
su-scheduler shell-send boot_1_1705167890 "ps -ef | grep su-scheduler"
```

### Viewing Shell Output

```bash
# View output file directly
su-scheduler task-output boot_1_1705167890

# Or use cat
cat /data/adb/su-scheduler/shells/boot_1_1705167890.out

# Follow output in real-time
tail -f /data/adb/su-scheduler/shells/boot_1_1705167890.out
```

---

## Advanced Examples

### Python Development Server

```bash
# Start Python server
su-scheduler add boot "python -m http.server 8000; : --interactive --termux"

# Send commands to it
su-scheduler shell-send <task_id> "print('Server running')"
```

### Node.js REPL

```bash
# Start Node REPL
su-scheduler add boot "node; : --interactive --termux"

# Send JavaScript
su-scheduler shell-send <task_id> "console.log('Hello from Node')"
su-scheduler shell-send <task_id> "process.version"
```

### Database Shell

```bash
# SQLite shell
su-scheduler add boot "sqlite3 /sdcard/mydb.db; : --interactive --termux"

# Send SQL queries
su-scheduler shell-send <task_id> "SELECT * FROM users;"
su-scheduler shell-send <task_id> ".tables"
```

### Monitoring Script

```bash
# Start monitoring
su-scheduler add boot "sh; : --interactive"

# Send monitoring commands
su-scheduler shell-send <task_id> "while true; do date; free -h; sleep 60; done"
```

### Git Operations

```bash
# Start in git repo
su-scheduler add boot "cd ~/projects && sh; : --interactive --termux"

# Send git commands
su-scheduler shell-send <task_id> "git status"
su-scheduler shell-send <task_id> "git pull"
su-scheduler shell-send <task_id> "git log -n 5"
```

---

## Multiline Code Blocks

You can execute multiline scripts using heredoc syntax:

### In Config File

```bash
# Edit config
su-scheduler edit

# Add multiline task
boot sh <<EOF; : --interactive
echo "Starting multi-line script"
cd /sdcard
for i in 1 2 3; do
    echo "Processing $i"
    sleep 1
done
echo "Complete"
EOF
```

### Via CLI (Alternative)

```bash
# Create a script file first
cat > /sdcard/multi.sh << 'SCRIPT'
#!/system/bin/sh
echo "Line 1"
echo "Line 2"
echo "Line 3"
SCRIPT

# Then schedule it
su-scheduler add boot "/sdcard/multi.sh; : --interactive"
```

---

## File Locations

### Shell I/O Files

```bash
# Input FIFO (send commands here)
/data/adb/su-scheduler/shells/<task_id>.in

# Output file (read output here)
/data/adb/su-scheduler/shells/<task_id>.out

# Example
echo "ls -la" > /data/adb/su-scheduler/shells/boot_1_1705167890.in
cat /data/adb/su-scheduler/shells/boot_1_1705167890.out
```

### Task Metadata

```bash
# Task directory
/data/adb/su-scheduler/tasks/<task_id>/

# Files:
- command.txt      # Original command
- pid.txt          # Process ID
- status.txt       # Current status
- start_time.txt   # When it started
- exec_mode.txt    # SYSTEM or TERMUX
```

---

## Common Workflows

### Workflow 1: Debug a Script

```bash
# 1. Start interactive shell
su-scheduler add boot "sh; : --interactive"

# 2. Get task ID
TASK_ID=$(su-scheduler tasks | grep "sh" | awk '{print $3}')

# 3. Send your script
su-scheduler shell-send $TASK_ID "/sdcard/debug-me.sh"

# 4. Watch output
su-scheduler shell-attach $TASK_ID
```

### Workflow 2: Remote Monitoring

```bash
# 1. Start monitoring shell on boot
su-scheduler add boot "sh; : --interactive --notify --msg='Monitor Ready'"

# 2. Later, check system status
su-scheduler shell-send <task_id> "top -n 1"
su-scheduler shell-send <task_id> "df -h"
su-scheduler shell-send <task_id> "free -h"

# 3. View results
su-scheduler task-output <task_id>
```

### Workflow 3: Scheduled Maintenance

```bash
# 1. Start shell at 3 AM
su-scheduler add 03:00 "sh; : --interactive"

# 2. Send maintenance commands
su-scheduler shell-send <task_id> "find /sdcard/Download -mtime +30 -delete"
su-scheduler shell-send <task_id> "logcat -c"
su-scheduler shell-send <task_id> "sync"

# 3. Check results in the morning
su-scheduler log
```

---

## Troubleshooting

### Shell Not Responding

**Check if it's running:**
```bash
su-scheduler tasks
su-scheduler task-info <task_id>
```

**Check the PID:**
```bash
ps -ef | grep <pid>
```

### Can't Connect

**Verify FIFO files exist:**
```bash
ls -la /data/adb/su-scheduler/shells/
```

**Check permissions:**
```bash
ls -la /data/adb/su-scheduler/shells/<task_id>.*
```

### No Output

**Check output file:**
```bash
cat /data/adb/su-scheduler/shells/<task_id>.out
```

**Send a test command:**
```bash
su-scheduler shell-send <task_id> "echo 'test'"
sleep 1
su-scheduler task-output <task_id>
```

### Shell Died

**Check logs:**
```bash
su-scheduler log | grep <task_id>
```

**Restart it:**
```bash
su-scheduler add boot "sh; : --interactive"
```

---

## Best Practices

### 1. Always Use Boot Tasks for Persistent Shells

```bash
# Good - survives reboots
su-scheduler add boot "sh; : --interactive"

# Bad - dies after one run
su-scheduler add 09:00 "sh; : --interactive"
```

### 2. Use Notifications

```bash
su-scheduler add boot "sh; : --interactive --notify --msg='Shell Ready'"
```

### 3. Name Your Shells (via comments)

```bash
# Edit config
su-scheduler edit

# Add comment above
# Main monitoring shell
boot sh; : --interactive
```

### 4. Monitor Output

```bash
# Set up a monitoring task
su-scheduler add boot "tail -f /data/adb/su-scheduler/shells/boot_1_*.out > /sdcard/shell-monitor.log; : --interactive"
```

### 5. Clean Up Old Shells

```bash
# Kill old shells
su-scheduler task-kill <old_task_id>

# Remove old FIFO files
rm /data/adb/su-scheduler/shells/<old_task_id>.*
```

---

## Quick Reference

| Action | Command |
|--------|---------|
| Start shell | `su-scheduler add boot "sh; : --interactive"` |
| List shells | `su-scheduler tasks` |
| Connect | `su-scheduler shell-attach <task_id>` |
| Send command | `su-scheduler shell-send <task_id> "<cmd>"` |
| View output | `su-scheduler task-output <task_id>` |
| Kill shell | `su-scheduler task-kill <task_id>` |
| Check status | `su-scheduler task-info <task_id>` |

---

## Summary

Interactive shells in Su Scheduler provide:

✅ **Persistent Sessions** - Shells that survive and stay running
✅ **Real-time Interaction** - Send commands anytime
✅ **Live Monitoring** - Watch output as it happens
✅ **Termux Support** - Full Termux environment available
✅ **Multiline Support** - Execute complex scripts
✅ **Easy Management** - Simple CLI commands

Perfect for debugging, monitoring, and interactive automation! 🎮🚀
# 🐧 Termux Integration Guide - Su Scheduler

## Overview

Su Scheduler now supports **full Termux environment execution**, allowing you to run Termux packages, scripts, and utilities as scheduled tasks with complete environment setup.

## Features

### ✅ What's Included

- **Full Environment Setup**: PATH, LD_LIBRARY_PATH, PREFIX, HOME, etc.
- **User 0 Decryption**: Automatic handling of FBE (File-Based Encryption)
- **Shell Detection**: Automatically uses your configured Termux shell (zsh/bash/sh)
- **Package Access**: Full access to all Termux packages and utilities
- **Seamless Integration**: Works with all Su Scheduler features (notifications, scheduling, etc.)

### 🔧 How It Works

When you use the `: --termux` modifier, Su Scheduler:

1. **Validates Termux Installation**
   - Checks if Termux is installed at `/data/data/com.termux`
   - Verifies accessibility of Termux binaries

2. **Handles User 0 Decryption**
   - Automatically waits for User 0 to be decrypted
   - Ensures Termux files are accessible

3. **Sets Up Environment**
   - Exports all necessary Termux environment variables
   - Configures PATH to include Termux binaries
   - Sets up LD_LIBRARY_PATH for Termux libraries
   - Loads libtermux-exec.so for shebang fixing

4. **Executes Command**
   - Runs your command in Termux's preferred shell
   - Full access to Termux packages and utilities

## Usage

### Basic Syntax

```bash
su-scheduler add <trigger> "<command>; : --termux"
```

### Examples

#### Python Scripts
```bash
# Run Python script daily at 9 AM
su-scheduler add 09:00 "python /sdcard/backup.py; : --termux --notify"

# Weekly Python data processing
su-scheduler add weekly:1:0800 "python /sdcard/process_data.py; : --termux"
```

#### Node.js Scripts
```bash
# Daily Node.js task
su-scheduler add 14:00 "node /sdcard/server-check.js; : --termux --notify-end"

# Monthly Node.js report
su-scheduler add monthly:01:0900 "node /sdcard/monthly-report.js; : --termux"
```

#### Termux Utilities
```bash
# Battery status logging
su-scheduler add 08:00 "termux-battery-status > /sdcard/battery.log; : --termux"

# WiFi scanning
su-scheduler add 12:00 "termux-wifi-scaninfo > /sdcard/wifi.log; : --termux"

# Location tracking
su-scheduler add 18:00 "termux-location > /sdcard/location.log; : --termux"
```

#### Package Management
```bash
# Auto-update Termux packages on boot
su-scheduler add boot "pkg update && pkg upgrade -y; : --termux --notify"

# Weekly package cleanup
su-scheduler add weekly:7:2300 "pkg autoclean; : --termux"
```

#### Git Operations
```bash
# Daily git pull
su-scheduler add 06:00 "cd ~/projects && git pull; : --termux --notify"

# Weekly backup to git
su-scheduler add weekly:7:2200 "cd ~/backup && git add . && git commit -m 'Auto backup' && git push; : --termux"
```

#### Cron-like Tasks
```bash
# Run custom backup script
su-scheduler add 03:00 "~/bin/backup.sh; : --termux --notify-end"

# Database maintenance
su-scheduler add monthly:01:0200 "~/scripts/db-maintenance.sh; : --termux"
```

## Environment Variables

When `: --termux` is used, the following environment is set up:

```bash
PREFIX="/data/data/com.termux/files/usr"
HOME="/data/data/com.termux/files/home"
TMPDIR="/data/data/com.termux/files/usr/tmp"
SHELL="/data/data/com.termux/files/usr/bin/zsh"  # or bash/sh
USER="u0_aXXXX"  # Termux user
LOGNAME="u0_aXXXX"
TERM="xterm-256color"
COLORTERM="truecolor"
LANG="en_US.UTF-8"
LD_PRELOAD="/data/data/com.termux/files/usr/lib/libtermux-exec.so"
PATH="/data/data/com.termux/files/usr/bin:..."
LD_LIBRARY_PATH="/data/data/com.termux/files/usr/lib:..."
```

## Troubleshooting

### Task Fails with "User 0 locked"

**Problem**: The device is encrypted and User 0 hasn't been decrypted yet.

**Solution**: 
- Ensure device is unlocked before the task runs
- For boot tasks, add a delay: `boot sleep 60 && <command>; : --termux`

### Task Fails with "Termux not installed"

**Problem**: Termux is not installed or not accessible.

**Solution**:
- Install Termux from F-Droid or GitHub
- Ensure Termux has been opened at least once
- Check permissions: `ls -la /data/data/com.termux`

### Command Not Found

**Problem**: Termux package not installed.

**Solution**:
```bash
# Install the package first
su-scheduler exec "pkg install python; : --termux"

# Then schedule your task
su-scheduler add 09:00 "python script.py; : --termux"
```

### Permission Denied

**Problem**: Script doesn't have execute permission.

**Solution**:
Su Scheduler automatically fixes this, but you can also:
```bash
chmod +x /sdcard/script.sh
```

## Combining with Other Modifiers

```bash
# Termux + Notification + Delete (one-time)
su-scheduler add 15:00 "python /sdcard/setup.py; : --termux --notify --delete"

# Termux + Boot + Custom Message
su-scheduler add boot "pkg update; : --termux --notify --msg='Packages Updated'"

# Termux + Weekly + Notification
su-scheduler add weekly:1:0900 "node backup.js; : --termux --notify-end"
```

## Best Practices

1. **Test Commands First**
   ```bash
   # Test in Termux first
   termux
   python /sdcard/script.py
   
   # Then schedule
   su-scheduler add 09:00 "python /sdcard/script.py; : --termux"
   ```

2. **Use Absolute Paths**
   ```bash
   # Good
   su-scheduler add 09:00 "/data/data/com.termux/files/home/script.sh; : --termux"
   
   # Also good (~ expands in Termux)
   su-scheduler add 09:00 "~/script.sh; : --termux"
   ```

3. **Handle Errors**
   ```bash
   # Add error handling
   su-scheduler add 09:00 "python script.py || echo 'Failed' > /sdcard/error.log; : --termux"
   ```

4. **Use Notifications**
   ```bash
   # Always notify for important tasks
   su-scheduler add 03:00 "~/backup.sh; : --termux --notify"
   ```

## Monitoring

```bash
# View task output
su-scheduler task-output <task_id>

# Check logs
su-scheduler log -f

# View task info
su-scheduler task-info <task_id>
```

## Advanced: Interactive Termux Shell

```bash
# Start interactive Termux shell on boot
su-scheduler add boot "sh; : --termux --interactive"

# Attach to it later
su-scheduler shell-attach boot_1_1673634567

# Send commands
su-scheduler shell-send boot_1_1673634567 "python script.py"
```

## Limitations

- Requires Termux to be installed
- Requires User 0 to be decrypted (device unlocked)
- Some Termux-specific features may not work (e.g., termux-api requiring foreground service)
- GUI apps won't work (terminal only)

## Summary

The `: --termux` modifier transforms Su Scheduler into a powerful automation tool for Termux users, enabling:

- ✅ Scheduled Python/Node.js/Ruby scripts
- ✅ Automated package management
- ✅ Git operations
- ✅ Data processing tasks
- ✅ System monitoring
- ✅ Backup automation
- ✅ And much more!

All with the full power of Termux's ecosystem at your fingertips! 🐧🚀
# 📅 Su Scheduler - Advanced Scheduling Quick Reference

## 🎯 Trigger Formats

### Basic Triggers
| Format | Description | Example |
|--------|-------------|---------|
| `boot` | Run on every boot | `boot echo "Booted"` |
| `HHMM` | Daily at time | `0830 backup.sh` |
| `HH:MM` | Daily at time (alt) | `08:30 backup.sh` |

### Advanced Triggers

#### Weekly Schedule
```bash
weekly:DAY:HHMM
```
- **DAY**: 1=Monday, 2=Tuesday, ..., 7=Sunday
- **Examples**:
  - `weekly:1:0800` - Every Monday at 8 AM
  - `weekly:5:1700` - Every Friday at 5 PM
  - `weekly:7:2200` - Every Sunday at 10 PM

#### N-Weekly Schedule (Every N Weeks)
```bash
nweekly:N:DAY:HHMM
```
- **N**: Number of weeks between executions
- **Examples**:
  - `nweekly:2:1:0900` - Every 2 weeks on Monday at 9 AM
  - `nweekly:4:3:1400` - Every 4 weeks on Wednesday at 2 PM

#### Monthly Schedule
```bash
monthly:DD:HHMM
```
- **DD**: Day of month (01-31)
- **Examples**:
  - `monthly:01:0000` - 1st of every month at midnight
  - `monthly:15:1200` - 15th of every month at noon
  - `monthly:28:2300` - 28th of every month at 11 PM

#### N-Monthly Schedule (Every N Months)
```bash
nmonthly:N:DD:HHMM
```
- **N**: Number of months between executions
- **Examples**:
  - `nmonthly:3:01:0900` - Every 3 months on the 1st at 9 AM (Quarterly)
  - `nmonthly:6:15:1200` - Every 6 months on the 15th at noon (Bi-annually)

#### Yearly Schedule
```bash
yearly:MM:DD:HHMM
```
- **MM**: Month (01-12)
- **DD**: Day (01-31)
- **Examples**:
  - `yearly:01:01:0000` - New Year's Day at midnight
  - `yearly:12:25:0800` - Christmas Day at 8 AM
  - `yearly:07:04:1200` - July 4th at noon

## 🎨 Modifiers

| Modifier | Description |
|----------|-------------|
| `: --delete` | Run once and remove from schedule |
| `: --boot` | Also run on boot (for time-based tasks) |
| `: --notify` | Send notification on start AND completion |
| `: --notify-start` | Send notification only on start |
| `: --notify-end` | Send notification only on completion |
| `: --msg="text"` | Custom notification message |
| `: --interactive` | Run in interactive shell mode |

## 📝 Complete Examples

### Daily Tasks
```bash
# Clear logs every day at 8 AM
su-scheduler add 08:00 "logcat -c; : --notify"

# Reboot daily at 3 AM
su-scheduler add 03:00 "reboot; : --notify-start"
```

### Weekly Tasks
```bash
# Weekly backup every Sunday at 11 PM
su-scheduler add weekly:7:2300 "/sdcard/backup.sh; : --notify"

# Clear cache every Monday at 9 AM
su-scheduler add weekly:1:0900 "pm clear com.android.chrome; : --notify-end"
```

### Bi-Weekly Tasks
```bash
# System maintenance every 2 weeks on Saturday
su-scheduler add nweekly:2:6:1000 "/sdcard/maintenance.sh; : --notify"
```

### Monthly Tasks
```bash
# Monthly report on the 1st at midnight
su-scheduler add monthly:01:0000 "/sdcard/monthly-report.sh; : --notify"

# Cleanup on the 15th of each month
su-scheduler add monthly:15:0300 "find /sdcard/Download -mtime +30 -delete"
```

### Quarterly Tasks
```bash
# Quarterly backup every 3 months on the 1st
su-scheduler add nmonthly:3:01:0200 "/sdcard/quarterly-backup.sh; : --notify"
```

### Yearly Tasks
```bash
# New Year celebration
su-scheduler add yearly:01:01:0000 "echo 'Happy New Year!' > /sdcard/newyear.txt; : --notify --msg='Happy New Year!'"

# Birthday reminder
su-scheduler add yearly:06:15:0800 "echo 'Birthday today!'; : --notify --msg='Happy Birthday!'"
```

### Combined Modifiers
```bash
# One-time task with notification
su-scheduler add 14:30 "reboot; : --delete --notify"

# Task that runs on time AND boot
su-scheduler add 08:00 "settings put global airplane_mode_on 0; : --boot --notify"

# Custom notification message
su-scheduler add weekly:1:0900 "backup.sh; : --notify --msg='Weekly Backup Complete'"
```

## 🧪 Testing

Run the comprehensive test suite:
```bash
# Copy test config and run tests
./test-scheduler.sh
```

This will:
- Backup your current config
- Install test configuration
- Test all features (boot, time, weekly, monthly, yearly)
- Monitor execution for 60 seconds
- Display results

## 📊 Monitoring

```bash
# View running tasks
su-scheduler tasks

# Follow logs in real-time
su-scheduler log -f

# View task details
su-scheduler task-info <task_id>

# View task output
su-scheduler task-output <task_id>
```

## 🔍 Day of Week Reference

| Number | Day |
|--------|-----|
| 1 | Monday |
| 2 | Tuesday |
| 3 | Wednesday |
| 4 | Thursday |
| 5 | Friday |
| 6 | Saturday |
| 7 | Sunday |

## 📅 Month Reference

| Number | Month |
|--------|-------|
| 01 | January |
| 02 | February |
| 03 | March |
| 04 | April |
| 05 | May |
| 06 | June |
| 07 | July |
| 08 | August |
| 09 | September |
| 10 | October |
| 11 | November |
| 12 | December |

---

## 🔗 兼容性与 P1 阶段状态（P1-13 追加）

> 本章节为 P1 阶段（P1-01..P1-13）**追加**，不改动本文件既有任何章节。
> 详细交接资料见 `docs/P1-HANDOVER.md`；兼容层架构见
> `docs/architecture/compatibility-layer.md`。

### 兼容性承诺

- **配置格式不变**：`config.txt` 行格式 `<trigger> <command>[;] : <modifiers>`
  与全部触发格式（boot / HHMM / HH:MM / weekly / nweekly / monthly /
  nmonthly / yearly）、modifiers（--notify / --delete / --interactive /
  --termux / --run-once-now / --msg）、heredoc 语义保持 v1.6.8 基线（基线
  见 `docs/phase-1-baseline.md`）。
- **旧解析与执行路径保留**：daemon、CLI、`service.sh`、`customize.sh`、
  `build.sh` 与既有看护循环在 P1 期间零改动。
- **P1 新增全部在测试域与文档**：内部 Task 模型（Schema v2）、状态机、
  Provider 契约、Legacy Adapter、Task Registry、Trigger 决策、Action 执行、
  运行时状态/事件、生命周期、只读 `task list` / `task status`——均不触碰
  生产文件、不写回 `config.txt`。
- **新旧状态不互覆盖**：旧工件（`status.txt`/`pid.txt`/`output.log`/
  `exit_code.txt`/`end_time.txt`/`start_time.txt`）保持原义；新
  `state.txt`/`events.log` 为**新增文件**，不与旧件同名。

### P1 状态

- **已实现**：P1-01..P1-12（基线、Task Schema v2、状态机、Provider 契约、
  Legacy Adapter、Task Registry、Trigger 决策、Action 执行、运行时状态/事件、
  生命周期、只读 Task CLI、P1 回归与设备冒烟脚本）。回归入口：
  `bash tests/run_p1.sh`（11 套全绿，无 `[FAIL]`）。
- **未实现（下一阶段，不视为已完成）**：**Watchdog 增强**、**WebUI**、
  **Dependency**（依赖/条件触发）、App/Process/Service Action、
  Health/Recovery 真实探测、daemon/CLI 生产接线——接口预留见
  `docs/P1-HANDOVER.md` §5，任何文档不得把它们表述为已完成。
- **升级与回滚**：P1 零生产改动，升级 = 合入 P1 提交（无迁移）；回滚 =
  删除 P1 层与文档（生产零影响）。命令级手册见 `docs/P1-UPGRADE-ROLLBACK.md`。

---

## 🌐 WebUI 只读数据面（P3-05）

> 本章节为 P3-05 追加，不改动本文件既有任何章节。

Su Scheduler 提供**只读** WebUI（Dashboard / Task List / Task Detail / Logs），
数据全部经 IPC（Runtime Read Aggregator，Runtime §22）读取——**不提供任何
Root Shell，前端 JS 不读数据目录、不调系统命令/动态求值**。静态资源位于
模块 `webroot/`（KernelSU 原生 WebUI 伺服），同时提供 CLI Reader 供主机/脚本使用：

```bash
# 主机/脚本验收与 KernelSU WebUI Bridge 共用同一 CLI Reader（只读白名单）
su-scheduler webui GET_SUMMARY
su-scheduler webui GET_TASK_DETAIL id=<base64(task_id)>
su-scheduler webui GET_TASK_EVENTS id=<base64(task_id)> lines=<base64(50)>
su-scheduler webui GET_DAEMON_LOG lines=<base64(100)>
su-scheduler webui GET_TASK_LOG id=<base64(task_id)> lines=<base64(100)>
```

- 成功输出**单行统一 JSON**；失败输出 `{"ok":false,"rc":N,"error":"..."}`
  （rc 6 = daemon_unavailable 离线；rc 3 = task_not_found）。
- 日志读取有界（task/daemon ≤500 行、events ≤200 行），`truncated` 标志
  明确提示「日志已截断」。
- 页面范围与数据契约见 **`docs/P3-05-WEBUI-DATA.md`**；执行记录见 `docs/P3-05.md`。

---

## 🎛️ Task 控制操作（P3-07）

> 本章节为 P3-07 追加，不改动本文件既有任何章节。

WebUI 与 CLI 共用**同一控制 API**：CLI `su-scheduler task <op> <id>` 与 WebUI
控制按钮（Task Detail 的 Start/Stop/Restart/Check/Enable/Disable/Logs）都经
IPC op（`START_TASK`/`STOP_TASK`/`RESTART_TASK`/`CHECK_TASK`/`ENABLE_TASK`/
`DISABLE_TASK`/`GET_TASK_LOG`）落到 daemon 的 Runtime §24 `tctl_*`（唯一控制
语义 + TSM 状态机强制），旧 CLI 命令（`task-info`/`task-output`/`task-kill`/
`tasks`/`status`/`stop`/`restart`）零改动保留。

```bash
su-scheduler task enable <id>      # 修改配置状态（仅 Managed）
su-scheduler task disable <id>
su-scheduler task start <id>       # 手动启动（已运行 → skip，不重复启动）
su-scheduler task stop <id>        # 停止当前运行实例（只杀本运行目录 pid）
su-scheduler task restart <id>     # 停止后重新启动
su-scheduler task check <id>       # 立即执行一次健康检查
su-scheduler task logs <id> [n]    # 查询 Task 日志
```

- **状态机强制**：start 经 `PENDING→STARTING→RUNNING`、stop 经
  `RUNNING/HEALTHY→STOPPING→STOPPED`、终态重武装 `FAILED→PENDING`；非法操作
  （如 STOPPING 中 start）返回错误且**不强行写状态文件**。
- 支持稳定 Task ID 与旧运行 ID（旧运行 ID 控制其旧运行目录）。
- 执行记录见 `docs/P3-07.md`。

---

## 🔒 安全与资源加固（P3-08）

> 本章节为 P3-08 追加，不改动本文件既有任何章节。

WebUI 作为高权限（root）平台的安全与资源加固（Runtime §25）：输入/文件/执行/
资源四类，全部为叠加校验原语 + 既有入口收口（不重构、不加 eval、不临时拼接
Root 命令）。

- **输入安全**：IPC 白名单 + 参数键白名单（P3-04）；`secv_id_ok` Task ID 字符集
  门（id-bearing op 外层拒绝路径穿越 id → invalid_request）；`secv_num_clamp`
  数值钳制（日志 lines）；请求大小限制（IPC_REQ_MAX）。
- **文件安全**：`secv_inside`/`secv_nosymlink`/`secv_guard_task_dir` 路径必须位于
  允许目录（拒绝 `..`/符号链接逃逸）；`secv_fix_perms` 权限强制（ipc 0700 /
  task-config 600 / 运行目录 700）；`secv_sweep_tmp` 临时文件清理（原子写兜底）。
- **执行安全**：命令只读自已校验任务文件（WebUI/CLI 不能临时拼接 Root 命令）；
  `secv_effective_timeout` 每个 Action 有超时（advanced.timeout ≤ TASK_RUNTIME_MAX）。
- **资源安全**：`runtime_limit_task_log` 单 Task 日志字节上限；快照/任务目录上限
  （P2-14）；`secv_ipc_ratelimit` IPC 频率限制（超限 → rc 7 `rate_limited`）。
- 审计清单见 `docs/security-audit.md`；执行记录见 `docs/P3-08.md`。

---

## 🧪 回归测试（P2-01 追加）

> 本章节为 P2-01 追加，不改动本文件既有任何章节。P0/P1 门禁的**唯一回归入口**
> 已统一为 `tests/run_tests.sh`（取代并覆盖此前的 `tests/run_p1.sh` 与
> `tests/_run_all.sh`；后两者保留为兼容子入口，见下）。

### 唯一入口与层级

```bash
bash tests/run_tests.sh                # 全量：L1 + L2 + L4（无设备）
bash tests/run_tests.sh --with-device  # 追加 L3 设备冒烟（无设备 → DEVICE_SKIPPED）
bash tests/run_tests.sh --lint-only    # 只跑 L1 静态语法层（快速检查）
```

| 层 | 内容 | 套件 |
| :-- | :-- | :-- |
| L1 | 静态语法（`sh -n` / `bash -n`，LF 归一，CRLF 检出亦通过） | `tests/lint/syntax.sh` |
| L2 | legacy 解析 golden 锁定（真实函数复现 + 逐字节比对） | `tests/legacy/golden.sh` |
| L2 | `--delete` 删除管线语义锁定（Q13：单激活行 `grep -v && mv` 短路） | `tests/legacy/delete-pipeline.sh` |
| L2 | 生产 Runtime 库边界（P2-02：daemon/CLI 共用原语、路径隔离、fallback） | `tests/runtime-lib/test.sh` |
| L2 | Registry Shadow Mode（P2-03：启动快照、原子 reload、损坏 KEPT、旁路比对记录） | `tests/shadow/test.sh` |
| L2 | Canonical↔Legacy Run ID 兼容（P2-04：双向映射、旧 CLI 原样可用、零改名） | `tests/idmap/test.sh` |
| L2 | TriggerProvider 接入（P2-05：单一正式入口 trigger_decide、boot/time/advanced 经 Provider、保留 ron/delete/去重、新旧一致比对） | `tests/trigger/test.sh` |
| L2 | CommandActionProvider 接入（P2-06：单一正式入口 action_run、Provider 委托既有 execute_task、四模式经统一 Action 入口、旧工件 status/pid/output/exit_code 保留、不建第二执行器） | `tests/action/test.sh` |
| L2 | 统一状态与事件日志（P2-07：state.txt/events.log 双写与旧工件并存、一次性任务成功→STOPPED 不虚假 HEALTHY、健康 Provider 门槛、非法转换非致命、重启残留再水合、旧 CLI 仍读旧状态） | `tests/state/test.sh` |
| L2 | 生产 Task CLI（P2-08：`task list|status`、Registry 只读挂载不重扫配置、稳定 Task ID 与旧运行 ID 双向查询、三态错误区分） | `tests/task-cli-prod/test.sh` |
| L2 | daemon 生命周期（P2-09：启动序列、最后有效快照回退、stale PID 恢复、stop/restart/stale lock 真实链路、单常驻循环、service 60s 看护原样） | `tests/lifecycle-prod/test.sh` |
| L2 | App Action（P2-10：package/activity/broadcast/service 结构化 spec、全参数校验拒绝 shell 注入、固定 am 模板构建、mock am 逐 argv 断言） | `tests/app-action/test.sh` |
| L2 | Process/Port Health（P2-11：Process Check / Port Check、统一三态 HEALTHY/UNHEALTHY/UNKNOWN + 原因 + 延迟 + 目标、真实监听验证、P2-07 健康门槛打开） | `tests/health/test.sh` |
| L2 | Supervisor 核心（P2-12：RUNNING→HEALTHY→UNHEALTHY→RECOVERING→STARTING\|FAILED 完整生命周期、统一事件循环无每任务常驻循环、恢复策略 retry.max/interval、真实 nc 闭环） | `tests/supervisor/test.sh` |
| L2 | Recovery/Retry/Cooldown（P2-13：Restart/Start/Stop+Start/Execute Script 恢复动作、max_retry 钳制禁止无限重启、retry.interval 节奏、基础 cooldown） | `tests/recovery/test.sh` |
| L2 | Crash Loop 与资源保护（P2-14：guard 降级窗口/节流/优雅重置、SIGKILL 崩溃序列抑制、日志/任务目录/快照上限、健康探针最小间隔、运行超时护栏、fake daemon 真实链路） | `tests/crashguard/test.sh` |
| L2 | P2 综合回归（P2-15：daemon kill/task kill/脚本 hang/应用崩溃/重启 端到端集成、Supervisor+CrashGuard+Health+Recovery 故障自愈闭环、重启残留收尾） | `tests/p2-integration/test.sh` |
| L2 | P2 发布评审（P2-15：KernelSU/Magisk/APatch 安装结构 + 发布契约、systemless 覆盖、数据独立模块目录、manager-agnostic 安装） | `tests/p2-install/test.sh` |
| L2 | Canonical Task Config Store（P3-02：双模式 legacy/managed 权威、导入幂等、失败原子性、回滚、导出、新建 ID `task_` 命名空间、损坏回退、接线） | `tests/config-v2/test.sh` |
| L2 | Task v2 编辑校验矩阵（P3-06：ID 路径穿越拒绝、trigger 枚举、App Action 注入全拒、recovery script 绝对路径可读、数值范围钳制、保存原子性、后端权威校验） | `tests/config-v2/validation.sh` |
| L2 | Registry 正式调度接管（P3-03：Registry 从 Shadow 提升为正式调度源、双模式 legacy/managed、TriggerProvider→ActionProvider、同周期去重、配置变更不重复执行、损坏 KEPT、task.v2 快照移除监督兜底、旧 CLI 查询/终止、单任务错误隔离、审计日志、接线） | `tests/scheduler-prod/test.sh` |
| L2 | 本地 IPC 控制面（P3-04：请求/响应文件通道、固定格式、base64 值、19 op 白名单（P3-07 起含 CHECK_TASK）、可区分错误码、写操作仅 managed、START/STOP/RESTART 经 action_run→§24 tctl_*、重复请求不重复启动、原子响应、接线） | `tests/ipc/test.sh` |
| L2 | IPC 安全边界（P3-04：fuzz/注入零副作用、Shell 元字符不进入执行路径、同 req_id 幂等、已运行不重复 START、单轮有界不阻塞、0700 权限、未授权写 permission_denied、daemon 停止 daemon_unavailable、超时 operation_timeout） | `tests/ipc/security.sh` |
| L2 | WebUI 只读数据面（P3-05：GET_SUMMARY/GET_TASK_DETAIL/GET_TASK_EVENTS/GET_DAEMON_LOG 统一 JSON、GET_TASK_LOG meta 行、JSON 转义防注入、空/损坏/daemon 离线三态、CLI Reader 只读白名单 + JSON 信封、零 exec） | `tests/webui/read-only.test.sh` |
| L2 | WebUI 安全（P3-05：webroot 无 Root 直执特征、恶意请求零 exec/零 config 写、`<script>`/引号/换行 JSON 转义、malformed→invalid_request、有界日志 + truncated 标志） | `tests/webui/security.test.sh` |
| L2 | WebUI Task Editor（P3-06：GET_TASK_EDIT/EDIT_TASK/VALIDATE_TASK(payload) 分步表单保存/校验/回滚、合法保存重载、非法拒绝、旧配置不变、无重复 ID、App Action 注入拒、Health/Recovery 可被 Supervisor 读取） | `tests/webui/editor.test.sh` |
| L2 | Task 控制操作（P3-07：WebUI 与 CLI 共用同一控制 API `task enable\|disable\|start\|stop\|restart\|check\|logs`，§24 tctl_* + TSM 强制可追踪、并发 start skip、stop 不误杀、旧运行 ID 控制旧运行目录、CHECK_TASK 立即健康检查、enable/disable 仅 managed、CLI 子命令经 IPC 全链路、失败不破坏 Registry/旧工件） | `tests/task-control/test.sh` |
| L2 | 安全与资源加固（P3-08 输入安全：IPC 白名单/格式 fuzz、Task ID 字符集门、请求大小限制、START/CREATE/UPDATE 命令注入全拒、App Action/脚本路径校验，全零副作用） | `tests/security/fuzz.sh` |
| L2 | 安全与资源加固（P3-08 路径安全：路径穿越/符号链接/允许目录约束/Task ID 门/IPC 穿越 id 拒绝零泄露、相对脚本拒） | `tests/security/path-validation.sh` |
| L2 | 安全与资源加固（P3-08 文件安全：secv_fix_perms 强制 0700/600、原子写 tmp 清理、secv_sweep_tmp、未授权写 permission_denied） | `tests/security/permission.sh` |
| L2 | 安全与资源加固（P3-08 资源安全：100 Task 单循环无 100 永久循环、日志/快照/任务目录上限、单任务错误隔离、IPC 频率限制 rc 7、CPU/内存有界） | `tests/resource/stress.sh` |
| L2 | P3 综合回归（P3-09：安装契约→daemon 生命周期/Runtime 加载→Legacy 继续执行→Task v2 导入→Registry 调度→WebUI Dashboard→Task Editor 保存/回滚→App Action→Process/Port Health→Retry/Cooldown 钳制→Crash Loop→Task 控制→配置损坏回退→旧 CLI 查询→日志轮转→重启状态恢复 端到端协同，48 断言） | `tests/p3-integration/test.sh` |
| L2 | Dependency/Condition Schema 与持久化（P4-02：`dependency=a,b,c` 逗号规范写回/空格容错规范化、`[?]<task-id>[:<STATE>]` 单条语法、STATE ∈ {STOPPED,FAILED}、condition 可打印 ASCII ≤256、DEP_MAX=32/COND_MAX_LEN=256、editor/store/CLI 后端权威校验、非法拒绝且原文件逐字节不变、Legacy 零影响） | `tests/p4-dependency/test.sh` |
| L2 | CLI 行为门禁（Q1/Q2/Q3/Q4/Q9：`log -n`、`add` 触发器集、`list` 空态、`task-output` 去重、yearly 归一） | `tests/cli/test.sh` |
| L2 | P1 层九套 + 跨层集成回归 | state-machine / providers / legacy-adapter / task-registry / trigger-decision / action-run / runtime / lifecycle / task-cli / p1-regression |
| L4 | 构建 + 八处版本一致性（含 docs 头部与 changelog，Q12） | `tests/p1-build/build_check.sh` |
| L3 | 设备冒烟（真实 KernelSU 设备，`adb` 通道；P1 legacy 冒烟） | `tests/p1-device/smoke.sh` |
| L3 | P3 设备矩阵冒烟（P3-09：真机 18 项覆盖 + mksh `\|` 缺陷探测判定，`adb root`；结果见 docs/P3-DEVICE-MATRIX.md） | `tests/p3-device/smoke.sh` |

**判定**：输出不得出现 `[FAIL]`；允许跳过项仅限 L3（`DEVICE_SKIPPED` 明示）与
CRLF 检出下的构建执行（`[SKIP]` 明示，CI/LF 为构建闸）。**结果可追溯**：每次
运行把完整逐层输出落盘 `tests/results/run_tests-<时间戳>.log`（`*.log` 已被
`.gitignore` 忽略，不污染工作树），末尾打印日志路径。

### CI 门禁

`.github/workflows/test.yml`：`main` push（生产/测试/文档变更路径）与 PR 上运行
`bash tests/run_tests.sh`（`ubuntu-latest` 标准 runner 自带工具，C3 合规；
无 adb → L3 不参与）。**成功与失败均上传 trace 日志工件（30 天保留，
P3-01）**——成功回归 trace 亦作为发布门禁证据存档。

### 兼容性说明

- `bash tests/run_p1.sh` 仍可用：P1 层专用子入口（9 套 + p1-regression + build-check），
  不含 L1 与 CLI 门禁——新任务请使用 `tests/run_tests.sh`。
- `tests/_run_all.sh` 已由 `tests/run_tests.sh` 取代（不再作为推荐入口）。
- Q1–Q4/Q9/Q11/Q12 处理与 Q10（`--boot`）决策记录见 `docs/P2-01.md`；基线文档
  `docs/phase-1-baseline.md` §6.1 有逐项状态表。

### 📄 P3 出口与发布文档（P3-10 追加）

> 本章节为 P3-10 追加，不改动本文件既有任何章节。

- **出口评审**：`docs/P3-EXIT-REPORT.md`（P3 出口标准 11 项覆盖矩阵、功能/兼容/安全/
  发布分类核验、D-IPC 修复说明、约束审计）。
- **交接资料**：`docs/P3-HANDOVER.md`（新成员阅读路径、P3 流程全景、已实现清单、
  P4 接口预留点、安全边界）。
- **升级与回滚**：`docs/P3-UPGRADE-ROLLBACK.md`（发布候选安装、卸载/回滚、故障排查）。
- **设备矩阵**：`docs/P3-DEVICE-MATRIX.md`（KernelSU×Android 16 真机 P3-09/10
  **25 PASS / 0 FAIL / 3 BLOCKED**→D-IPC 修复；**P4-01 复验 28 PASS / 0 FAIL /
  0 BLOCKED**，7/8/14 转 PASS；其余 14 格为发布限制）。
- **P4 Dependency 需求输入**：`docs/P4-DEPENDENCY-REQUIREMENTS.md`（WAITING 接线点、
  功能/非功能需求、安全边界、禁止事项）。
