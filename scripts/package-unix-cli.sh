#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-dist}"
LAUNCHER_NAME="${2:-NetRay-Compile}"
ASSET_NAME="${3:-NetRay-Compile-linux-x86_64.zip}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_PATH="${REPO_ROOT}/${OUTPUT_DIR}"
PAYLOAD_DIR="${OUTPUT_PATH}/unix-payload"
PAYLOAD_ARCHIVE="${OUTPUT_PATH}/unix-payload.tar.gz"
LAUNCHER_PATH="${OUTPUT_PATH}/${LAUNCHER_NAME}"
ASSET_PATH="${OUTPUT_PATH}/${ASSET_NAME}"
LUNE_PATH="$(find "${HOME}/.rokit/tool-storage/lune-org/lune" -type f -name lune | sort | tail -n 1)"

mkdir -p "${OUTPUT_PATH}"
rm -rf "${PAYLOAD_DIR}"
mkdir -p "${PAYLOAD_DIR}/cli"

cp "${LUNE_PATH}" "${PAYLOAD_DIR}/lune"
cp "${REPO_ROOT}/cli/netray.luau" "${PAYLOAD_DIR}/cli/netray.luau"
cp -R "${REPO_ROOT}/src" "${PAYLOAD_DIR}/src"
chmod +x "${PAYLOAD_DIR}/lune"

rm -f "${PAYLOAD_ARCHIVE}"
tar -czf "${PAYLOAD_ARCHIVE}" -C "${PAYLOAD_DIR}" .

BASE64_PAYLOAD="$(base64 < "${PAYLOAD_ARCHIVE}")"

cat > "${LAUNCHER_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

decode_base64() {
    if base64 --help >/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

SELF="\${BASH_SOURCE[0]}"
PAYLOAD_LINE=\$(awk '/^__NETRAY_PAYLOAD_BELOW__\$/{print NR + 1; exit 0}' "\${SELF}")
if [[ -z "\${PAYLOAD_LINE}" ]]; then
    echo "Missing embedded payload." >&2
    exit 1
fi

WORKDIR="\$(mktemp -d "\${TMPDIR:-/tmp}/netray-cli.XXXXXX")"
cleanup() {
    rm -rf "\${WORKDIR}"
}
trap cleanup EXIT

tail -n +"\${PAYLOAD_LINE}" "\${SELF}" | decode_base64 > "\${WORKDIR}/payload.tar.gz"
tar -xzf "\${WORKDIR}/payload.tar.gz" -C "\${WORKDIR}"
chmod +x "\${WORKDIR}/lune"
exec "\${WORKDIR}/lune" run "\${WORKDIR}/cli/netray.luau" "\$@"
__NETRAY_PAYLOAD_BELOW__
${BASE64_PAYLOAD}
EOF

chmod +x "${LAUNCHER_PATH}"
rm -f "${ASSET_PATH}"
zip -j "${ASSET_PATH}" "${LAUNCHER_PATH}" >/dev/null

echo "Packaged Unix CLI asset at ${ASSET_PATH}"
