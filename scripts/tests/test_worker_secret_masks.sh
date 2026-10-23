#!/usr/bin/env bash
# Real bwrap checks using dummy credentials and fake provider CLIs. No model calls.
set -euo pipefail
TEST_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fixture="$(mktemp -d "${TEST_SOURCE_ROOT}/.worker-secret-test.XXXXXX")"
trap 'rm -rf -- "${fixture}"' EXIT
export CORTEX_DIR="${fixture}" AGENT_ID=secret-test
export TEST_SOURCE_ROOT
mkdir -p "${fixture}/agents/conductor/secrets" "${fixture}/agents/${AGENT_ID}" "${fixture}/bin" "${fixture}/stage"
printf 'dummy credential\n' > "${fixture}/agents/conductor/secrets/signal.env"
printf 'dummy credential\n' > "${fixture}/agents/conductor/secrets/telegram.env"
printf 'ordinary fixture\n' > "${fixture}/ordinary.txt"
cat > "${fixture}/bin/codex" <<'CLI'
#!/bin/bash
set -eu
python3 - <<'PROBE'
import os
from pathlib import Path
root = Path(os.environ['CORTEX_DIR'])
paths = [root/'agents/conductor/secrets', root/'outside-secrets']
for directory in paths:
    for name in ['signal.env', 'telegram.env']:
        try:
            fd = os.open(directory/name, os.O_RDONLY)
        except (FileNotFoundError, PermissionError):
            continue
        os.close(fd)
        raise SystemExit('FAIL: dummy credential could be opened')
assert (root/'ordinary.txt').read_text().strip() == 'ordinary fixture'
if os.environ.get('TEST_NODE_READ_ONLY') == '1':
    try:
        (root/'ordinary.txt').write_text('unexpected write')
    except (OSError, PermissionError):
        pass
    else:
        raise SystemExit('FAIL: node checkout is writable')
else:
    (root/'agents'/os.environ['AGENT_ID']/'probe-result.txt').write_text('ok')
print('dummy credential opens blocked; ordinary read and own-dir write work')
PROBE
CLI
chmod +x "${fixture}/bin/codex"
ln -s codex "${fixture}/bin/claude"
export PATH="${fixture}/bin:${PATH}"
source "${TEST_SOURCE_ROOT}/scripts/bash_compat.sh"
source "${TEST_SOURCE_ROOT}/roles/sandbox.sh"
source "${TEST_SOURCE_ROOT}/roles/node.sh"
source "${TEST_SOURCE_ROOT}/roles/worker.common.sh"
source "${TEST_SOURCE_ROOT}/roles/framework/worker.security.sh"
source "${TEST_SOURCE_ROOT}/roles/framework/worker.efficiency.sh"
source "${TEST_SOURCE_ROOT}/roles/operational/worker.compressor.sh"
# Bind only system executables and the dummy checkout; never real credentials.
security_bwrap_ro_binds() {
    named_array_clear "$3"
    local system_path
    for system_path in /usr /bin /lib /lib64 /etc; do
        append_ro_bind_if_exists "${system_path}" "$3"
    done
    named_array_append "$3" --ro-bind "${CORTEX_DIR}" "${CORTEX_DIR}"
}
# Exercise broad RO/RW overlays as well as the custom read-only launchers.
worker_pre_rw_ro_base() { named_array_append "$1" --ro-bind "${CORTEX_DIR}" "${CORTEX_DIR}"; }
worker_bwrap_rw_binds() { named_array_append "$2" --bind "${CORTEX_DIR}" "${CORTEX_DIR}"; }
worker_post_rw_ro_binds() { named_array_clear "$1"; }
worker_ro_masks() { named_array_clear "$1"; }
worker_append_ssh_binds() { named_array_clear "$1"; }
worker_bwrap_pid_args() { named_array_append "$1" --unshare-pid; }
worker_bwrap_device_args() { security_bwrap_device_args "$1"; }
prepare_codex_stage_home() { printf '%s' "${fixture}/stage"; }
cleanup_codex_stage_home() { :; }
start_codex_stage_scrubber() { :; }
security_claude_usage_stage_bind() { named_array_clear "$2"; }
worker_claude_pin_session() { :; }
# No timeout prefix is needed for these finite dummy probes. Capture the actual
# argv to assert masks follow every bind, then execute real bwrap unchanged.
run_with_array_prefix() {
    shift
    printf '%s\0' "$@" > "${fixture}/argv"
    "$@"
}
cortex_usage_new_claude_session_id() { :; }
CLAUDE_EFFORT=medium
CLAUDE_MODEL=dummy
CODEX_MODEL=dummy
CODEX_REASONING_EFFORT=medium
timeout_cmd=()
launchers=(worker_launch_codex_generic worker_launch_claude_generic worker_security_launch_codex worker_security_launch_claude worker_efficiency_launch_codex worker_compressor_launch_codex worker_compressor_launch_claude node_run_provider_cli)
for layout in directory symlink; do
    if [[ "${layout}" == symlink ]]; then
        mv "${fixture}/agents/conductor/secrets" "${fixture}/outside-secrets"
        ln -s "${fixture}/outside-secrets" "${fixture}/agents/conductor/secrets"
    fi
    for launcher in "${launchers[@]}"; do
        export TEST_NODE_READ_ONLY=0
        if [[ "${launcher}" == node_run_provider_cli ]]; then
            export TEST_NODE_READ_ONLY=1
            AGENT_PROVIDER=claude
            "${launcher}" probe "${fixture}/working" "${fixture}/out" "${fixture}/last" timeout_cmd >"${fixture}/probe.log" 2>&1 || { cat "${fixture}/probe.log"; exit 1; }
        elif [[ "${launcher}" == *claude* ]]; then
            "${launcher}" probe "${fixture}/working" "${fixture}/out" timeout_cmd >"${fixture}/probe.log" 2>&1 || { cat "${fixture}/probe.log"; exit 1; }
        else
            "${launcher}" probe "${fixture}/working" "${fixture}/out" "${fixture}/last" timeout_cmd >"${fixture}/probe.log" 2>&1 || { cat "${fixture}/probe.log"; exit 1; }
        fi
        python3 - "${fixture}/argv" <<'ORDER'
from pathlib import Path
import sys
args = Path(sys.argv[1]).read_bytes().decode().split('\0')[:-1]
last_bind = max(i for i, value in enumerate(args) if value in ('--bind', '--ro-bind', '--dev-bind'))
masks = [i for i, value in enumerate(args) if value == '--tmpfs' and args[i+1].endswith(('/secrets', '/outside-secrets'))]
assert masks and min(masks) > last_bind, 'credential masks must follow all binds'
ORDER
        # Worker namespaces must not remove the host-side files used by watch.
        [[ -r "${fixture}/agents/conductor/secrets/signal.env" ]]
        [[ -r "${fixture}/agents/conductor/secrets/telegram.env" ]]
        printf 'PASS: %s (%s)\n' "${launcher}" "${layout}"
    done
done
printf 'PASS: all 16 sandbox credential-isolation probes\n'
