#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -sm)" == "Darwin arm64" ]] || { echo "需要 Apple Silicon 发布 Mac。" >&2; exit 1; }
for tool in git gh asc openssl python3; do command -v "$tool" >/dev/null; done
gh auth status >/dev/null 2>&1
openssl version | grep -Eq '^OpenSSL (3|4)\.' || { echo "需要 OpenSSL 3 或 4。" >&2; exit 1; }
label=local.folio.tag-publisher
root="$HOME/Library/Application Support/FolioRelease"
agents="$HOME/Library/LaunchAgents"
umask 077
mkdir -p "$root" "$agents"
install -m 700 scripts/tag-release.py "$root/publisher.new"
mv -f "$root/publisher.new" "$root/publisher.py"
plist="$agents/$label.plist"
python3 - "$plist" "$root" "$label" <<'PY'
import os, pathlib, plistlib, shutil, sys
plist, root, label = sys.argv[1:]
paths = [str(pathlib.Path(shutil.which(t)).parent) for t in ("gh","asc","openssl","python3")]
env_path = ":".join(dict.fromkeys(paths + ["/usr/bin","/bin","/usr/sbin","/sbin"]))
config = dict(Label=label, ProgramArguments=[sys.executable,root+"/publisher.py"],
              StartInterval=300, RunAtLoad=True, WorkingDirectory=root,
              EnvironmentVariables=dict(PATH=env_path,GIT_TERMINAL_PROMPT="0",GH_PROMPT_DISABLED="1"),
              StandardErrorPath=root+"/launch-error.log")
path = pathlib.Path(plist)
tmp = path.with_suffix(".new")
tmp.write_bytes(plistlib.dumps(config)); os.replace(tmp,path)
PY
domain="gui/$(id -u)"
if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl bootstrap "$domain" "$plist"
else
  launchctl kickstart "$domain/$label"
fi
echo "本机 tag 发布服务已安装。日志：$root/publisher.log"
