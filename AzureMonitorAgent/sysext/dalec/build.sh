#!/bin/bash
# build.sh -- Build AMA sysext image with DALEC
#
# Usage: ./build.sh <arch> <version> <deb-path> <extension-dir>
#
# Arguments:
#   arch          - x86_64, amd64, arm64, or aarch64
#   version       - AMA version (e.g. 1.41.0)
#   deb-path      - Path to the signed (non-dynamicssl) .deb
#   extension-dir - Directory with extension binaries (amaCoreAgentBin/,
#                   agentLauncherBin/, MetricsExtensionBin/, etc.)
#
# Steps:
#   1. Build an extras .deb from loose extension binaries + shared configs
#   2. Pass both .debs to DALEC via trixie-pkg build context
#   3. DALEC produces an EROFS sysext .raw image
#
# Requirements: Docker (BuildKit), dpkg-deb, gzip, md5sum
#
# Environment:
#   DALEC_TARGET       - Build target (default: trixie/testing/sysext)
#   OUTPUT_DIR         - Output directory (default: .)
#   PREBUILT_DEBS_DIR  - When set, .debs are passed as prebuilt packages.
#                        Otelcollector is skipped in this mode (its postinst
#                        tries to start systemd services in the container).

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ARCH="${1:?Usage: $0 <arch> <version> <deb-path> <extension-dir>}"
VERSION="${2:?}"
DEB_PATH="${3:?}"
EXT_DIR="${4:-.}"

DALEC_TARGET="${DALEC_TARGET:-trixie/testing/sysext}"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR:-.}")"
PREBUILT_DEBS_DIR="${PREBUILT_DEBS_DIR:-}"
TARGET_KEY="${DALEC_TARGET%%/*}"
export DOCKER_BUILDKIT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSEXT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSEXT_NAME="azuremonitoragent"

case "$ARCH" in
    x86-64|x86_64|amd64) ARCH_BIN=x86_64; ARCH_DPKG=amd64; ARCH_SYSEXT=x86-64 ;;
    arm64|aarch64)        ARCH_BIN=aarch64; ARCH_DPKG=arm64; ARCH_SYSEXT=arm64 ;;
    *) echo "ERROR: Unknown arch: $ARCH" >&2; exit 1 ;;
esac

DEB_PATH="$(realpath "$DEB_PATH")"
EXT_DIR="$(realpath "$EXT_DIR")"

[[ -f "$DEB_PATH" ]] || { echo "ERROR: .deb not found: $DEB_PATH" >&2; exit 1; }
[[ -d "$EXT_DIR" ]]  || { echo "ERROR: extension dir not found: $EXT_DIR" >&2; exit 1; }

if [[ -n "${PREBUILT_DEBS_DIR}" ]]; then
    mkdir -p "${PREBUILT_DEBS_DIR}"
    PREBUILT_DEBS_DIR="$(realpath "${PREBUILT_DEBS_DIR}")"
fi

# ---------------------------------------------------------------------------
# Read package metadata from the .deb
# ---------------------------------------------------------------------------

AMA_PKG_NAME=$(dpkg-deb --showformat='${Package}' --show "$DEB_PATH")
AMA_PKG_VERSION=$(dpkg-deb --showformat='${Version}' --show "$DEB_PATH")

# ---------------------------------------------------------------------------
# Otelcollector .deb (optional)
# ---------------------------------------------------------------------------

OTEL_DEB=$(find "${EXT_DIR}/azureotelcollector/" -maxdepth 1 \
    -name "azureotelcollector_*_${ARCH_DPKG}.deb" 2>/dev/null | head -1)
OTEL_PKG_NAME=""

if [[ -n "${OTEL_DEB}" ]]; then
    OTEL_PKG_NAME=$(dpkg-deb --showformat='${Package}' --show "$OTEL_DEB")
fi

# In local mode, skip otelcollector -- its postinst tries to start
# systemd services which fails inside the DALEC build container.
if [[ -n "${PREBUILT_DEBS_DIR}" && -n "${OTEL_DEB}" ]]; then
    echo "NOTE: Skipping otelcollector in prebuilt-debs (local) mode"
    OTEL_DEB=""
    OTEL_PKG_NAME=""
fi

echo "=== AMA Sysext Build (DALEC): v${VERSION}/${ARCH_BIN} ==="
echo "    ama deb:   $DEB_PATH (${AMA_PKG_NAME} ${AMA_PKG_VERSION})"
if [[ -n "${OTEL_PKG_NAME}" ]]; then
    echo "    otel deb:  $OTEL_DEB (${OTEL_PKG_NAME})"
else
    echo "    otel deb:  (not found -- skipping)"
fi
echo "    ext dir:   $EXT_DIR"
echo "    target:    $DALEC_TARGET"
echo "    output:    $OUTPUT_DIR"
echo ""

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------

WORKDIR=$(mktemp -d)
REPO_IMAGE=""
cleanup() {
    rm -rf "$WORKDIR"
    if [[ -n "${REPO_IMAGE}" ]]; then
        docker rmi "${REPO_IMAGE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Build extras .deb (extension binaries + shared configs)
# ---------------------------------------------------------------------------

echo "--- Building extras .deb ---"

EXTRAS="${WORKDIR}/extras"
EXTRAS_BIN="${EXTRAS}/opt/microsoft/azuremonitoragent/bin"

mkdir -p "${EXTRAS_BIN}"
mkdir -p "${EXTRAS}/usr/lib/sysusers.d"
mkdir -p "${EXTRAS}/usr/lib/tmpfiles.d"

# --- 1a: Extension binaries ---

if [[ -f "${EXT_DIR}/amaCoreAgentBin/amacoreagent_${ARCH_BIN}" ]]; then
    cp "${EXT_DIR}/amaCoreAgentBin/amacoreagent_${ARCH_BIN}" "${EXTRAS_BIN}/amacoreagent"
    echo "    Added amacoreagent"
fi

if [[ "${ARCH_BIN}" == "x86_64" ]] && [[ -f "${EXT_DIR}/amaCoreAgentBin/liblz4x64.so" ]]; then
    cp "${EXT_DIR}/amaCoreAgentBin/liblz4x64.so" "${EXTRAS_BIN}/"
    echo "    Added liblz4x64.so"
fi

if [[ -f "${EXT_DIR}/agentLauncherBin/agentlauncher_${ARCH_BIN}" ]]; then
    cp "${EXT_DIR}/agentLauncherBin/agentlauncher_${ARCH_BIN}" "${EXTRAS_BIN}/agentlauncher"
    echo "    Added agentlauncher"
fi

if [[ -f "${EXT_DIR}/MetricsExtensionBin/metricsextension_${ARCH_BIN}" ]]; then
    cp "${EXT_DIR}/MetricsExtensionBin/metricsextension_${ARCH_BIN}" "${EXTRAS_BIN}/MetricsExtension"
    echo "    Added MetricsExtension"
fi

if [[ "${ARCH_BIN}" == "x86_64" ]] && [[ -d "${EXT_DIR}/AstExtensionBin" ]]; then
    mkdir -p "${EXTRAS_BIN}/astextension"
    cp -a "${EXT_DIR}/AstExtensionBin/"* "${EXTRAS_BIN}/astextension/" 2>/dev/null || true
    echo "    Added AstExtension (x86_64 only)"
fi

# --- 1b: Set executable permissions ---

find "${EXTRAS_BIN}" -type f -exec chmod 755 {} \;

# --- 1c: Shared config files ---

cp "${SYSEXT_DIR}/azuremonitoragent.tmpfiles" \
    "${EXTRAS}/usr/lib/tmpfiles.d/azuremonitoragent.conf"
cp "${SYSEXT_DIR}/azuremonitoragent.sysusers" \
    "${EXTRAS}/usr/lib/sysusers.d/azuremonitoragent.conf"
echo "    Added sysusers.d + tmpfiles.d"

# --- 1d: Create the .deb ---

EXTRAS_PKG_NAME="${SYSEXT_NAME}-extras"

mkdir -p "${EXTRAS}/DEBIAN"
cat > "${EXTRAS}/DEBIAN/control" <<EOF
Package: ${EXTRAS_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH_DPKG}
Maintainer: ama-flatcar@microsoft.com
Description: AMA sysext extras (extension binaries + shared configs)
EOF

dpkg-deb --build "${EXTRAS}" "${WORKDIR}/${EXTRAS_PKG_NAME}.deb" >/dev/null
echo "    Created ${EXTRAS_PKG_NAME}.deb"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Create local apt repo
# ---------------------------------------------------------------------------

echo "--- Creating apt repo ---"

REPO="${WORKDIR}/repo"
mkdir -p "${REPO}"
cp "${DEB_PATH}" "${REPO}/"
cp "${WORKDIR}/${EXTRAS_PKG_NAME}.deb" "${REPO}/"

# Add otelcollector .deb if present
if [[ -n "${OTEL_DEB}" ]]; then
    cp "${OTEL_DEB}" "${REPO}/"
    echo "    Added ${OTEL_PKG_NAME} as direct DALEC dependency"
fi

# Generate Packages index (DALEC needs Package, Version, Arch, Filename, Size, MD5sum)
generate_pkg_entry() {
    local deb_file="$1"
    local filename
    filename=$(basename "${deb_file}")

    local meta
    meta=$(dpkg-deb --showformat='${Package}\t${Version}\t${Architecture}' --show "${deb_file}")
    local pkg_name pkg_version pkg_arch
    IFS=$'\t' read -r pkg_name pkg_version pkg_arch <<< "${meta}"

    local size md5
    size=$(stat -c%s "${deb_file}")
    md5=$(md5sum "${deb_file}" | cut -d' ' -f1)

    cat <<EOF
Package: ${pkg_name}
Version: ${pkg_version}
Architecture: ${pkg_arch}
Filename: ./${filename}
Size: ${size}
MD5sum: ${md5}
Description: ${pkg_name}
EOF
    echo ""
}

# Write entries for all .debs
> "${REPO}/Packages"
for deb in "${REPO}"/*.deb; do
    generate_pkg_entry "${deb}" >> "${REPO}/Packages"
done

gzip "${REPO}/Packages"

if [[ -n "${PREBUILT_DEBS_DIR}" ]]; then
    echo "--- Populating prebuilt debs dir ---"
    mkdir -p "${PREBUILT_DEBS_DIR}"
    cp "${REPO}"/*.deb "${PREBUILT_DEBS_DIR}/"
    echo "    Prebuilt debs: $(ls -1 "${PREBUILT_DEBS_DIR}"/*.deb 2>/dev/null | wc -l)"
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 2b: Build repo as a Docker image
# Workaround: DALEC/BuildKit directory contexts turn files into dirs.
# A docker-image context preserves file types correctly.
# ---------------------------------------------------------------------------

echo "--- Packaging repo as Docker image ---"

REPO_IMAGE="dalec-ama-repo-$$"
docker build -q -t "${REPO_IMAGE}" -f - "${REPO}" <<'REPOEOF'
FROM scratch
COPY . /
REPOEOF

echo "    Image: ${REPO_IMAGE}"

PKG_COUNT=$(find "${REPO}" -name '*.deb' | wc -l)
echo "    Repo: ${PKG_COUNT} packages"
echo "    - ${AMA_PKG_NAME} (signed .deb, passed directly)"
echo "    - ${EXTRAS_PKG_NAME} (extension binaries + configs)"
if [[ -n "${OTEL_PKG_NAME}" ]]; then
    echo "    - ${OTEL_PKG_NAME} (otelcollector .deb, passed directly)"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: Prepare DALEC YAML
# ---------------------------------------------------------------------------

DALEC_YAML="${WORKDIR}/azuremonitoragent.yml"
cp "${SCRIPT_DIR}/azuremonitoragent.yml" "${DALEC_YAML}"

# ---------------------------------------------------------------------------
# Step 4: DALEC build
# ---------------------------------------------------------------------------

echo "--- Running DALEC build ---"

DOCKER_BUILD_ARGS=(
    --build-arg "VERSION=${VERSION}"
)

DOCKER_BUILD_CONTEXTS=(--build-context "repo=docker-image://${REPO_IMAGE}")
if [[ -n "${PREBUILT_DEBS_DIR}" ]]; then
    DOCKER_BUILD_CONTEXTS+=(--build-context "${TARGET_KEY}-pkg=${PREBUILT_DEBS_DIR}")
    DOCKER_BUILD_CONTEXTS+=(--build-context "pkg=${PREBUILT_DEBS_DIR}")
fi

docker build \
    --progress=plain \
    -f "${DALEC_YAML}" \
    "${DOCKER_BUILD_ARGS[@]}" \
    "${DOCKER_BUILD_CONTEXTS[@]}" \
    --target "${DALEC_TARGET}" \
    --output "type=local,dest=${OUTPUT_DIR}" \
    "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Step 5: Output summary
# ---------------------------------------------------------------------------

RAW=$(find "$OUTPUT_DIR" -maxdepth 1 -name 'azuremonitoragent*.raw' -print -quit)
if [[ -n "$RAW" ]]; then
    # Rename to the format install_via_sysext() expects:
    #   azuremonitoragent-v{VERSION}-{ARCH_SYSEXT}.raw
    EXPECTED_NAME="${SYSEXT_NAME}-v${VERSION}-${ARCH_SYSEXT}.raw"
    if [[ "$(basename "$RAW")" != "${EXPECTED_NAME}" ]]; then
        mv "$RAW" "${OUTPUT_DIR}/${EXPECTED_NAME}"
        RAW="${OUTPUT_DIR}/${EXPECTED_NAME}"
        echo "    Renamed to ${EXPECTED_NAME}"
    fi

    sha256sum "$RAW" > "${OUTPUT_DIR}/SHA256SUMS.azuremonitoragent"

    PACKAGES="${AMA_PKG_NAME} + ${EXTRAS_PKG_NAME}"
    if [[ -n "${OTEL_PKG_NAME}" ]]; then
        PACKAGES="${PACKAGES} + ${OTEL_PKG_NAME}"
    fi

    echo ""
    echo "==========================================="
    echo " SUCCESS"
    echo "==========================================="
    echo " Image:    $(basename "$RAW")"
    echo " Size:     $(du -h "$RAW" | cut -f1)"
    echo " SHA256:   $(cut -d' ' -f1 "${OUTPUT_DIR}/SHA256SUMS.azuremonitoragent")"
    echo ""
    echo " Build:    DALEC (EROFS)"
    echo " Packages: ${PACKAGES}"
    echo " Target:   ${DALEC_TARGET}"
    echo "==========================================="
else
    echo "ERROR: No .raw output found" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Verify sysext EROFS content
# DALEC tests only check the build container. This mounts the actual
# .raw image and checks extension-release, /etc relocation, C+ tmpfiles.
# ---------------------------------------------------------------------------

echo ""
echo "--- Verifying sysext EROFS content ---"

VERIFY_MNT="${WORKDIR}/verify-mnt"
mkdir -p "${VERIFY_MNT}"
VERIFY_FAIL=0

# Mount the EROFS image. Skip if mount fails (no root or no erofs support).
if mount -o loop,ro -t erofs "$RAW" "${VERIFY_MNT}" 2>/dev/null; then
    # Unmount on exit
    trap 'umount "${VERIFY_MNT}" 2>/dev/null || true; rm -rf "$WORKDIR"; if [[ -n "${REPO_IMAGE}" ]]; then docker rmi "${REPO_IMAGE}" 2>/dev/null || true; fi' EXIT

    # 1. extension-release metadata
    ER="${VERIFY_MNT}/usr/lib/extension-release.d/extension-release.${SYSEXT_NAME}"
    if [[ -f "$ER" ]]; then
        if grep -q "ID=_any" "$ER" && grep -q "EXTENSION_RELOAD_MANAGER=1" "$ER"; then
            echo "  [OK] extension-release.${SYSEXT_NAME}"
        else
            echo "  [FAIL] extension-release.${SYSEXT_NAME}: missing expected fields"
            cat "$ER"
            VERIFY_FAIL=1
        fi
    else
        echo "  [FAIL] extension-release.${SYSEXT_NAME}: not found"
        VERIFY_FAIL=1
    fi

    # 2. DALEC-generated C+ tmpfiles (from /etc content in debs)
    CT="${VERIFY_MNT}/usr/lib/tmpfiles.d/10-${SYSEXT_NAME}.conf"
    if [[ -f "$CT" ]]; then
        if grep -q "C+" "$CT"; then
            echo "  [OK] 10-${SYSEXT_NAME}.conf (C+ tmpfiles)"
        else
            echo "  [FAIL] 10-${SYSEXT_NAME}.conf: no C+ entries"
            cat "$CT"
            VERIFY_FAIL=1
        fi
    else
        echo "  [FAIL] 10-${SYSEXT_NAME}.conf: not found (no /etc relocation)"
        VERIFY_FAIL=1
    fi

    # 3. Relocated config templates (/etc -> /usr/share/<name>/etc)
    for cfg in etc/opt/microsoft/azuremonitoragent/mdsd.xml \
               etc/opt/microsoft/azuremonitoragent/mdsautokey.cfg; do
        relocated="${VERIFY_MNT}/usr/share/${SYSEXT_NAME}/${cfg}"
        base=$(basename "$cfg")
        if [[ -f "$relocated" ]]; then
            echo "  [OK] relocated config: ${base}"
        else
            echo "  [FAIL] relocated config: ${base} not found at usr/share/${SYSEXT_NAME}/${cfg}"
            VERIFY_FAIL=1
        fi
    done

    # 4. Core binaries (sanity check)
    for bin in opt/microsoft/azuremonitoragent/bin/mdsd \
               opt/microsoft/azuremonitoragent/bin/mdsdmgr; do
        if [[ -f "${VERIFY_MNT}/${bin}" ]]; then
            echo "  [OK] binary: $(basename "$bin")"
        else
            echo "  [FAIL] binary: $(basename "$bin") not found"
            VERIFY_FAIL=1
        fi
    done

    umount "${VERIFY_MNT}" 2>/dev/null || true
    # Restore original trap
    trap 'rm -rf "$WORKDIR"; if [[ -n "${REPO_IMAGE}" ]]; then docker rmi "${REPO_IMAGE}" 2>/dev/null || true; fi' EXIT

    if [[ "$VERIFY_FAIL" -ne 0 ]]; then
        echo ""
        echo "ERROR: EROFS sysext content verification failed" >&2
        exit 1
    fi
    echo ""
    echo "  All EROFS content checks passed."
else
    echo "  [WARN] Cannot mount EROFS image (no root or no erofs support) -- skipping verification"
    echo "     The .raw image was produced but its content was not verified."
fi
