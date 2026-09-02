#!/bin/bash
# Build script for Su Scheduler with embedded documentation
# Author: Rex Ackermann

NAME="su-scheduler"
VERSION="v1.6.8"
ZIP_NAME="${NAME}-${VERSION}.zip"
DOCS_FILE="system/bin/.su-scheduler-docs"

echo "🔨 Building Su Scheduler..."

# Remove old build
rm -f "$ZIP_NAME"

# Merge all documentation into single file
echo "📚 Merging documentation..."
cat > "$DOCS_FILE" << 'DOCS_START'
# ═══════════════════════════════════════════════════════════════════════════
# 📚 SU SCHEDULER - COMPLETE DOCUMENTATION
# ═══════════════════════════════════════════════════════════════════════════
# Author: Rex Ackermann
# Version: 1.6.8
# ═══════════════════════════════════════════════════════════════════════════

DOCS_START

# Add README (which now contains everything)
cat README.md >> "$DOCS_FILE"

echo "✅ Documentation prepared ($(wc -l < "$DOCS_FILE") lines)"

# Create zip
echo "📦 Creating $ZIP_NAME..."
zip -r "$ZIP_NAME" module.prop customize.sh service.sh system/ webroot/ -x "build.sh"

echo "✅ Done! File ready: $ZIP_NAME"
ls -lh "$ZIP_NAME"
