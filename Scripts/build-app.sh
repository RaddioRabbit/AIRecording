#!/bin/zsh
set -e

# AIRecording Release Build Script
# Creates a proper .app bundle with Info.plist, entitlements, and code signature.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build/release"
APP_BUNDLE="/Applications/AIRecording.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

BUNDLE_ID="com.airecording.app"
BUNDLE_NAME="AIRecording"
BUNDLE_EXECUTABLE="AIRecording"
BUNDLE_VERSION="1.0"
BUNDLE_BUILD="1"
MIN_OS_VERSION="13.0"

echo "🔨 Building AIRecording Release..."
swift build -c release --package-path "${PROJECT_DIR}"

if [ ! -f "${BUILD_DIR}/AIRecording" ]; then
    echo "❌ Error: release binary not found at ${BUILD_DIR}/AIRecording"
    exit 1
fi

KNOWLEDGE_BUILD_DIR="${PROJECT_DIR}/.build/knowledge-agent"
KNOWLEDGE_AGENT_BINARY="${KNOWLEDGE_BUILD_DIR}/dist/knowledge-agent"
KNOWLEDGE_PYTHON="${PROJECT_DIR}/KnowledgeAgent/.venv/bin/python"

if [ ! -x "${KNOWLEDGE_PYTHON}" ]; then
    echo "❌ Error: KnowledgeAgent runtime is missing. Run the documented local setup first."
    exit 1
fi

echo "📦 Packaging standalone KnowledgeAgent runtime..."
rm -rf "${KNOWLEDGE_BUILD_DIR}"
mkdir -p "${KNOWLEDGE_BUILD_DIR}/work" "${KNOWLEDGE_BUILD_DIR}/dist"
(
    cd "${PROJECT_DIR}/KnowledgeAgent"
    "${KNOWLEDGE_PYTHON}" -m PyInstaller --clean --noconfirm \
        --workpath "${KNOWLEDGE_BUILD_DIR}/work" \
        --distpath "${KNOWLEDGE_BUILD_DIR}/dist" \
        "${PROJECT_DIR}/KnowledgeAgent/knowledge-agent.spec"
)

if [ ! -x "${KNOWLEDGE_AGENT_BINARY}" ]; then
    echo "❌ Error: KnowledgeAgent packaging did not produce an executable"
    exit 1
fi

echo "📦 Creating .app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "📋 Copying executable..."
cp "${BUILD_DIR}/AIRecording" "${MACOS_DIR}/${BUNDLE_EXECUTABLE}"
chmod +x "${MACOS_DIR}/${BUNDLE_EXECUTABLE}"

echo "📋 Copying Info.plist..."
# Process Info.plist: replace build variables with actual values.
# We copy the source plist and substitute the SPM/Xcode variables.
INFO_PLIST_SRC="${PROJECT_DIR}/AIRecording/Info.plist"
INFO_PLIST_DST="${CONTENTS_DIR}/Info.plist"

cp "${INFO_PLIST_SRC}" "${INFO_PLIST_DST}"

# Replace variables using sed
sed -i '' "s|\$(DEVELOPMENT_LANGUAGE)|zh-CN|g" "${INFO_PLIST_DST}"
sed -i '' "s|\$(EXECUTABLE_NAME)|${BUNDLE_EXECUTABLE}|g" "${INFO_PLIST_DST}"
sed -i '' "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|${BUNDLE_ID}|g" "${INFO_PLIST_DST}"
sed -i '' "s|\$(PRODUCT_NAME)|${BUNDLE_NAME}|g" "${INFO_PLIST_DST}"
sed -i '' "s|\$(PRODUCT_BUNDLE_PACKAGE_TYPE)|APPL|g" "${INFO_PLIST_DST}"
sed -i '' "s|\$(MACOSX_DEPLOYMENT_TARGET)|${MIN_OS_VERSION}|g" "${INFO_PLIST_DST}"

echo "📋 Copying resources..."
# Copy Assets.xcassets compiled bundle if it exists
BUNDLE_RESOURCES="${BUILD_DIR}/${BUNDLE_EXECUTABLE}_${BUNDLE_EXECUTABLE}.bundle"
if [ -d "${BUNDLE_RESOURCES}" ]; then
    cp -R "${BUNDLE_RESOURCES}" "${RESOURCES_DIR}/"
fi

# Also copy any Resources directory contents
if [ -d "${PROJECT_DIR}/AIRecording/Resources" ]; then
    cp -R "${PROJECT_DIR}/AIRecording/Resources/"* "${RESOURCES_DIR}/" 2>/dev/null || true
fi

# Copy ChartAgent Python service
if [ -d "${PROJECT_DIR}/ChartAgent" ]; then
    cp -R "${PROJECT_DIR}/ChartAgent" "${RESOURCES_DIR}/"
fi

mkdir -p "${RESOURCES_DIR}/KnowledgeAgent"
cp "${KNOWLEDGE_AGENT_BINARY}" "${RESOURCES_DIR}/KnowledgeAgent/knowledge-agent"
chmod +x "${RESOURCES_DIR}/KnowledgeAgent/knowledge-agent"

echo "🩺 Verifying packaged KnowledgeAgent health..."
KNOWLEDGE_VERIFY_DIR="$(mktemp -d /private/tmp/knowledge-agent-verify.XXXXXX)"
KNOWLEDGE_VERIFY_PORT="18766"
KNOWLEDGE_DB_PATH="${KNOWLEDGE_VERIFY_DIR}/knowledge.sqlite" PORT="${KNOWLEDGE_VERIFY_PORT}" \
    "${RESOURCES_DIR}/KnowledgeAgent/knowledge-agent" >"${KNOWLEDGE_VERIFY_DIR}/runtime.log" 2>&1 &
KNOWLEDGE_VERIFY_PID=$!
KNOWLEDGE_HEALTHY=0
for attempt in {1..30}; do
    if curl --silent --fail "http://127.0.0.1:${KNOWLEDGE_VERIFY_PORT}/health" >"${KNOWLEDGE_VERIFY_DIR}/health.json"; then
        if grep -q '"serviceVersion":"1.0.0"' "${KNOWLEDGE_VERIFY_DIR}/health.json"; then
            KNOWLEDGE_HEALTHY=1
        fi
        break
    fi
    sleep 0.2
done
kill "${KNOWLEDGE_VERIFY_PID}" 2>/dev/null || true
wait "${KNOWLEDGE_VERIFY_PID}" 2>/dev/null || true
rm -rf "${KNOWLEDGE_VERIFY_DIR}"
if [ "${KNOWLEDGE_HEALTHY}" -ne 1 ]; then
    echo "❌ Error: packaged KnowledgeAgent health check failed"
    exit 1
fi

echo "🎨 Generating app icon..."
ICON_SRC="${PROJECT_DIR}/Assets/AppIcon-1024.png"
if [ -f "${ICON_SRC}" ]; then
    ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
    rm -rf "${ICONSET_DIR}"
    mkdir -p "${ICONSET_DIR}"
    for size in 16 32 128 256 512; do
        sips -z ${size} ${size} "${ICON_SRC}" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z ${double} ${double} "${ICON_SRC}" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
else
    echo "⚠️  Warning: icon source not found at ${ICON_SRC}, app will have no icon"
fi

echo "🧹 Cleaning extended attribute files (._*) for codesign..."
dot_clean "${APP_BUNDLE}" 2>/dev/null || true
find "${APP_BUNDLE}" -name '._*' -delete 2>/dev/null || true

echo "🔏 Signing app bundle with entitlements..."
ENTITLEMENTS_PLIST="${PROJECT_DIR}/AIRecording/AIRecording.entitlements"
if [ -f "${ENTITLEMENTS_PLIST}" ]; then
    codesign --force --deep --sign - \
        --entitlements "${ENTITLEMENTS_PLIST}" \
        "${APP_BUNDLE}"
else
    echo "⚠️  Warning: entitlements file not found at ${ENTITLEMENTS_PLIST}"
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo ""
echo "✅ Build complete!"
echo "📍 App bundle: ${APP_BUNDLE}"
echo "🔑 Bundle ID:   ${BUNDLE_ID}"
echo ""
echo "🚀 To run:"
echo "   open \"${APP_BUNDLE}\""
echo ""
echo "📋 NOTE: App is installed to /Applications. TCC permissions persist across rebuilds"
echo "   because macOS tracks ad-hoc signed apps by bundle path in /Applications."
echo ""
echo "⚠️  If you see '无法打开因为无法验证开发者', right-click the app icon"
echo "   in Finder and choose 'Open' to bypass Gatekeeper for this build."
echo ""
echo "⚠️  If permissions were previously broken, reset TCC entries before first run:"
echo "   tccutil reset Microphone com.airecording.app"
echo "   tccutil reset ScreenCapture com.airecording.app"
echo "   Then open the app and re-authorize once."
