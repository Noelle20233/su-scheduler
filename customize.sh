#!/system/bin/sh
# ---------------------------------------------------------------------------------------
# 🛠️ Su Scheduler Installer (customize.sh) 🛠️
# ---------------------------------------------------------------------------------------
# Author: Rex Ackermann
# Description: This script handles the surgical installation of the module.
# It sets up permissions, directories, and default configurations.
# ---------------------------------------------------------------------------------------

# 🤐 Tell the system to skip the default unzipping (we do it manually for control)
SKIPUNZIP=1

# 🎨 Premium ASCII Splash Screen
ui_print "*********************************************************"
ui_print " __                       __             __      __      "
ui_print "/  \      |   _ __ |_    |  \    |     /  \    /  \    "
ui_print "\__       |__|  |  |__   |__/    |     \__/    \__/    "
ui_print "   \  |   |              |       |                     "
ui_print "\__/  \__/               |       |____                 "
ui_print "                                                       "
ui_print "*********************************************************"
ui_print "✨ Su Scheduler for Android - Let's get automated! ✨"
ui_print "*********************************************************"

# 📦 [PHASE 1] Extractions
# We extract the files from the zip to their systemless homes
ui_print "- 📂 Extracting core module files..."
unzip -o "$ZIPFILE" 'system/*' -d $MODPATH >&2
unzip -o "$ZIPFILE" 'service.sh' -d $MODPATH >&2
unzip -o "$ZIPFILE" 'module.prop' -d $MODPATH >&2
unzip -o "$ZIPFILE" 'webroot/*' -d $MODPATH >&2   # KernelSU 原生 WebUI 静态资源（P3-05）

# 📁 [PHASE 2] Data Directory Setup
# This is where your logs/state live
DATA_DIR="/data/adb/su-scheduler"
USER_DOC_DIR="/sdcard/Documents/su-scheduler"

# Ensure data vault exists
if [ ! -d "$DATA_DIR" ]; then
  ui_print "- 🏗️  Creating persistent vault: $DATA_DIR"
  mkdir -p "$DATA_DIR"
fi

# Ensure user document directory exists
if [ ! -d "$USER_DOC_DIR" ]; then
  ui_print "- 📂 Creating user directory: $USER_DOC_DIR"
  mkdir -p "$USER_DOC_DIR"
fi

# 📜 Genesis Config: Comprehensive examples and documentation
if [ ! -f "$USER_DOC_DIR/config.txt" ]; then
  ui_print "- ✍️  Writing comprehensive config to SD card..."
  cat << 'EOF' > "$USER_DOC_DIR/config.txt"
# ═══════════════════════════════════════════════════════════════════════════
# 🔥 Su Scheduler Configuration File 🔥
# ═══════════════════════════════════════════════════════════════════════════
# Author: Rex Ackermann
# Location: /sdcard/Documents/su-scheduler/config.txt
# Edit: su-scheduler edit
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# 📖 QUICK START GUIDE
# ═══════════════════════════════════════════════════════════════════════════
# Format: <trigger> <command>; : <modifiers>
#
# TRIGGERS:
#   boot              - Run on every boot
#   HHMM or HH:MM     - Daily at specific time (e.g., 0830 or 08:30)
#   weekly:DAY:HHMM   - Weekly (1=Mon, 7=Sun) e.g., weekly:1:0800
#   monthly:DD:HHMM   - Monthly on day DD e.g., monthly:15:1200
#   yearly:MM:DD:HHMM - Yearly e.g., yearly:01:01:0000
#
# MODIFIERS:
#   : --delete        - Run once and remove from schedule
#   : --boot          - Also run on boot (for time-based tasks)
#   : --notify        - Send notification on start & completion
#   : --notify-start  - Notify only on start
#   : --notify-end    - Notify only on completion
#   : --msg="text"    - Custom notification message
#   : --interactive   - Run in interactive shell mode
#   : --termux        - Execute in Termux environment
#
# COMMANDS:
#   su-scheduler add <trigger> "<command>"  - Add new task
#   su-scheduler list                       - List all tasks
#   su-scheduler remove <line>              - Remove task
#   su-scheduler edit                       - Edit this file
#   su-scheduler log -f                     - Follow logs
#   su-scheduler tasks                      - List running tasks
#   su-scheduler help                       - Show full documentation
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# 🏁 BOOT TASKS - Run when device starts
# ═══════════════════════════════════════════════════════════════════════════

# Example: Create boot marker
# boot touch /sdcard/Documents/su-scheduler/boot-$(date +%Y%m%d-%H%M%S).log

# Example: Boot notification
# boot echo "Device booted at $(date)"; : --notify --msg="System Ready"

# Example: Start interactive shell for debugging
# boot sh; : --interactive

# ═══════════════════════════════════════════════════════════════════════════
# ⏰ TIME-BASED TASKS - Run at specific times daily
# ═══════════════════════════════════════════════════════════════════════════

# Example: Clear logs every morning at 8 AM
# 08:00 logcat -c; : --notify-end --msg="Logs cleared"

# Example: Night mode at 10 PM
# 22:00 settings put system screen_brightness 10

# Example: Backup at 3 AM
# 03:00 /sdcard/Documents/su-scheduler/backup.sh; : --notify

# ═══════════════════════════════════════════════════════════════════════════
# 📅 WEEKLY TASKS - Run on specific day of week
# ═══════════════════════════════════════════════════════════════════════════

# Example: Weekly backup every Sunday at 11 PM
# weekly:7:2300 /sdcard/Documents/su-scheduler/weekly-backup.sh; : --notify

# Example: Monday morning cleanup
# weekly:1:0900 find /sdcard/Download -mtime +30 -delete; : --notify-end

# ═══════════════════════════════════════════════════════════════════════════
# 📆 MONTHLY TASKS - Run on specific day of month
# ═══════════════════════════════════════════════════════════════════════════

# Example: Monthly report on the 1st at midnight
# monthly:01:0000 /sdcard/Documents/su-scheduler/monthly-report.sh; : --notify

# Example: Cleanup on the 15th
# monthly:15:0300 find /sdcard -name ".cache" -type d -delete

# ═══════════════════════════════════════════════════════════════════════════
# 🎂 YEARLY TASKS - Run once per year
# ═══════════════════════════════════════════════════════════════════════════

# Example: New Year celebration
# yearly:01:01:0000 echo "Happy New Year!"; : --notify --msg="🎉 Happy New Year!"

# ═══════════════════════════════════════════════════════════════════════════
# 🐧 TERMUX TASKS - Execute in Termux environment
# ═══════════════════════════════════════════════════════════════════════════

# Example: Python script in Termux
# 09:00 python /sdcard/Documents/su-scheduler/backup.py; : --termux --notify

# Example: Update Termux packages on boot
# boot pkg update && pkg upgrade -y; : --termux --notify-end

# ═══════════════════════════════════════════════════════════════════════════
# 📜 MULTILINE CODE BLOCKS - Complex scripts
# ═══════════════════════════════════════════════════════════════════════════

# Example: Multiline backup script
# boot sh <<EOF; : --notify --msg="Backup Complete"
# echo "Starting backup..."
# cd /sdcard
# mkdir -p Backups/$(date +%Y%m%d)
# tar -czf Backups/$(date +%Y%m%d)/backup.tar.gz Documents/
# echo "Backup complete!"
# EOF

# ═══════════════════════════════════════════════════════════════════════════
# 💡 MORE EXAMPLES
# ═══════════════════════════════════════════════════════════════════════════

# Battery monitoring
# 08:00 dumpsys battery > /sdcard/Documents/su-scheduler/battery-$(date +%H%M).log

# WiFi scan
# 12:00 dumpsys wifi > /sdcard/Documents/su-scheduler/wifi-scan.log

# System info
# boot uname -a > /sdcard/Documents/su-scheduler/system-info.txt

# ═══════════════════════════════════════════════════════════════════════════
# 📚 DOCUMENTATION
# ═══════════════════════════════════════════════════════════════════════════
# Full documentation: su-scheduler help
# Interactive guide: su-scheduler help --interactive
# Termux guide: su-scheduler help --termux
# Scheduling guide: su-scheduler help --scheduling
# ═══════════════════════════════════════════════════════════════════════════
EOF
fi

# Create scripts directory
# Create example scripts if they don't exist
if [ ! -f "$USER_DOC_DIR/backup.sh" ]; then
  ui_print "- 📂 Creating example script: backup.sh"
  
  # Create example backup script
  cat << 'SCRIPT' > "$USER_DOC_DIR/backup.sh"
#!/system/bin/sh
# Example backup script for Su Scheduler
# Usage: su-scheduler add 03:00 "/sdcard/Documents/su-scheduler/backup.sh; : --notify"

echo "=== Backup Started at $(date) ==="

# Create backup directory
BACKUP_DIR="/sdcard/Documents/su-scheduler/backups/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# Backup important directories
tar -czf "$BACKUP_DIR/documents.tar.gz" /sdcard/Documents/ 2>/dev/null
tar -czf "$BACKUP_DIR/pictures.tar.gz" /sdcard/DCIM/ 2>/dev/null

# Clean old backups (older than 30 days)
find /sdcard/Documents/su-scheduler/backups/ -type f -mtime +30 -delete

echo "=== Backup Complete ==="
SCRIPT

  chmod +x "$USER_DOC_DIR/backup.sh"
  ui_print "- ✅ Example scripts created in $USER_DOC_DIR"
fi

# 🔑 [PHASE 3] Permission Protocol
# Ensuring our tools have the authority to run and execute
ui_print "- 🔒 Securing permissions..."
# 0 0 0755 0644 means root:root, 755 for dirs, 644 for files
set_perm_recursive $MODPATH 0 0 0755 0644
# Ensure bin files are executable (755)
set_perm_recursive $MODPATH/system/bin 0 0 0755 0755
# Ensure the boot service script is executable
set_perm $MODPATH/service.sh 0 0 0755

# 🎉 Final Celebration
ui_print "*********************************************************"
ui_print "✅ Installation Complete! You're now a power user. 🚀"
ui_print "💡 Tip: Reboot and type 'su-scheduler' in terminal."
ui_print "*********************************************************"
