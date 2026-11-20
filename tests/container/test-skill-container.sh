#!/bin/bash
# test-skill-container.sh — contrib/container/skill-container offline: a fake
# `podman` keeps secrets as files, records every call and stands in for the
# client's container; a fake `opencode` answers `secrets` alone; openQA reads
# a made-up client config with several hosts. The launcher's own commands come
# from $tools/bin, where each real one is wrapped to check what it is given,
# the caller's opencode from $tools/userbin on the caller's PATH, whose first
# directory holds commands that must never run. Exit 0 = all assertions hold.
# With SKILL_CONTAINER_TEST_STRICT=1 a case this host cannot run fails instead of printing SKIP.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
# shellcheck disable=SC2016  # the fake commands written here expand their own variables
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SC="$HERE/../../contrib/container/skill-container"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
	printf 'FAIL: %s\n' "$*"
	fails=$((fails + 1))
}
skip() { if [ "${SKILL_CONTAINER_TEST_STRICT-}" = 1 ]; then fail "$* (SKILL_CONTAINER_TEST_STRICT=1)"; else echo "SKIP: $*"; fi; }
[ -x "$SC" ] && pass "the launcher is executable" || fail "the launcher is not executable"
# install refuses a work directory under /var: the temporary ones lie below /tmp.
case ${TMPDIR-}/ in
/tmp/?*) ;;
*) export TMPDIR=/tmp ;;
esac
# The commands live outside $work: a work directory that holds one is refused.
work="$(mktemp -d)"
tools="$(mktemp -d)"
open="$(mktemp -d)"
vtmp="$(mktemp -d -p /var/tmp)"
trap 'rm -rf "$work" "$tools" "$open" "$vtmp"' EXIT
FIX="$work/fix"
export FIX
N=openqa

mkdir -p "$tools/bin" "$tools/userbin" "$tools/evilbin" "$FIX/secrets" "$FIX/store/volumes" "$work/home/.config" \
	"$work/ws/bin" "$work/a,b" "$work/a:b" \
	"$work/planted" "$work/config/openqa" "$work/config/mcp-bugzilla" "$work/run/sub"
ln -s home "$work/homelink"
ln -s "$work/ws/bin" "$tools/wslink"
# A link the agent could repoint: it lies in the work directory and leads out of it.
ln -s "$tools/userbin" "$work/ws/pathlink"
touch "$work/stamp"
# Sourced by every fake and wrapper: no command starts in the work directory,
# and none has a login or the server password in its environment or arguments.
cat >"$FIX/envcheck" <<'EOF'
case "$PWD/" in
"${FIX%/fix}/ws"/*) printf '%s\n' "${0##*/}" >> "$FIX/cwd-leak" ;;
esac
case "$(/usr/bin/env) $*" in
*SECRET[-_][0-9]* | *OQASECRET[0-9]*) printf '%s\n' "${0##*/}" >> "$FIX/secret-leak" ;;
esac
for _f in "$FIX"/secrets/*-server-password; do
  [ -s "$_f" ] || continue
  _pw=$(< "$_f")
  # Empty while `up` replaces it.
  [ -n "$_pw" ] || continue
  case "$(/usr/bin/env) $*" in
  *"$_pw"*) printf '%s\n' "${0##*/}" >> "$FIX/env-leak" ;;
  esac
done
EOF
# Every control character the filter drops, between two marks: the C0 set
# without tab and newline, DEL, and the C1 set as UTF-8. Builtins only.
cat >"$FIX/ctl" <<'EOF'
ctl() {
  local i o
  printf 'ctl<'
  for i in {0..8} {11..31} 127; do printf -v o '\\%03o' "$i"; printf "$o"; done
  for i in {128..159}; do printf -v o '\\302\\%03o' "$i"; printf "$o"; done
  printf '>\n'
}
EOF
cat >"$tools/bin/podman" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
PATH=/usr/bin:/bin
printf '%s\n' "$*" >> "$FIX/podman-calls"
case "$1 $2" in
"secret create")
  [ "$3" = --replace ] || exit 98
  if [ "$5" = - ]; then cat > "$FIX/secrets/$4"; else cp "$5" "$FIX/secrets/$4"; fi ;;
"secret exists") [ -f "$FIX/secrets/$3" ] ;;
"secret inspect") cat "$FIX/secrets/${!#}"; echo ;;
"info --format") case $3 in *VolumePath*) cat "$FIX/volpath" ;; *) cat "$FIX/storepath" ;; esac ;;
# Two other containers run when $FIX/others names what they write on the host.
"ps --quiet") [ ! -e "$FIX/ps-fails" ] || exit 1; [ ! -s "$FIX/others" ] || printf '%s\n' beef01 beef02 ;;
"run --detach")
  while [ $# -gt 1 ]; do
    [ "$1" = --workdir ] && printf %s "$2" > "$FIX/workdir"
    shift
  done
  # With $FIX/run-fails podman makes the container and cannot start it.
  [ ! -e "$FIX/run-fails" ] || exit 125
  # With $FIX/stops the container exits at once.
  [ -e "$FIX/stops" ] || echo true > "$FIX/running"
  echo c0ffee ;;
# The client's container: whether it got a terminal, and what a client prints.
"run --rm")
  # The memory seed: cp -n keeps what a volume already holds.
  case "$*" in
  *"test -e /seed/"*) [ -e "$FIX/seed-exists" ]; exit ;;
  *"cp -n /src/"* | *"cp /src/"*)
    printf '%s\n' "$*" >> "$FIX/seed-calls"
    : > "$FIX/seeded"
    [ ! -e "$FIX/seed-fails" ]; exit ;;
  *)
    printf '%s\n' "$*" >> "$FIX/client-calls"
    ;;
  esac
  t=no; [ -t 0 ] && [ -t 1 ] && t=yes
  echo "$t" > "$FIX/client-tty"
  # A reply that tries the terminal: clipboard, title, clear, a C1 control, a
  # colour made of the filter's own marker.
  if [ -e "$FIX/escapes" ]; then
    printf 'out\033]52;c;QUJD\007\033[31mred\033[0m\033[2J\302\233x\001[35m'
    # C1 controls that are whole only once the one inside them is taken out.
    printf '\302\302\233\2332Jy\302\302\235\2350;t\302\302\234\234\r\n'
    printf 'err\033]0;title\007\033[1mbold\033[0m\n' >&2
    . "$FIX/ctl"
    ctl
    ctl >&2
    exit 7
  fi ;;
"inspect --format")
  case $3 in
  *Running*) cat "$FIX/running" ;;
  *WorkingDir*) cat "$FIX/workdir" ;;
  *Image*) cat "$FIX/image" ;;
  # What a container writes on the host, as podman prints it for this format alone.
  *"{{.Name}}|"*)
    [ "$3" = '{{.Name}}|{{range .Mounts}}{{if .RW}}|{{.Source}}{{end}}{{end}}' ] \
      && [ "$4" = beef01 ] && [ "$5" = beef02 ] && [ $# = 5 ] || exit 97
    srcs=$(tr '\n' '|' < "$FIX/others")
    if [ -e "$FIX/own-name" ]; then printf '/%s|%s\n' "$(cat "$FIX/own-name")" "$srcs"
    else printf '/beef01|%s\n/beef02|%s\n' "$srcs" "$srcs"; fi ;;
  # The networks the running containers share the server with, as name and mode.
  *HostConfig.NetworkMode*) [ ! -e "$FIX/modes-fails" ] || exit 1; cat "$FIX/netmode" ;;
  # The server's id, by which podman names it in a client's network mode.
  '{{.Id}}') [ ! -e "$FIX/id-fails" ] || exit 1; cat "$FIX/ctr-id" ;;
  esac ;;
# The image a name stands for now: the running one unless a newer was pulled.
"image inspect") if [ -e "$FIX/image-new" ]; then cat "$FIX/image-new"; else cat "$FIX/image"; fi ;;
"pull"*)
  printf '%s\n' "$*" >> "$FIX/pull-calls"
  [ ! -e "$FIX/pull-fails" ] ;;
"exec "*)
  # Every call into the container is one the launcher bounds in time.
  [ -n "${FAKE_TIMEOUT-}" ] || printf '%s\n' "$*" >> "$FIX/untimed"
  # With $FIX/exec-escape whatever runs in the container tries the terminal on its error stream.
  [ ! -e "$FIX/exec-escape" ] || printf 'inside says\033]52;c;QUFB\007\033[2J\n' >&2
  case "$*" in
  *"auth import"*) cat > "$FIX/imported"; [ ! -e "$FIX/import-fails" ] ;;
  # A session the container imports from a pipe: stdin is the export.
  *"session import"*)
    cat > "$FIX/imported-session"
    [ ! -e "$FIX/import-fails" ] ;;
  # The model logins the state volume keeps; the answer holds their keys.
  # A client that repeats the answer on its error stream is the worst case.
  # With $FIX/logins-next the next answer differs.
  *"api GET /api/credential "*) cat "$FIX/logins"; cat "$FIX/logins" >&2
    [ ! -e "$FIX/logins-next" ] || mv "$FIX/logins-next" "$FIX/logins" ;;
  *"api DELETE /api/credential/"*)
    all="$*"; id=${all#*/api/credential/}; id=${id%% *}
    # With $FIX/login-stays the server refuses.
    [ ! -e "$FIX/login-stays" ] || exit 1
    # With $FIX/login-ghost it answers as the real one does for a login it does not hold.
    [ ! -e "$FIX/login-ghost" ] || exit 0
    jq -c --arg id "$id" '.data |= map(select(.id != $id))' "$FIX/logins" > "$FIX/logins.new" \
      && mv "$FIX/logins.new" "$FIX/logins" ;;
  # The readiness check. With $FIX/silent the server never answers; $FIX/answers-after
  # holds how many calls it misses first.
  *"api GET /api/project "*)
    printf '%s\n' "$*" >> "$FIX/project-calls"
    if [ -e "$FIX/silent" ]; then echo "error: connect ECONNREFUSED 127.0.0.1:4096" >&2; exit 1; fi
    if [ -s "$FIX/answers-after" ]; then
      left=$(cat "$FIX/answers-after"); echo $((left - 1)) > "$FIX/answers-after"
      [ "$left" -le 0 ] || { echo "error: connect ECONNREFUSED 127.0.0.1:4096" >&2; exit 1; }
    fi
    cat "$FIX/projects" ;;
  # The approvals of the server's project, of every project (an empty id), or
  # of the one named. What is no list is answered as it is.
  *"api GET /api/permission/saved"[?\ ]*)
    all="$*"
    if ! jq -e '.data | type == "array"' "$FIX/saved" > /dev/null 2>&1; then cat "$FIX/saved"
    elif [[ $all != *"saved?projectID="* ]]; then jq -c '.data |= map(select(.projectID == "prj_main"))' "$FIX/saved"
    else
      id=${all#*projectID=}; id=${id%% *}
      if [ -z "$id" ]; then
        # With $FIX/empty-lists-none the server knows no such question.
        if [ -e "$FIX/empty-lists-none" ]; then echo '{"data":[]}'; else cat "$FIX/saved"; fi
      # With $FIX/id-answers-nothing a project's own list does not come.
      elif [ ! -e "$FIX/id-answers-nothing" ]; then
        jq -c --arg p "$id" '.data |= map(select(.projectID == $p))' "$FIX/saved"
      fi
    fi ;;
  *"api DELETE /api/permission/saved/"*)
    all="$*"; id=${all#*/api/permission/saved/}; id=${id%% *}
    # With $FIX/keeps the server answers and removes nothing.
    [ -e "$FIX/keeps" ] || { jq -c --arg id "$id" '.data |= map(select(.id != $id))' "$FIX/saved" \
      > "$FIX/saved.new" && mv "$FIX/saved.new" "$FIX/saved"; } ;;
  # The session list, two to a page whatever the limit; the cursor is the offset
  # and never null. What is no list is answered as it is.
  *"api GET /api/session?limit=1000"*)
    all="$*"; off=0
    [[ $all != *"cursor="* ]] || { off=${all#*cursor=}; off=${off%%[& ]*}; }
    next=$((off + 2)); [ ! -e "$FIX/bad-cursor" ] || next="$next&directory=/x"
    # With $FIX/endless the list never ends.
    if [ -e "$FIX/endless" ]; then
      printf '{"data":[{"id":"ses_x","permissions":null}],"cursor":{"next":"%s"}}\n' "$next"
    elif jq -e 'type == "array"' "$FIX/sessions" > /dev/null; then
      jq -c --argjson o "$off" --arg n "$next" '{data: .[$o:$o + 2], cursor: {next: $n}}' "$FIX/sessions"
    else cat "$FIX/sessions"; fi ;;
  *"api PATCH /api/session/"*)
    all="$*"; id=${all#*/api/session/}; id=${id%% *}
    [[ $all == *' -d {"permissions":[]} '* ]] || exit 96
    # With $FIX/keeps-rules the server answers and clears nothing.
    [ -e "$FIX/keeps-rules" ] || { jq -c --arg id "$id" 'map(if .id == $id then .permissions = [] else . end)' \
      "$FIX/sessions" > "$FIX/sessions.new" && mv "$FIX/sessions.new" "$FIX/sessions"; } ;;
  esac ;;
"logs "*) [ ! -e "$FIX/log-escapes" ] || { printf 'log\033]0;t\007line\n'; . "$FIX/ctl"; ctl; } ;;
"rm "*) echo false > "$FIX/running" ;;
*) echo "fake podman: unexpected $*" >&2; exit 99 ;;
esac
EOF
# The caller's opencode, which `secrets` and `import` alone start: builtins
# only, it runs with the caller's PATH.
cat >"$tools/userbin/opencode" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
printf '%s\n' "$*" >> "$FIX/opencode-calls"
printf '%s' "$0" > "$FIX/client-path"
printf '%s' "$PATH" > "$FIX/client-PATH"
# The sessions of the project the caller names: the host's own.
if [ "$1 $2" = "session list" ]; then cat "$FIX/host-sessions"; exit 0; fi
if [ "$1 $2" = "session export" ]; then
  if [ -e "$FIX/export-busy" ]; then cat "$FIX/host-export-busy"; else cat "$FIX/host-export"; fi
  exit 0
fi
[ "$1 $2" = "auth export" ] || exit 95
printf '%s %s\n' "$PWD" "${OPENCODE_DISABLE_PROJECT_CONFIG-unset}" > "$FIX/export-env"
# An array, as opencode prints it; empty for the integration `none`.
if [ "$3" = none ]; then echo '[]'
# What is no JSON and holds a credential all the same.
elif [ "$3" = broken ]; then echo 'warning: MODEL-SECRET-6 is no JSON'
else printf '[{"id":"cred_1","integrationID":"%s","label":"key","active":true,"value":{"type":"key","key":"MODEL-SECRET-6"}}]\n' "$3"; fi
EOF
# The launcher's filter, recording what it gets of the server password.
cat >"$tools/bin/sed" <<EOF
#!/bin/bash
. "\$FIX/envcheck"
printf '%s\\n' "\${OPENCODE_PASSWORD-unset}" >> "\$FIX/sed-password"
exec $(command -v sed) "\$@"
EOF
cat >"$tools/bin/timeout" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
shift; FAKE_TIMEOUT=1 exec "$@"
EOF
# gh: the login's name and its token, each on request only, from the config
# directory the caller names.
cat >"$tools/bin/gh" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
PATH=/usr/bin:/bin
printf '%s\n' "$*" >> "$FIX/gh-calls"
case "$*" in
"config get -h github.com user") cat "${GH_CONFIG_DIR:-$FIX}/gh-user"; [ ! -e "$FIX/gh-no-login" ] ;;
"auth token --hostname github.com") cat "${GH_CONFIG_DIR:-$FIX}/gh-token"; [ ! -e "$FIX/gh-no-token" ] ;;
*) exit 97 ;;
esac
EOF
# systemctl: the units install writes and up starts. Records every call and
# stands in for the unit: start activates it, stop and restart clear it.
cat >"$tools/bin/systemctl" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
PATH=/usr/bin:/bin
[ "$1" = --user ] && shift
printf '%s\n' "$*" >> "$FIX/systemctl-calls"
case "$1" in
daemon-reload) [ ! -e "$FIX/reload-fails" ] ;;
disable | reset-failed) ;;
start) [ ! -e "$FIX/start-fails" ] || exit 1; [ ! -e "$FIX/run-fails" ] || exit 125
  [ -e "$FIX/stops" ] || echo true > "$FIX/running" ;;
stop) echo false > "$FIX/running" ;;
restart) [ ! -e "$FIX/start-fails" ] || exit 1; [ ! -e "$FIX/run-fails" ] || exit 125
  echo true > "$FIX/running" ;;
is-active) grep -qx true "$FIX/running" ;;
*) echo "fake systemctl: unexpected $*" >&2; exit 99 ;;
esac
EOF
# The real commands of the launcher, each behind the same check.
for f in python3 jq realpath head base64 tr id mkdir seq sleep cat ls cp cmp mktemp rm ln ssh-keygen git rmdir; do
	printf '%s\n' '#!/bin/bash' '. "$FIX/envcheck"' "exec $(command -v "$f") \"\$@\"" >"$tools/bin/$f"
done
# The launcher's pauses are recorded; with $FIX/sleep-fast they take no time.
printf '%s\n' '#!/bin/bash' '. "$FIX/envcheck"' 'printf "%s\n" "$*" >> "$FIX/sleep-calls"' \
	'[ ! -e "$FIX/sleep-fast" ] || exit 0' "exec $(command -v sleep) \"\$@\"" >"$tools/bin/sleep"
# A client among the launcher's own commands is not the caller's.
printf '%s\n' '#!/bin/bash' ': > "$FIX/launcher-path-client"; exit 1' >"$tools/bin/opencode"
# First on the caller's PATH: what the launcher must take from its own.
for f in podman python3 jq realpath sed timeout head base64 tr id mkdir seq sleep cat ls gh cp cmp mktemp rm systemctl ln ssh-keygen git rmdir; do
	printf '%s\n' '#!/bin/bash' ': > "$FIX/planted-host"; exit 1' >"$tools/evilbin/$f"
done
chmod +x "$tools/bin/"* "$tools/userbin/"* "$tools/evilbin/"*
# What an agent could leave in the work directory for the launcher to start.
for f in podman opencode sed bin/sed bin/podman bin/opencode; do
	printf '%s\n' '#!/bin/bash' ': > "$FIX/planted-client"' >"$work/ws/$f"
	chmod +x "$work/ws/$f"
done
# A client named relative to / that the work directory holds as well.
mkdir -p "$work/ws/usr/bin"
cp "$work/ws/podman" "$work/ws/usr/bin/env"
# What an agent could leave in a work directory for the launcher to import.
for m in configparser re sys sitecustomize; do
	printf 'import os\nopen(os.environ["FIX"] + "/planted-ran", "w").close()\n' >"$work/planted/$m.py"
done
# And in the user's site directory, which -E alone leaves on the path.
usersite="$(HOME="$work/home" python3 -c 'import site; print(site.getusersitepackages())')"
mkdir -p "$usersite"
cp "$work/planted/sitecustomize.py" "$usersite/usercustomize.py"

# The openQA client config: two hosts that are asked for, one that is not, one
# whose name holds the default host's, and sections each refused for what they
# lack or hold, or for a name that is no host. [DEFAULT] lends nothing.
# Configs that the parser refuses as a whole or reads in part are under $oqc.
cat >"$work/config/openqa/client.conf" <<'EOF'
[DEFAULT]
key = OQASECRET8DEFAULTKEY
secret = OQASECRET8DEFAULTSECRET

[openqa.opensuse.org.example.net]
key = OQASECRET9NEARKEY
secret = OQASECRET9NEARSECRET

[openqa.opensuse.org]
key = OQASECRET1KEY
secret = OQASECRET1SECRET
extra = OQASECRET1EXTRA

[openqa.example.org:8080]
key = OQASECRET2KEY
secret = OQASECRET2SECRET

[openqa.example.com]
key = OQASECRET9FARKEY
secret = OQASECRET9FARSECRET

[nokey.example.org]
secret = OQASECRET3SECRET

[nosecret.example.org]
key = OQASECRET3KEY

[empty.example.org]
key =
secret = OQASECRET3SECRET

[dash.example.org]
key = OQASECRET3-KEY
secret = OQASECRET3SECRET

[space.example.org]
key = OQASECRET3 KEY
secret = OQASECRET3SECRET

[percent.example.org]
key = OQASECRET3%KEY
secret = OQASECRET3SECRET

[openqa.example.org/x]
key = OQASECRET3KEY
secret = OQASECRET3SECRET
EOF
printf '%s\n' '[openqa.opensuse.org]' 'key = OQASECRET5KEY' 'secret = OQASECRET5SECRET' >"$work/planted/client.conf"
oqc="$work/oqconf"
mkdir "$oqc"
oqgood=('[openqa.opensuse.org]' 'key = OQASECRET6KEY' 'secret = OQASECRET6SECRET')
oqother=('key = OQASECRET6OTHERKEY' 'secret = OQASECRET6OTHERSECRET')
# Read in full: comments of both kinds, blank lines, key=value, trailing blanks and tabs.
printf '%s\n' '# c' '; c' '' '   ' $' \t' "${oqgood[0]}" '#key = OQASECRET6OTHERKEY' \
	';key = OQASECRET6OTHERKEY' "${oqgood[1]}" '' "${oqgood[2]}" '[openqa.example.com]' "${oqother[@]}" >"$oqc/comments"
printf '%s\n' $'[openqa.opensuse.org] \t' $'key=OQASECRET6KEY\t' $'secret =\tOQASECRET6SECRET  ' 'note= x' >"$oqc/tight"
# Refused as a whole. indent-header: configparser took the indented header for
# a continuation line and gave the asked host the other host's key.
printf '%s\n' "${oqgood[0]}" 'note = mine' '  [openqa.example.com]' "${oqother[@]}" >"$oqc/indent-header"
printf '%s\n' "${oqgood[@]}" $'\t[openqa.example.com]' "${oqother[@]}" >"$oqc/tab-header"
printf '%s\n' "${oqgood[0]}" '  key = OQASECRET6KEY' "${oqgood[2]}" >"$oqc/indent-option"
printf '%s\n' "${oqgood[@]}" '[openqa.example.com]' "${oqother[@]}" '[openqa.example.com]' "${oqother[@]}" >"$oqc/dup-section"
printf '%s\n' "${oqgood[0]}" "${oqother[0]}" "${oqgood[1]}" "${oqgood[2]}" >"$oqc/dup-key"
printf '%s\n' "${oqgood[@]}" 'note = <<EOT' >"$oqc/heredoc"
printf '%s\n' "${oqother[0]}" "${oqgood[@]}" >"$oqc/before-section"
printf '%s\n' "${oqgood[0]}" 'key OQASECRET6KEY' "${oqgood[2]}" >"$oqc/no-equals"
printf '%s\n' "${oqgood[0]}" 'key: OQASECRET6KEY' 'secret: OQASECRET6SECRET' >"$oqc/colon"
printf '%s\n' "${oqgood[@]}" "my ${oqother[0]}" >"$oqc/name-blank"
n=0
for h in '[openqa example.org]' $'[openqa\texample.org]' '[openqa.example.org]]' '[[openqa.example.org]' '[]' \
	'[openqa.example.com] ; c'; do
	n=$((n + 1))
	printf '%s\n' "${oqgood[@]}" "$h" "${oqother[@]}" >"$oqc/header-$n"
done
printf '%s\n' "${oqgood[@]}" '  # c' >"$oqc/indent-comment"
# openqa-cli's parser ends a line at a lone CR or 0x15 when the first line does,
# and takes VT and FF for blanks: each of these gave the asked host the other
# host's key. A character that is not printable ASCII is refused anywhere.
printf '#\r[openqa.example.com]\r#\n[openqa.opensuse.org]\r\n%s\r\n%s\r\n#\r[openqa.opensuse.org]\r%s\r%s\r\n' \
	"${oqother[@]}" "${oqgood[@]:1}" >"$oqc/cr-steal"
printf '#\x15[openqa.example.com]\x15#\n[openqa.opensuse.org]\n%s\n%s\n#\x15[openqa.opensuse.org]\x15%s\x15%s\x15#\n' \
	"${oqother[@]}" "${oqgood[@]:1}" >"$oqc/nak-hide"
printf '%s\n' "${oqgood[@]}" $'[openqa.opensuse.org\v]' "${oqother[@]}" >"$oqc/vt-header"
printf '%s\n' "${oqgood[0]}" $'note =\f<<z=z' "${oqother[@]}" 'z=z' >"$oqc/heredoc-ff"
printf '%s\r\n' "${oqgood[@]}" >"$oqc/crlf"
printf '%s\n' "${oqgood[0]}" $'note = x\rkey = OQASECRET6OTHERKEY' "${oqgood[2]}" >"$oqc/lone-cr"
printf '%s\n' '# café' "${oqgood[@]}" >"$oqc/non-ascii"
printf '# a\0b\n%s\n%s\n%s\n' "${oqgood[@]}" >"$oqc/nul"
printf '# a\037b\n%s\n%s\n%s\n' "${oqgood[@]}" >"$oqc/unit-separator"
printf '# a\177b\n%s\n%s\n%s\n' "${oqgood[@]}" >"$oqc/del"
# Read, but not as the asked host's key or secret: names are case-sensitive.
printf '%s\n' "${oqgood[0]}" 'KEY = OQASECRET6KEY' 'Secret = OQASECRET6SECRET' >"$oqc/upper-key"
printf '%s\n' "${oqgood[@]:0:2}" 'Secret = OQASECRET6SECRET' >"$oqc/upper-secret"
printf '%s\n' "${oqgood[@]}" $'\xff' >"$oqc/undecodable"
printf 'BZ-SECRET-5\n' >"$work/config/mcp-bugzilla/api-key"
gh_config() {
	printf '%s\n' "$1" >"$FIX/gh-user"
	printf '%s\n' "$2" >"$FIX/gh-token"
}
gh_config packager gho_SECRET_9
echo false >"$FIX/running"
printf %s "$work/ws" >"$FIX/workdir"
# The image of the server's container, as podman names it: by its id.
img="$(printf %s "$N" | sha256sum | cut -d' ' -f1)"
echo "$img" >"$FIX/image"
echo "$FIX/store" >"$FIX/storepath"
echo "$FIX/store/volumes" >"$FIX/volpath"
# Another container, which writes beside the directories of this test.
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" >"$FIX/others"
echo '{"data":[]}' >"$FIX/saved"
echo '{"data":[]}' >"$FIX/logins"
kept_login() { printf '{"data":[{"id":"%s","integrationID":"prov","active":true,"value":{"type":"key","key":"KEPT-SECRET-8"}}]}\n' "$1" >"$FIX/logins"; }
echo '[{"id":"prj_main"}]' >"$FIX/projects"
echo '[]' >"$FIX/sessions"
printf '%s\n' '/beef01 bridge' '/beef02 bridge' >"$FIX/netmode"
printf '%s' server | sha256sum | cut -d' ' -f1 >"$FIX/ctr-id"
# The sessions of the host project, as `session list` answers them.
printf '%s\n' '[{"id":"ses_h1","title":"host one"},{"id":"ses_h2","title":"host two"}]' >"$FIX/host-sessions"
# And their export: idle, with the transcript the container keeps.
printf '%s\n' '{"info":{"id":"ses_h1","title":"host one","location":{"directory":"/home/user/obs"},"time":{"busy":1,"idle":2}},"messages":[{"id":"msg_1","type":"user","text":"hello"}]}' >"$FIX/host-export"
printf '%s\n' '{"info":{"id":"ses_h1","title":"host one","location":{"directory":"/home/user/obs"},"time":{"busy":3,"idle":2}},"messages":[{"id":"msg_1","type":"user","text":"hello"}]}' >"$FIX/host-export-busy"
# The fixed copy install asks for: the launcher itself.
mkdir -p "$work/home/.local/bin"
cp "$SC" "$work/home/.local/bin/openqa-container"
cp -r "$HERE/../../contrib/container/systemd" "$work/home/.local/bin/systemd"
allow='[{"action":"*","resource":"*","effect":"allow"}]'
# The sessions of the state volume, as the agent could have written them.
sessions() {
	printf '%s\n' "$1" >"$FIX/sessions"
	: >"$FIX/client-calls"
}
# One approval the server saved for a project, as the agent could have written it.
approval() {
	printf '{"data":[{"id":"%s","projectID":"%s","action":"shell","resource":"*"}]}\n' "$1" "${2:-prj_main}" \
		>"$FIX/saved"
	: >"$FIX/client-calls"
}

# OPENCODE unset: the caller's own must not replace the fake. The launcher finds
# its commands among the checked ones alone: one it takes from elsewhere fails.
ownpath="$tools/bin"
callerpath="$tools/evilbin:$tools/userbin:$PATH"
scenv=(env -u OPENCODE -u OPENCODE_PASSWORD XDG_CONFIG_HOME="$work/config" XDG_RUNTIME_DIR="$work/run"
	"SKILL_CONTAINER_NAME=$N" "SKILL_CONTAINER_PATH=$ownpath" PATH="$callerpath")
sc() { "${scenv[@]}" HOME="${SC_HOME:-$work/home}" bash "$SC" "$@"; }
# A command on a terminal of its own, whose output a pipe reads: attach wants one.
pty() (
	set -o pipefail
	python3 -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    os.write(1, data)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))' "$@" | tr -d '\r'
)
tty() { pty "${scenv[@]}" HOME="$work/home" bash "$SC" "$@"; }
# The files the launcher left that hold the server password $pw.
pwfiles() {
	{
		find /tmp /var/tmp /dev/shm "/run/user/$(id -u)" -maxdepth 3 \( -path "$work" -o -path "$tools" \) -prune \
			-o -type f -user "$(id -u)" -newer "$work/stamp" -print 2>/dev/null
		find "$work" "$tools" -path "$FIX" -prune -o -type f -newer "$work/stamp" -print
	} | xargs -r -d '\n' grep -lF -- "$pw" 2>/dev/null
}
# The files that hold a made-up login and are not the fixtures: those the
# launcher left, in the temporary directories or beside what it reads.
fixtures=("$work/config/openqa/client.conf" "$work/planted/client.conf" "$oqc"/* "$work/openqa-closed.conf" "$work/config/mcp-bugzilla/api-key"
	"$work/planted/key" "$work/mem-key/memory.json" "$work/mem-mixed/memory.json" "$tools/userbin/opencode")
# Another launcher suite running at the same time keeps its fixtures in a
# temporary directory of its own with fix/envcheck in it: not a leak of this run.
mine() {
	local f d rest top
	while IFS= read -r f; do
		top=''
		for d in /tmp /var/tmp /dev/shm "/run/user/$(id -u)"; do
			[[ $f == "$d"/*/* ]] || continue
			rest=${f#"$d"/}
			top=$d/${rest%%/*}
		done
		# A sibling's tool directory holds a fake login in userbin/opencode, without fix/.
		[ -n "$top" ] && [ "$top" != "$work" ] && [ "$top" != "$tools" ] &&
			{ [ -e "$top/fix/envcheck" ] || [ -e "$top/userbin/opencode" ]; } && continue
		printf '%s\n' "$f"
	done
}
leakfiles() {
	{
		find /tmp /var/tmp /dev/shm "/run/user/$(id -u)" -maxdepth 3 \( -path "$work" -o -path "$tools" \) -prune \
			-o -type f -user "$(id -u)" -newer "$work/stamp" -print 2>/dev/null
		find "$work" "$tools" -path "$FIX" -prune -o -type f -print
	} | xargs -r -d '\n' grep -lE -- 'SECRET[-_][0-9]|OQASECRET[0-9]' 2>/dev/null | grep -vxF -f <(printf '%s\n' "${fixtures[@]}") | mine
}
secret() { cat "$FIX/secrets/$N-$1" 2>/dev/null; }
stored() { cat "$FIX/secrets/"* | sha256sum; }
# The container was removed after it last started.
stopped() { grep -qx "stop $N-agent@obs.service" "$FIX/systemctl-calls"; }
# No made-up secret may reach the terminal or a command line.
leaks() { grep -E 'SECRET[-_][0-9]|OQASECRET[0-9]' "$@" 2>/dev/null; }

out="$(sc install obs --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "secrets" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install without secrets starts nothing" || fail "install without secrets: rc=$rc $out"

out="$(sc secrets 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ -z "$(ls "$FIX/secrets")" ] && pass "secrets needs --model-auth" ||
	fail "secrets without --model-auth: rc=$rc $out"
out="$(sc ssh-key 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-ssh" <<<"$out" && pass "ssh-key before secrets says so" ||
	fail "ssh-key without the secret: rc=$rc $out"

# From a directory the agent wrote: none of its modules is imported, opencode
# exports elsewhere and without project config, a key file named from it is found.
printf 'BZ-SECRET-8\n' >"$work/planted/key"
out="$(cd "$work/planted" && sc secrets --model-auth prov --bugzilla-key key 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ ! -e "$FIX/planted-ran" ] && pass "secrets imports no module from the current directory" ||
	fail "secrets in a directory with planted modules: rc=$rc $out"
[ "$(cat "$FIX/export-env")" = "/ 1" ] && pass "the export runs outside the current directory, project config off" ||
	fail "the export ran in: $(cat "$FIX/export-env")"
[ "$(secret bugzilla)" = BZ-SECRET-8 ] && pass "a key file named from the current directory is stored" ||
	fail "a relative --bugzilla-key: rc=$rc $out"
[ "$(cat "$FIX/client-path")" = "$tools/userbin/opencode" ] && [ "$(cat "$FIX/client-PATH")" = "$callerpath" ] &&
	pass "the export is the caller's opencode, with the caller's PATH" ||
	fail "the export ran $(cat "$FIX/client-path") with $(cat "$FIX/client-PATH")"
# Nor from a directory that PYTHONPATH names: in secrets, which reads the
# logins, and in up, which checks the directories above the mounts.
out="$(PYTHONPATH="$work/planted" sc secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ ! -e "$FIX/planted-ran" ] && pass "secrets imports no module from PYTHONPATH" ||
	fail "secrets with PYTHONPATH on planted modules: rc=$rc $out"
rm -f "$FIX/planted-ran"
out="$(PYTHONPATH="$work/planted" sc install obs --workdir "$work/ws" --memory "$work/none" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "not a file: $work/none" <<<"$out" && [ ! -e "$FIX/planted-ran" ] &&
	pass "install imports no module from PYTHONPATH" || fail "install with PYTHONPATH on planted modules: rc=$rc $out"
rm -f "$FIX/planted-ran"
# The GitHub login is the one gh finds where the caller runs secrets.
mkdir "$FIX/ghalt"
printf 'narrow\n' >"$FIX/ghalt/gh-user"
printf 'gho_SECRET_8\n' >"$FIX/ghalt/gh-token"
out="$(GH_CONFIG_DIR="$FIX/ghalt" sc secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(secret github | grep -c 'user: narrow$\|oauth_token: gho_SECRET_8$')" = 3 ] &&
	! secret github | grep -q 'packager\|gho_SECRET_9' &&
	pass "secrets copies the login of the gh config directory the caller names" ||
	fail "secrets with GH_CONFIG_DIR: rc=$rc $(leaks <<<"$out" | wc -l) $(secret github | sed 's/token:.*/token: …/')"

out="$(sc secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf '%s\n' $N-openqa $N-github $N-model $N-bugzilla $N-ssh)" ] &&
	pass "secrets prints the five names only" || fail "secrets: rc=$rc $out"
# The SSH key: made by the first run, with no file of it left behind.
key1="$(secret ssh)"
grep -q 'BEGIN OPENSSH PRIVATE KEY' <<<"$key1" && [ -z "$(find "$work/run" -name 'tmp.*')" ] &&
	pass "secrets makes an SSH key and leaves no copy" || fail "the SSH key: $(find "$work/run" -name 'tmp.*')"
out="$(sc ssh-key 2>&1)"
rc=$?
[ "$rc" = 0 ] && [[ $out == "ssh-ed25519 "*" $N" ]] && [ "$(wc -l <<<"$out")" = 1 ] &&
	pass "ssh-key prints the public half alone" || fail "ssh-key: rc=$rc $(wc -l <<<"$out") lines"
out="$(sc secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(secret ssh)" = "$key1" ] && pass "a later secrets run keeps the SSH key" ||
	fail "the SSH key after a second run: rc=$rc"
out="$(sc secrets --model-auth prov --new-ssh-key 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(secret ssh)" != "$key1" ] && secret ssh | grep -q 'BEGIN OPENSSH PRIVATE KEY' &&
	pass "--new-ssh-key replaces the SSH key" || fail "--new-ssh-key: rc=$rc"
[ -z "$(leaks "$FIX/podman-calls" "$FIX/opencode-calls" "$FIX/gh-calls")" ] && pass "no secret on a command line" ||
	fail "a secret on a command line: $(leaks "$FIX/podman-calls" "$FIX/opencode-calls" "$FIX/gh-calls")"

# The openQA secret: the key and the secret of each host asked for, in that
# order, and nothing else of the config; openqa.opensuse.org when none is.
oqa1="$(printf '%s\n' '[openqa.opensuse.org]' 'key = OQASECRET1KEY' 'secret = OQASECRET1SECRET')"
oqa2="$(printf '%s\n' '[openqa.example.org:8080]' 'key = OQASECRET2KEY' 'secret = OQASECRET2SECRET')"
[ "$(secret openqa)" = "$oqa1" ] && pass "without --openqa-host the openQA secret holds openqa.opensuse.org alone" ||
	fail "the openQA secret: $(secret openqa | sed 's/ = .*/ = …/')"
out="$(sc secrets --model-auth prov --openqa-host openqa.example.org:8080 --openqa-host openqa.opensuse.org 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf '%s\n' $N-openqa $N-github $N-model $N-bugzilla $N-ssh)" ] &&
	[ "$(secret openqa)" = "$oqa2"$'\n\n'"$oqa1" ] && pass "the openQA secret holds the two hosts asked for alone" ||
	fail "secrets with two hosts: rc=$rc $out / $(secret openqa | sed 's/ = .*/ = …/')"
out="$(sc secrets --model-auth prov --openqa-host openqa.example.org:8080 --openqa-host openqa.example.org:8080 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(secret openqa)" = "$oqa2" ] && pass "a host asked for twice is copied once" ||
	fail "secrets with a host twice: rc=$rc $out / $(secret openqa | sed 's/ = .*/ = …/')"
out="$(cd "$work/planted" && sc secrets --model-auth prov --openqa-conf client.conf 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(secret openqa)" = "$(printf '%s\n' '[openqa.opensuse.org]' 'key = OQASECRET5KEY' 'secret = OQASECRET5SECRET')" ] &&
	pass "an openQA config named from the current directory is read" || fail "a relative --openqa-conf: rc=$rc $out"
oqa6="$(printf '%s\n' "${oqgood[@]}")"
for f in comments tight; do
	out="$(sc secrets --model-auth prov --openqa-host openqa.opensuse.org --openqa-host openqa.opensuse.org \
		--openqa-conf "$oqc/$f" 2>&1)"
	rc=$?
	[ "$rc" = 0 ] && [ "$(secret openqa)" = "$oqa6" ] && pass "the openQA config parser reads $f, the host asked twice once" ||
		fail "openQA config $f: rc=$rc $out / $(secret openqa | sed 's/ = .*/ = …/')"
done
out="$(sc secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(secret openqa)" = "$oqa1" ] || fail "secrets with the default config again: rc=$rc $out"
# gh's hosts file, as gh 2.x writes it for one login.
[ "$(secret github)" = "$(printf '%s\n' "github.com:" "    users:" "        packager:" \
	"            oauth_token: gho_SECRET_9" "    git_protocol: https" "    user: packager" \
	"    oauth_token: gho_SECRET_9")" ] &&
	[ "$(sort -u "$FIX/gh-calls" | tr '\n' '|')" = "auth token --hostname github.com|config get -h github.com user|" ] &&
	pass "the gh secret is a hosts file with the one github.com login" ||
	fail "the gh secret: $(secret github | sed 's/token:.*/token: …/') / $(sort -u "$FIX/gh-calls")"
secret model | grep -qF MODEL-SECRET-6 && [ "$(secret bugzilla)" = BZ-SECRET-5 ] &&
	pass "the model and Bugzilla secrets are stored" || fail "the model or Bugzilla secret"
[ ! -e "$FIX/secrets/$N-server-password" ] && pass "no server password before a container starts" ||
	fail "a server password without a container"

# A later run that fails must not have stored its first secret already.
sed -i 's/OQASECRET1KEY/OQASECRET1NEWKEY/' "$work/config/openqa/client.conf"
before="$(stored)"
# A section that is not there, holds no usable key or secret, or would get one
# from [DEFAULT]: nothing is replaced, no value is shown.
while IFS='|' read -r hosts why; do
	# shellcheck disable=SC2086  # the --openqa-host flags are words of their own
	out="$(sc secrets --model-auth prov $hosts 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qxF -- "skill-container: $why" <<<"$out" && [ -z "$(leaks <<<"$out")" ] &&
		[ "$(stored)" = "$before" ] && pass "secrets refuses $hosts: nothing replaced, nothing quoted" ||
		fail "secrets $hosts: rc=$rc $out"
done <<'EOF'
--openqa-host openqa.example.org|the openQA client config has no section openqa.example.org
--openqa-host example.org|the openQA client config has no section example.org
--openqa-host openqa.opensuse.org --openqa-host nokey.example.org|section nokey.example.org has no usable key
--openqa-host nosecret.example.org --openqa-host openqa.opensuse.org|section nosecret.example.org has no usable secret
--openqa-host empty.example.org|section empty.example.org has no usable key
--openqa-host dash.example.org|section dash.example.org has no usable key
--openqa-host space.example.org|section space.example.org has no usable key
--openqa-host percent.example.org|section percent.example.org has no usable key
EOF
# A host is a section name as the config writes it: one that is no host name
# is refused before the config is read, after a good one as well.
n=0
for host in 'openqa.example.org]' 'openqa example.org' $'openqa.example.org\n[openqa.example.com]' 'openqa.example.org/x' \
	'' 'openqa.example.org:' 'openqa.example.org:80x'; do
	n=$((n + 1))
	out="$(sc secrets --model-auth prov --openqa-host openqa.opensuse.org --openqa-host "$host" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [[ $out == *"secrets: not a host name: $host" ]] && [ -z "$(leaks <<<"$out")" ] &&
		[ "$(stored)" = "$before" ] && pass "secrets refuses a host that is no host name ($n)" ||
		fail "secrets with the host '$host': rc=$rc $out"
done
# In a UTF-8 locale a range such as A-Z can take a letter of another alphabet.
host='openqa.éxample.org'
loc=
for l in en_US.utf8 $(locale -a 2>/dev/null | grep -iE '\.utf-?8$'); do
	if LC_ALL=$l bash -c '[[ $1 =~ ^[A-Za-z.]+$ ]]' _ "$host" 2>/dev/null; then
		loc=$l
		break
	fi
done
if [ -n "$loc" ]; then
	out="$(LC_ALL=$loc sc secrets --model-auth prov --openqa-host "$host" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [[ $out == *"secrets: not a host name: $host" ]] && [ "$(stored)" = "$before" ] &&
		pass "secrets refuses a host name with a non-ASCII letter in $loc" || fail "secrets with the host '$host' in $loc: rc=$rc $out"
else
	skip "a host name with a non-ASCII letter (no locale here whose A-Z takes one)"
fi
# An instance name has 1 to 64 characters and does not start with -: no flag is taken for one.
instmsg="an instance names the container: 1 to 64 letters, digits, _ and -, the first no -"
long="$(printf 'a%.0s' {1..64})"
out="$(sc idle "$long" 2>&1)"
rc=$?
[ "$rc" != 0 ] && [[ $out == "skill-container: $long is not installed"* ]] &&
	pass "an instance name of 64 characters is taken" || fail "the instance of 64 characters: rc=$rc $out"
# Installed under another name, the launcher's messages name the command run.
ln -s "$SC" "$work/openqa-container"
out="$("${scenv[@]}" HOME="$work/home" bash "$work/openqa-container" idle "$long" 2>&1)"
rc=$?
[ "$rc" != 0 ] && [[ $out == "openqa-container: $long is not installed: 'openqa-container install $long'"* ]] &&
	pass "the messages name the command the launcher was run as" || fail "the launcher's own name: rc=$rc $out"
# A name install would write into the drop-in header, so not one that holds a new line or a blank.
for odd in "oqa"$'\n'"PodmanArgs=--privileged" "openqa container"; do
	ln -s "$SC" "$work/$odd"
	out="$("${scenv[@]}" HOME="$work/home" bash "$work/$odd" idle "$long" 2>&1)"
	rc=$?
	rm "$work/$odd"
	[ "$rc" != 0 ] && [[ $out == "skill-container: $long is not installed: 'skill-container install $long'"* ]] &&
		pass "the launcher named $(printf %q "$odd") names itself skill-container" ||
		fail "the launcher named $(printf %q "$odd"): rc=$rc $out"
done
for bad in "${long}a" -x - '' a.b; do
	out="$(sc idle "$bad" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ "$out" = "skill-container: $instmsg" ] && pass "the instance name '$bad' is refused" ||
		fail "the instance '$bad': rc=$rc $out"
done
: >"$FIX/systemctl-calls"
out="$(sc down --help 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ "$out" = "skill-container: $instmsg" ] && [ ! -s "$FIX/systemctl-calls" ] &&
	pass "down --help stops no instance" || fail "down --help: rc=$rc $out"
# Nor does an instance name take a non-ASCII letter: the launcher runs in the C locale.
if [ -n "$loc" ]; then
	out="$(LC_ALL=$loc sc install 'ébs' --workdir "$work/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ "$out" = "skill-container: $instmsg" ] &&
		pass "an instance name with a non-ASCII letter is refused in $loc" || fail "the instance 'ébs' in $loc: rc=$rc $out"
else
	skip "an instance name with a non-ASCII letter (no locale here whose A-Z takes one)"
fi
# A line the parser cannot take refuses the whole config, without quoting it.
r="the openQA client config has a line that is not a plain section, key = value or comment, or that repeats one, or a character that is not printable ASCII"
while IFS='|' read -r f why; do
	out="$(sc secrets --model-auth prov --openqa-host openqa.opensuse.org --openqa-conf "$oqc/$f" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ "$out" = "skill-container: ${why:-$r}" ] && [ -z "$(leaks <<<"$out")" ] &&
		[ "$(stored)" = "$before" ] && pass "secrets refuses the openQA config $f: nothing replaced, nothing quoted" ||
		fail "openQA config $f: rc=$rc $out"
done <<'EOF'
indent-header|
tab-header|
indent-option|
dup-section|
dup-key|
heredoc|
before-section|
no-equals|
colon|
name-blank|
header-1|
header-2|
header-3|
header-4|
header-5|
header-6|
indent-comment|
cr-steal|
nak-hide|
vt-header|
heredoc-ff|
crlf|
lone-cr|
non-ascii|
nul|
unit-separator|
del|
upper-key|section openqa.opensuse.org has no usable key
upper-secret|section openqa.opensuse.org has no usable secret
EOF
# The configs that gave the asked host another host's key: it is stored nowhere and shown nowhere.
for f in indent-header cr-steal nak-hide vt-header heredoc-ff; do
	out="$(sc secrets --model-auth prov --openqa-conf "$oqc/$f" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && ! grep -qF OQASECRET6OTHER <<<"$out" && ! grep -rqF OQASECRET6OTHER "$FIX/secrets" &&
		[ "$(stored)" = "$before" ] && pass "the openQA config $f lends no other host's key" ||
		fail "openQA config $f lends a key: rc=$rc $out"
done
printf '%s\n' '[openqa.opensuse.org]' 'key = OQASECRET7KEY' 'secret = OQASECRET7SECRET' >"$work/openqa-closed.conf"
chmod 000 "$work/openqa-closed.conf"
# What Python says of a file it cannot read or decode may quote it: its type alone is shown.
confs=("$oqc/undecodable|UnicodeDecodeError" "$work/none.conf|FileNotFoundError" "$work/config|IsADirectoryError")
[ "$(id -u)" = 0 ] || confs+=("$work/openqa-closed.conf|PermissionError")
for c in "${confs[@]}"; do
	out="$(sc secrets --model-auth prov --openqa-conf "${c%%|*}" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ "$out" = "skill-container: cannot read the openQA client config (${c#*|})" ] &&
		[ "$(stored)" = "$before" ] && pass "an openQA config that cannot be read: its error's type alone (${c##*/})" ||
		fail "openQA config ${c%%|*}: rc=$rc $out"
done
# Nor is the SSH key made or replaced by a run that fails.
mv "$FIX/secrets/$N-ssh" "$FIX/ssh.kept"
out="$(sc secrets --model-auth prov --openqa-host openqa.example.org 2>&1)"
rc1=$?
out="$out$(sc secrets --model-auth none 2>&1)"
rc=$?
[ "$rc1" != 0 ] && [ "$rc" != 0 ] && [ ! -e "$FIX/secrets/$N-ssh" ] && [ -z "$(find "$work/run" -name 'tmp.*')" ] &&
	pass "a run that fails makes no SSH key" || fail "a failed run and a missing SSH key: rc=$rc1 $rc $out"
mv "$FIX/ssh.kept" "$FIX/secrets/$N-ssh"
out="$(sc secrets --model-auth none --new-ssh-key 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ "$(stored)" = "$before" ] && pass "a run that fails keeps the SSH key, --new-ssh-key or not" ||
	fail "a failed run with --new-ssh-key: rc=$rc $out"
out="$("${scenv[@]}" OPENCODE=usr/bin/env HOME="$work/home" bash "$SC" secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "no opencode client at an absolute path" <<<"$out" && [ "$(stored)" = "$before" ] &&
	pass "secrets refuses a client named by a relative path" || fail "secrets with a relative OPENCODE: rc=$rc $out"
# gh without a github.com login or its token. What gh prints goes into a YAML
# file as it is: a name or a token that is more than one word is not stored.
touch "$FIX/gh-no-login"
out="$(sc secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "no github.com login" <<<"$out" && [ "$(stored)" = "$before" ] &&
	pass "no GitHub login: nothing replaced" || fail "no GitHub login: rc=$rc $out"
rm "$FIX/gh-no-login"
touch "$FIX/gh-no-token"
out="$(sc secrets --model-auth prov 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "no token for github.com" <<<"$out" && [ "$(stored)" = "$before" ] &&
	pass "a GitHub login without a token: nothing replaced" || fail "GitHub login without a token: rc=$rc $out"
rm "$FIX/gh-no-token"
n=0
for pair in 'packager: x|gho_SECRET_9' '|gho_SECRET_9' $'packager|gho_SECRET_9\n    user: other' \
	'packager|gho_SECRET_9: x' 'packager|'; do
	n=$((n + 1))
	gh_config "${pair%%|*}" "${pair#*|}"
	out="$(sc secrets --model-auth prov 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ -z "$(leaks <<<"$out")" ] && [ "$(stored)" = "$before" ] &&
		pass "a GitHub name or token that is not one word: nothing replaced, nothing quoted ($n)" ||
		fail "GitHub name or token ($n): rc=$rc $out"
done
gh_config packager gho_SECRET_9
out="$(sc secrets --model-auth none 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ "$(stored)" = "$before" ] &&
	pass "an empty export: nothing replaced" || fail "empty export: rc=$rc $out"
out="$(sc secrets --model-auth broken 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "exported no credential" <<<"$out" && [ -z "$(leaks <<<"$out")" ] && [ "$(stored)" = "$before" ] &&
	pass "an export that is no JSON: nothing replaced, nothing quoted" || fail "export that is no JSON: rc=$rc $out"
: >"$work/empty-key"
mkdir "$work/dir-key"
for key in "$work/no-key" "$work/empty-key" "$work/dir-key"; do
	out="$(sc secrets --model-auth prov --bugzilla-key "$key" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ "$out" = "skill-container: no Bugzilla API key at $key" ] && [ "$(stored)" = "$before" ] &&
		pass "no Bugzilla key in ${key##*/}: nothing replaced" || fail "Bugzilla key $key: rc=$rc $out"
done

left="$(leakfiles)"
[ -z "$left" ] && pass "secrets leaves no login in a file" || fail "secrets left a login in: $left"
# The scan passes over the fixtures of another suite's run, not over a stray file.
sib="$(mktemp -d)"
mkdir "$sib/fix"
: >"$sib/fix/envcheck"
echo SECRET-9 >"$sib/fix/logins"
sibtools="$(mktemp -d)"
mkdir "$sibtools/userbin"
echo 'echo SECRET-9' >"$sibtools/userbin/opencode"
stray="$(mktemp)"
echo SECRET-9 >"$stray"
left="$(leakfiles)"
! grep -qF "$sib/" <<<"$left" && ! grep -qF "$sibtools/" <<<"$left" && grep -qxF "$stray" <<<"$left" &&
	pass "the leak scan passes over another suite's fixtures and tools, not over a stray file" || fail "the leak scan's filter: $left"
rm -rf "$sib" "$sibtools" "$stray"

# The agent gets the whole work directory: not the home directory, what holds
# it, the logins, podman's storage, the runtime directory, someone else's
# directory, or a path podman would split.
refused=(/ "$work" "$work/home" "$work/home/.config" "$work/config" "$work/config/openqa" "$FIX"
	"$FIX/store/volumes" "$work/run" "$work/run/sub" "$work/a,b" "$work/a:b")
[ "$(id -u)" = 0 ] || refused+=(/etc)
for d in "${refused[@]}"; do
	out="$(sc install obs --workdir "$d" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && ! grep -q '^run ' "$FIX/podman-calls" && pass "install refuses $d" ||
		fail "install --workdir $d: rc=$rc $out"
done
# Podman's volumes can lie outside its storage.
mkdir -p "$work/vols/v/_data" "$work/vols/g/_data" "$FIX/store/volumes/g/_data" "$FIX/store/overlay"
echo "$work/vols" >"$FIX/volpath"
for d in "$work/vols/v/_data" "$FIX/store/overlay"; do
	out="$(sc install obs --workdir "$d" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "the work directory is one you own" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory in podman's storage or volumes (${d#"$work"})" ||
		fail "install --workdir $d: rc=$rc $out"
done
# Nor is the graph a file there or in the storage: a container that mounts the
# volume writes it.
for d in "$work/vols/g/_data" "$FIX/store/volumes/g/_data"; do
	printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' >"$d/memory.json"
	out="$(sc install obs --workdir "$work/ws" --memory "$d/memory.json" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "memory.json: it lies in podman's storage" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a graph in podman's storage (${d#"$work"})" || fail "install --memory $d/memory.json: rc=$rc $out"
done
echo "$FIX/store/volumes" >"$FIX/volpath"
# Another owner's directory below a closed one of the caller: without root
# only a subordinate uid makes one.
mkdir "$work/foreign"
if unshare --user --map-root-user --map-users=auto chown 1 "$work/foreign" 2>/dev/null; then
	out="$(sc install obs --workdir "$work/foreign" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "the work directory is one you own" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory of another owner" || fail "install --workdir of another owner: rc=$rc $out"
else
	skip "a work directory of another owner (no subordinate uids here)"
fi
rmdir "$work/foreign"
out="$(cd "$work/ws" && sc install obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "is required" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install without --workdir starts nothing, wherever it is called" || fail "install without --workdir: rc=$rc $out"
out="$(SC_HOME="$work/homelink" sc install obs --workdir "$work/home" 2>&1)"
rc=$?
[ "$rc" != 0 ] && ! grep -q '^run ' "$FIX/podman-calls" && pass "install refuses the home directory behind a link" ||
	fail "install --workdir on a linked home: rc=$rc $out"

# Every login is there before a container starts.
for s in openqa bugzilla model ssh; do
	mv "$FIX/secrets/$N-$s" "$FIX/$s.kept"
	out="$(sc install obs --workdir "$work/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "no secret $N-$s" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		[ ! -e "$work/config/skill-container/$N/obs.dir" ] &&
		pass "install without the $s secret starts nothing" || fail "install without the $s secret: rc=$rc $out"
	mv "$FIX/$s.kept" "$FIX/secrets/$N-$s"
done
mv "$FIX/secrets/$N-github" "$FIX/github.kept"
out="$(sc install obs --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install without the GitHub secret starts nothing" || fail "install without the GitHub secret: rc=$rc $out"

# The work directory is not mounted over the image's own files: not at / nor in
# or above one of its directories, as the path reads once realpath -ms has
# normalised it, whether --as names it or the work directory's own path is the
# mount point. Refused before a secret is looked at, with nothing written.
# $1 = what is printed as the mount point, $2 = the directory it meets (none: /;
# var: /var or /tmp), then the arguments of install.
mounted() {
	local at=$1 own=$2 want
	shift 2
	want="skill-container: refusing to mount the work directory at $at: it lies in or holds $own, where the image keeps its own files; --as names another place"
	[ -n "$own" ] || want="skill-container: refusing to mount the work directory at /"
	[ "$own" != var ] ||
		want="skill-container: refusing to mount the work directory at $at: nothing in /var is free, nor is /tmp itself; --as names another place, such as /work or one below /tmp"
	: >"$FIX/podman-calls"
	: >"$FIX/systemctl-calls"
	out="$(cd /usr && sc install mnt "$@" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ "$out" = "$want" ] && [ ! -s "$FIX/podman-calls" ] && [ ! -s "$FIX/systemctl-calls" ] &&
		[ ! -e "$work/home/.config/containers" ] && [ ! -e "$work/home/.config/systemd" ] &&
		[ ! -e "$work/config/skill-container/$N/mnt.dir" ] &&
		pass "install refuses to mount the work directory at $at" || fail "install mounted at $at: rc=$rc $out"
}
while read -r as own; do
	mounted "$as" "$own" --workdir "$work/ws" --as "$as"
done <<'EOF'
/etc /etc
/usr /usr
/bin /bin
/sbin /sbin
/lib /lib
/lib64 /lib64
/home/agent /home/agent
/agent-logins /agent-logins
/etc/opencode /etc
/usr/local/x /usr
/home/agent/work /home/agent
/agent-logins/gh /agent-logins
/home /home/agent
/srv/../etc /etc
//etc /etc
/usr/./lib /usr
/etc/ /etc
/boot /boot
/dev /dev
/proc /proc
/sys /sys
/run /run
/root /root
/boot/efi /boot
/dev/shm /dev
/proc/1 /proc
/sys/fs /sys
/run/x /run
/root/x /root
//run /run
/run/. /run
/srv/../run/x /run
/var var
/var/ var
/var/lib var
/var/lib/rpm var
/var/lib/ca-certificates var
/var/run var
/var/tmpx var
/var/tmp var
/var/tmp/ var
//var/tmp var
/var/./tmp var
/var/tmp/. var
/var/tmp/x/.. var
/var/lib/../tmp var
/var/tmp/x var
/var/tmp/x/work var
//var/tmp/x var
/var/tmp/./x var
/srv/../var/tmp/x var
/tmp/../var/tmp/x var
/tmp var
//tmp var
/tmp/. var
/tmp/x/.. var
EOF
for as in / // /srv/..; do
	mounted "$as" "" --workdir "$work/ws" --as "$as"
done
# A relative --as is taken from where install was called: /usr here.
mounted /usr/../etc/x /etc --workdir "$work/ws" --as ../etc/x
# Without --as the work directory's own path is the mount point.
for wd in /etc /usr /usr/lib /agent-logins /home /run /var/lib /tmp; do
	own=$wd
	[ "$wd" != /usr/lib ] || own=/usr
	[ "$wd" != /home ] || own=/home/agent
	[ "$wd" != /var/lib ] && [ "$wd" != /tmp ] || own=var
	mounted "$wd" "$own" --workdir "$wd"
done
mounted / "" --workdir /
# A host work directory under /var/tmp is mounted elsewhere only.
mkdir "$vtmp/ws"
mounted "$vtmp/ws" var --workdir "$vtmp/ws"
for as in /work /tmp/x; do
	out="$(sc install mnt --workdir "$vtmp/ws" --as "$as" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qxF "skill-container: no secret $N-github: run 'skill-container secrets' first" <<<"$out" &&
		pass "install takes a work directory under /var/tmp mounted at $as" || fail "install --workdir $vtmp/ws --as $as: rc=$rc $out"
done
# With every secret there as well.
mv "$FIX/github.kept" "$FIX/secrets/$N-github"
mounted /etc/opencode /etc --workdir "$work/ws" --as /etc/opencode
mv "$FIX/secrets/$N-github" "$FIX/github.kept"
# Names that only look like those directories are mounted: install goes on to the secrets.
for as in /etcetera /usr2 /homework /tmp/x/work /srv/work /home/user/openqa /tmp/x /tmp/./x /srv /opt \
	/mnt/x /work /variable /tmpx /usrlocal /runtime /rootfs /devices /bootx /sysx /procx; do
	out="$(sc install mnt --workdir "$work/ws" --as "$as" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qxF "skill-container: no secret $N-github: run 'skill-container secrets' first" <<<"$out" &&
		pass "install takes the mount point $as" || fail "install --as $as: rc=$rc $out"
done

# The agent runs as the caller and can make a file setuid to them: a directory
# above what it writes is the caller's and closed to everyone else. ($open
# lies in a temporary directory that is open, as /tmp is.)
mkdir -p "$open/ws" "$open/mid/ws" "$open/vol"
chmod 700 "$open/ws"
for mode in 755 750 710 701; do
	chmod "$mode" "$open"
	out="$(sc install obs --workdir "$open/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory below a directory others can enter ($mode)" ||
		fail "install below a directory of mode $mode: rc=$rc $out"
done
echo "$open/vol" >"$FIX/volpath"
out="$(sc install obs --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/vol need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install refuses volumes below a directory others can enter" || fail "install with open volumes: rc=$rc $out"
echo "$FIX/store/volumes" >"$FIX/volpath"
# Closed two levels up: the check goes on to the logins.
chmod 700 "$open"
chmod 755 "$open/mid"
out="$(sc install obs --workdir "$open/mid/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install takes a work directory with a closed directory further up" || fail "install below a closed directory: rc=$rc $out"
# Root owns what lies above: where the directories above belong to neither
# root nor the caller, as an unmapped owner shows in a user namespace, the
# closed one counts for nothing.
if unshare --user --map-user="$(id -u)" true 2>/dev/null; then
	out="$(unshare --user --map-user="$(id -u)" "${scenv[@]}" HOME="$work/home" bash "$SC" install obs --workdir "$open/mid/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory below one that neither root nor the caller owns" ||
		fail "install below a directory of another owner: rc=$rc $out"
else
	skip "a directory of another owner (no user namespaces here)"
fi
# A closed directory does not help below one that others write: they can put
# another in its place. A sticky one keeps it. The same holds for a graph,
# which needs no closed one.
mkdir -p "$open/c/ws" "$open/c/vol" "$open/gm"
chmod 700 "$open/c"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' >"$open/gm/memory.json"
for mode in 777 775 757; do
	chmod "$mode" "$open"
	out="$(sc install obs --workdir "$open/c/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory below a directory others can write ($mode)" ||
		fail "install below a directory of mode $mode: rc=$rc $out"
	out="$(sc install obs --workdir "$work/ws" --memory "$open/gm/memory.json" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "another user can write a directory above it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a graph below a directory others can write ($mode)" ||
		fail "install --memory below a directory of mode $mode: rc=$rc $out"
done
echo "$open/c/vol" >"$FIX/volpath"
out="$(sc install obs --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/c/vol need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install refuses volumes below a directory others can write" || fail "install with volumes others can replace: rc=$rc $out"
# A directory that is not there yet is not a closed one.
chmod 1777 "$open"
echo "$open/missing/volumes" >"$FIX/volpath"
out="$(sc install obs --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/missing/volumes need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install refuses volumes below a missing directory with no closed one above" ||
	fail "install with volumes below a missing directory: rc=$rc $out"
echo "$FIX/store/volumes" >"$FIX/volpath"
for mode in 1777 755; do
	chmod "$mode" "$open"
	out="$(sc install obs --workdir "$open/c/ws" --memory "$open/gm/memory.json" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install takes a work directory and a graph below a directory others cannot replace them in ($mode)" ||
		fail "install below a directory of mode $mode: rc=$rc $out"
done
chmod 777 "$open/gm"
out="$(sc install obs --workdir "$open/c/ws" --memory "$open/gm/memory.json" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "another user can write a directory above it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install refuses a graph in a directory others can write" || fail "install --memory in an open directory: rc=$rc $out"
chmod 700 "$open"
# What a link names is taken where the link leads: the directory of the
# logins, the runtime directory, podman's storage and its volumes.
# $1 = what lies behind the link, $2 = the refusal, then assignments for the
# environment and the arguments of up.
linked() {
	local label=$1 want=$2 envs=()
	shift 2
	while [[ $1 == *=* ]]; do
		envs+=("$1")
		shift
	done
	out="$("${scenv[@]}" HOME="$work/home" "${envs[@]}" bash "$SC" install obs "$@" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF -- "$want" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses $label behind a link" || fail "install with $label behind a link: rc=$rc $out"
}
mkdir -p "$work/lk/ws/config" "$work/lk/ws/storage/g" "$work/lk/ws/vols/g" "$open/lkvol"
ln -s ws/config "$work/lk/config"
ln -s ws "$work/lk/run"
ln -s ws/storage "$work/lk/storage"
ln -s ws/vols "$work/lk/vols"
ln -s "$open/lkvol" "$work/lk/openvols"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' |
	tee "$work/lk/ws/storage/g/memory.json" >"$work/lk/ws/vols/g/memory.json"
own="the work directory is one you own"
instore="memory.json: it lies in podman's storage"
linked "a work directory that holds the logins" "$own" XDG_CONFIG_HOME="$work/lk/config" --workdir "$work/lk/ws"
linked "a work directory that is the runtime directory" "$own" XDG_RUNTIME_DIR="$work/lk/run" --workdir "$work/lk/ws"
echo "$work/lk/storage" >"$FIX/storepath"
linked "a work directory that holds podman's storage" "$own" --workdir "$work/lk/ws"
linked "a graph in podman's storage" "$instore" --workdir "$work/ws" --memory "$work/lk/ws/storage/g/memory.json"
echo "$FIX/store" >"$FIX/storepath"
echo "$work/lk/vols" >"$FIX/volpath"
linked "a work directory that holds podman's volumes" "$own" --workdir "$work/lk/ws"
linked "a graph in podman's volumes" "$instore" --workdir "$work/ws" --memory "$work/lk/ws/vols/g/memory.json"
chmod 755 "$open"
echo "$work/lk/openvols" >"$FIX/volpath"
linked "podman's volumes below a directory others can enter" "podman's volumes in $work/lk/openvols need" \
	--workdir "$work/ws"
chmod 700 "$open"
echo "$FIX/store/volumes" >"$FIX/volpath"
# No directory here is root's and written by others, which takes root to make,
# and where user namespaces are off none is another user's: the program of
# kept() is given a tree of them. $1 = owner and $2 = mode of /a, which lies
# above /a/b, a closed directory of the caller (uid 1000).
keptprog="$(sed -n '/^kept() {$/,/^}$/p' "$SC" | sed -e '1,2d' -e '/^EOF$/,$d')"
keptfed() {
	python3 -I -c 'import os, sys
tree = {"/": (0, 0o40755), "/a": (int(sys.argv.pop(1)), int(sys.argv.pop(1), 8)), "/a/b": (1000, 0o40700)}
os.getuid = lambda: 1000
os.stat = lambda d: os.stat_result((tree[d][1], 0, 0, 0, tree[d][0], 0, 0, 0, 0, 0))
'"$keptprog" "$1" "$2" /a/b/ws closed
}
[ -n "$keptprog" ] || fail "no program found in kept()"
for fed in "0 777" "0 775" "0 757" "2000 755" "2000 1777" "1000 777"; do
	# shellcheck disable=SC2086  # owner and mode are two arguments
	keptfed $fed
	rc=$?
	[ "$rc" = 1 ] && pass "kept() refuses below a directory of owner and mode $fed" ||
		fail "kept() below a directory of owner and mode $fed: rc=$rc"
done
for fed in "0 755" "0 1777" "1000 755" "1000 1777"; do
	# shellcheck disable=SC2086
	keptfed $fed
	rc=$?
	[ "$rc" = 0 ] && pass "kept() takes a closed directory below one of owner and mode $fed" ||
		fail "kept() below a directory of owner and mode $fed: rc=$rc"
done

# A running container that writes a directory above or below the one mounted
# next could turn it into a link between the checks and the mount.
ln -s ws "$work/wsalias"
for other in "$work" "$work/ws" "$work/ws/sub" "$work/wsalias" "$work/ws/vol/_data"; do
	printf '%s\n' /srv/elsewhere "$other" >"$FIX/others"
	out="$(sc install obs --workdir "$work/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "a running container writes" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory a running container writes around (${other#"$work"}/)" ||
		fail "install while a container writes $other: rc=$rc $out"
done
mkdir -p "$work/memc/g"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' >"$work/memc/g/memory.json"
for other in "$work/memc" "$work/memc/g" "$work/memc/g/sub" "$work/memc/g/_data"; do
	printf '%s\n' "$other" /srv/elsewhere >"$FIX/others"
	out="$(sc install obs --workdir "$work/ws" --memory "$work/memc/g/memory.json" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "memory.json: a running container writes" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a graph a running container writes around (${other#"$work"}/)" ||
		fail "install --memory while a container writes $other: rc=$rc $out"
done
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" >"$FIX/others"
touch "$FIX/ps-fails"
out="$(sc install obs --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "cannot list what the running containers mount" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install starts nothing when the running containers cannot be listed" || fail "install without a container list: rc=$rc $out"
rm "$FIX/ps-fails"
mv "$FIX/github.kept" "$FIX/secrets/$N-github"

# A shared memory graph: its directory is mounted whole and relabelled, so the
# file is alone in it, holds a graph and nothing else, and is not the agent's.
graph='{"type":"entity","name":"a","entityType":"t","observations":["o"]}
{"type":"relation","from":"a","to":"a","relationType":"r"}'
mkdir -p "$work/mem" "$work/mem-two" "$work/mem-hidden" "$work/mem-key" "$work/mem-mixed" "$work/ws/mem" "$work/m,x"
for d in mem mem-two mem-hidden mem-mixed ws/mem "m,x"; do printf '%s\n' "$graph" >"$work/$d/memory.json"; done
touch "$work/mem-two/other" "$work/mem-hidden/.other"
printf 'BZ-SECRET-5\n' >"$work/mem-key/memory.json"
printf '%s\n' '{"type":"login","token":"TEA-SECRET-4"}' >>"$work/mem-mixed/memory.json"
ln -s "$work/ws/mem/memory.json" "$work/graphlink"
ln -s mem "$work/memlink"
while IFS='|' read -r file why; do
	out="$(sc install obs --workdir "$work/ws" --memory "$work/$file" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "$why" <<<"$out" && [ -z "$(leaks <<<"$out")" ] && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses the memory graph $file" || fail "install --memory $file: rc=$rc $out"
done <<'EOF'
mem/none.json|not a file
mem|not a file
mem-two/memory.json|alone in its directory
mem-hidden/memory.json|alone in its directory
mem-key/memory.json|alone in its directory
mem-mixed/memory.json|alone in its directory
ws/mem/memory.json|lies in the work directory
mem/../ws/mem/memory.json|lies in the work directory
graphlink|a symlink leads to it
memlink/memory.json|a symlink leads to it
m,x/memory.json|podman cannot mount
EOF
# Nor is a work directory behind a link: podman would mount where it leads.
mkdir "$work/elsewhere"
ln -s "$work/elsewhere" "$work/ws/sublink"
ln -s ws "$work/wslink"
for d in "$work/wslink" "$work/ws/sublink" "$work/wslink/bin"; do
	out="$(sc install obs --workdir "$d" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "a symlink leads to it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory behind a link (${d#"$work/"})" || fail "install --workdir $d: rc=$rc $out"
done

# Commands are looked up nowhere in the work directory: not on the caller's
# PATH, not behind a link, not on the launcher's own.
n=0
for p in "PATH=$callerpath:$work/ws/bin" "PATH=$callerpath:$tools/wslink" "SKILL_CONTAINER_PATH=$ownpath:$work/ws/bin" \
	"PATH=$callerpath:$work/ws/pathlink" "SKILL_CONTAINER_PATH=$ownpath:$work/ws/pathlink" \
	"PATH=$callerpath:$work/ws" "SKILL_CONTAINER_PATH=$ownpath:$work/ws"; do
	n=$((n + 1))
	out="$("${scenv[@]}" "$p" HOME="$work/home" bash "$SC" install obs --workdir "$work/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory that commands are looked install in ($n)" ||
		fail "install with a PATH entry in the work directory ($n): rc=$rc $out"
done
out="$("${scenv[@]}" "SKILL_CONTAINER_PATH=bin:$ownpath" HOME="$work/home" bash "$SC" install obs --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "not an absolute path" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
	pass "install refuses a relative entry among the launcher's own directories" ||
	fail "install with a relative SKILL_CONTAINER_PATH entry: rc=$rc $out"
# An entry with . or .. is not the directory it reads as; a name that starts
# with a dot is.
mkdir -p "$tools/.dot/..dot"
n=0
for p in "PATH=$callerpath:$tools/userbin/../userbin" "PATH=$callerpath:$tools/./userbin" "PATH=$callerpath:$tools/userbin/." \
	"PATH=$callerpath:$tools/userbin/.." "SKILL_CONTAINER_PATH=$ownpath/../bin" "LD_LIBRARY_PATH=$tools/../lib" \
	"LD_PRELOAD=$tools/./x.so"; do
	n=$((n + 1))
	out="$("${scenv[@]}" "$p" HOME="$work/home" bash "$SC" install obs --workdir "$work/ws" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "with a . or .. in it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses an entry with . or .. in it ($n)" || fail "install with $p: rc=$rc $out"
done
out="$("${scenv[@]}" PATH="$callerpath:$tools/.dot:$tools/.dot/..dot" HOME="$work/home" bash "$SC" help 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q '^usage:' <<<"$out" && pass "a PATH entry whose name starts with a dot is taken" ||
	fail "a dot-directory on PATH: rc=$rc $out"

# Nor are libraries: no entry of the loader's lists lies in the work directory,
# behind a link, after a `;` or after a space.
mkdir "$tools/lib"
ld() { (cd "$work" && "${scenv[@]}" "$1" HOME="$work/home" bash "$SC" "${@:2}" 2>&1); }
n=0
for p in "LD_LIBRARY_PATH=$work/ws/bin" "LD_LIBRARY_PATH=$work/ws" "LD_LIBRARY_PATH=$tools/wslink" "LD_LIBRARY_PATH=$tools/lib;$work/ws/bin" \
	"LD_PRELOAD=$work/ws/bin/x.so" "LD_PRELOAD=$tools/lib/a.so $work/ws/bin/x.so" \
	"LD_AUDIT=$tools/lib/a.so:$work/ws/bin/x.so"; do
	n=$((n + 1))
	out="$(ld "$p" install obs --workdir "$work/ws")"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses a work directory that libraries are looked install in ($n)" ||
		fail "install with a loader entry in the work directory ($n): rc=$rc $out"
done
# An empty or relative entry is looked up where a command starts.
n=0
for p in "LD_LIBRARY_PATH=$tools/lib:" "LD_LIBRARY_PATH=:$tools/lib" "LD_LIBRARY_PATH=lib" \
	"LD_LIBRARY_PATH=$tools/lib;lib" "LD_PRELOAD=lib/x.so" "LD_PRELOAD=$tools/lib/a.so lib/x.so" \
	"LD_AUDIT=lib/x.so" "LD_AUDIT=$tools/lib/a.so:lib/x.so"; do
	n=$((n + 1))
	out="$(ld "$p" install obs --workdir "$work/ws")"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "not an absolute path" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses an empty or relative entry in a list of the loader ($n)" ||
		fail "install with an empty or relative loader entry ($n): rc=$rc $out"
done
for p in "LD_LIBRARY_PATH=$tools/"'$LIB' "LD_PRELOAD=$tools/"'$LIB/x.so'; do
	out="$(ld "$p" install obs --workdir "$work/ws")"
	rc=$?
	[ "$rc" != 0 ] && grep -qF 'with a $' <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" &&
		pass "install refuses an entry the loader would rewrite (${p%%=*})" || fail "install with $p: rc=$rc $out"
done

# From here on no opencode starts on the host: the client's is in a container.
oc0="$(wc -l <"$FIX/opencode-calls")"
printf '%s\n' '{"data":[{"id":"per_a1","projectID":"prj_main","action":"shell","resource":"*"},{"id":"per_b2","projectID":"prj_main","action":"edit","resource":"*"}]}' \
	>"$FIX/saved"
sessions "[{\"id\":\"ses_u1\",\"permissions\":$allow}]"
kept_login cred_old1
# A work directory named from the current one. install validates it and writes
# the unit; up starts it.
out="$(cd "$work" && sc install obs --workdir ws --image img:1 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ -f "$work/home/.config/containers/systemd/$N-agent@obs.container.d/10-workdir.conf" ] &&
	[ -L "$work/home/.config/containers/systemd/$N-agent@obs.container" ] &&
	pass "install writes the unit drop-in" || fail "install: rc=$rc $out"
drop="$(cat "$work/home/.config/containers/systemd/$N-agent@obs.container.d/10-workdir.conf")"
[ "$drop" = "$(printf '%s\n' "# Written by skill-container install obs. Do not edit: install writes it again." \
	"[Container]" "Volume=$work/ws:$work/ws:Z" "WorkingDir=$work/ws" "Image=img:1")" ] &&
	pass "install writes the work directory and the image into the drop-in" || fail "the drop-in: $drop"
[ "$(cat "$work/config/skill-container/$N/obs.dir")" = "$(printf '%s\n' "$work/ws" "$work/ws" img:1)" ] &&
	pass "install writes the state file" || fail "the state file"
[ "$(grep -c daemon-reload "$FIX/systemctl-calls")" = 1 ] &&
	[ -f "$work/home/.config/containers/systemd/$N-agent@.container" ] &&
	[ -f "$work/home/.config/systemd/user/$N-agent@.service.d/20-depend.conf" ] &&
	[ -f "$work/home/.config/systemd/user/$N-relay@.service" ] &&
	[ -f "$work/home/.config/systemd/user/$N-update@.timer" ] &&
	pass "install installs the units" || fail "install and the units"
# The six units of this skill, as they ship: the update runs the fixed copy.
units="$HERE/../../contrib/container/systemd"
copied=0
for f in "containers/systemd/$N-agent@.container" "systemd/user/$N-agent@.service.d/10-relay.conf" \
	"systemd/user/$N-agent@.service.d/20-depend.conf" "systemd/user/$N-relay@.service" \
	"systemd/user/$N-update@.service" "systemd/user/$N-update@.timer"; do
	cmp -s "$work/home/.config/$f" "$units/${f#*/*/}" && copied=$((copied + 1))
done
[ "$copied" = 6 ] && grep -qxF "ExecStart=%h/.local/bin/openqa-container update %i" "$units/$N-update@.service" &&
	pass "install copies the six openqa units, whose update runs the fixed copy" ||
	fail "install copied $copied of the six units; the update runs: $(grep '^ExecStart' "$units/$N-update@.service")"
# up starts nothing while a login is missing.
for s in openqa github bugzilla model ssh; do
	mv "$FIX/secrets/$N-$s" "$FIX/$s.kept"
	out="$(sc up obs 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "no secret $N-$s" <<<"$out" && ! grep -q '^start ' "$FIX/systemctl-calls" &&
		[ ! -e "$FIX/secrets/$N-obs-server-password" ] &&
		pass "up without the $s secret starts nothing" || fail "up without the $s secret: rc=$rc $out"
	mv "$FIX/$s.kept" "$FIX/secrets/$N-$s"
done
: >"$FIX/systemctl-calls"
out="$(sc up obs --model prov/model 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qx "start $N-agent@obs.service" "$FIX/systemctl-calls" &&
	pass "up starts the unit" || fail "up and the unit: rc=$rc $out"
order="$(grep -o 'api DELETE [^ ]*\|api PATCH [^ ]*\|auth import' "$FIX/podman-calls" | tr '\n' ' ')"
[ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ "$(jq -c 'map(.permissions)' "$FIX/sessions")" = "[[]]" ] &&
	grep -qF "removed the saved approvals and session rules" <<<"$out" &&
	[ "$order" = "api DELETE /api/permission/saved/per_a1 api DELETE /api/permission/saved/per_b2 api PATCH /api/session/ses_u1 api DELETE /api/credential/cred_old1 auth import " ] &&
	pass "up removes the saved approvals and session rules before the model credential goes in" ||
	fail "up and saved approvals: $order / $out"
[ "$(jq -c .data "$FIX/logins")" = "[]" ] && [[ $order == *"api DELETE /api/credential/cred_old1 auth import " ]] &&
	[ -z "$(leaks <<<"$out")" ] &&
	pass "up removes the model login the state volume kept, then imports the secret's" ||
	fail "up and a kept model login: $order / $(jq -c '.data | map(.id)' "$FIX/logins")"
[ "$rc" = 0 ] && grep -qxF "obs is up, work directory $work/ws" <<<"$out" && ! stopped && pass "up says where the instance works" ||
	fail "up: rc=$rc $out"
pw="$(secret obs-server-password)"
[ "${#pw}" = 32 ] && [ "$(secret obs-server-password | wc -l)" = 0 ] &&
	grep -qx "secret create --replace $N-obs-server-password -" "$FIX/podman-calls" &&
	pass "up makes a 24-byte server password without a newline" ||
	fail "the server password: ${#pw} characters"
# The lockdown lives in the unit file the service starts: every flag the
# pilot checked on the podman command line is there, and the service refuses
# the locked-down shape no update may change.
missed=0
for line in "UserNS=keep-id" "ReadOnly=true" "DropCapability=all" "NoNewPrivileges=true" "Pull=never" \
	"Secret=openqa-%i-server-password,type=env,target=OPENCODE_PASSWORD" \
	"Secret=openqa-openqa,target=/agent-logins/openqa/client.conf,uid=%U,gid=%G,mode=0400" \
	"Secret=openqa-github,target=/agent-logins/gh/hosts.yml,uid=%U,gid=%G,mode=0400" \
	"Secret=openqa-bugzilla,target=/agent-logins/bugzilla/api-key,uid=%U,gid=%G,mode=0400" \
	"Secret=openqa-ssh,target=/agent-logins/ssh/id_ed25519,uid=%U,gid=%G,mode=0400" \
	"StartLimitIntervalSec=600" "StartLimitBurst=5" "SuccessExitStatus=143" \
	"Volume=openqa-%i-state:/home/agent/.local/share/opencode:U" \
	"Volume=openqa-%i-memory:/home/agent/.local/share/mcp-memory:U" \
	"Volume=openqa-%i-toolstate:/home/agent/.local/state:U" \
	"Volume=openqa-%i-scratch:/var/tmp" \
	"Exec=opencode serve --hostname 127.0.0.1 --port 4096"; do
	grep -qxF "$line" "$units/openqa-agent@.container" ||
		missed=$((missed + 1))
done
# Those five secrets and no other: no osc or tea login goes in.
[ "$missed" = 0 ] && [ "$(grep -c '^Secret=' "$units/openqa-agent@.container")" = 5 ] &&
	pass "the unit runs the container locked down, with its secrets and volumes" ||
	fail "the unit lost its lockdown"
# The units name one another, the container, its image and settings as the
# launcher does: by this skill's name.
missed=0
for line in "agent@.container|ContainerName=openqa-%i-agent" "agent@.container|Image=localhost/openqa-agent:latest" \
	"agent@.container|Volume=%h/.config/skill-container/openqa:/home/agent/.config/opencode:ro,Z" \
	"agent@.service.d/10-relay.conf|Wants=openqa-relay@%i.service" \
	"agent@.service.d/20-depend.conf|ExecStop=/usr/bin/podman rm -v -f -i --depend openqa-%i-agent" \
	"agent@.service.d/20-depend.conf|ExecStopPost=/usr/bin/podman rm -v -f -i --ignore --depend openqa-%i-agent" \
	"relay@.service|BindsTo=openqa-agent@%i.service" "relay@.service|After=openqa-agent@%i.service" \
	"relay@.service|ExecStart=/usr/bin/socat UNIX-LISTEN:%t/openqa-%i.sock,mode=0600,unlink-early,fork 'EXEC:\"/usr/bin/podman exec -i openqa-%i-agent socat - TCP:127.0.0.1:4096\"'" \
	"update@.timer|Unit=openqa-update@%i.service"; do
	grep -qxF "${line#*|}" "$units/$N-${line%%|*}" || missed=$((missed + 1))
done
[ "$missed" = 0 ] && ! grep -rq 'opensuse-packaging\|skill-container update' "$units" &&
	pass "the units name one another and the container by the skill's name" || fail "the units' names: $missed missed"
! grep -qF "$N-model" <<<"$out" && grep -qF MODEL-SECRET-6 "$FIX/imported" &&
	grep -q "^exec -i $N-obs-agent opencode auth import --server http://127.0.0.1:4096$" "$FIX/podman-calls" &&
	pass "the model credential is imported through a pipe, not mounted" ||
	fail "the model import: $(grep 'auth import' "$FIX/podman-calls")"
[ "$(jq -r .model "$work/config/skill-container/$N/opencode.json")" = prov/model ] &&
	pass "the model choice is in the user config" || fail "the user config"
[ -z "$(leaks "$FIX/podman-calls")" ] && [ -z "$(leaks <<<"$out")" ] && ! grep -qF "$pw" <<<"$out" &&
	pass "up puts no secret on a command line or the terminal" || fail "up leaks a secret"

# attach and run start the client in a second container, made from the image
# the server's container runs. The whole command, as for up: a mount of the
# host, a published port or a variable of the caller fails here.
inner=http://127.0.0.1:4096
cl=(run --rm --pull=never --network "container:$N-obs-agent" --userns "container:$N-obs-agent"
	--user "$(id -u):$(id -g)" --read-only --cap-drop=all --security-opt no-new-privileges --init
	--http-proxy=false --log-driver=none
	--secret "$N-obs-server-password,type=env,target=OPENCODE_PASSWORD"
	--env FORCE_HYPERLINK=0 --env TERM --env COLORTERM
	--tmpfs "/home/agent/.local/share/opencode:rw,mode=0700,U"
	--tmpfs "/home/agent/.local/state:rw,mode=0700,U" --tmpfs "/home/agent/.cache:rw,mode=0700,U"
	--tmpfs "$work/ws:ro,mode=0555,notmpcopyup" --workdir "$work/ws")
# The last client's container against the one expected, and where they differ.
client() { [ "$(tail -1 "$FIX/client-calls")" = "${cl[*]} $*" ]; }
differs() { diff <(printf '%s\n' "${cl[@]}" "$@") <(tail -1 "$FIX/client-calls" | tr ' ' '\n'); }
rm -f "$FIX/sed-password"
out="$(cd / && VISUAL=vi EDITOR=vi FORCE_HYPERLINK=1 http_proxy=http://proxy.example:3128 sc run obs --continue hello 2>&1)"
rc=$?
[ "$rc" = 0 ] && client "$img" opencode run --server "$inner" --continue hello &&
	pass "run starts the client in a container of its own: the server's image, network and users, nothing of the host" ||
	fail "run: rc=$rc $out / $(differs "$img" opencode run --server "$inner" --continue hello)"
grep -qx "inspect --format {{.Image}} $N-obs-agent" "$FIX/podman-calls" &&
	pass "run takes the image from the server's container, by its id" || fail "run did not ask for the server's image"
[ -s "$FIX/sed-password" ] && ! grep -qv '^unset$' "$FIX/sed-password" &&
	pass "the filter of run starts without the server password" || fail "the filter of run got the password"
# Called from the work directory, the launcher's commands still start in /.
out="$(cd "$work/ws" && sc run obs hello 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ ! -e "$FIX/cwd-leak" ] && client "$img" opencode run --server "$inner" hello &&
	pass "run from the work directory starts no command there" ||
	fail "run from the work directory: rc=$rc $out / $(sort -u "$FIX/cwd-leak" 2>/dev/null | tr '\n' ' ')"
# attach gives the client's container the caller's terminal, and starts
# nothing without one at both ends.
rm -f "$FIX/client-tty"
out="$(tty attach obs --session s1 2>&1)"
rc=$?
[ "$rc" = 0 ] && client --interactive --tty --detach-keys= "$img" opencode --server "$inner" --session s1 &&
	[ "$(cat "$FIX/client-tty")" = yes ] &&
	pass "attach starts the client in a container of its own, on the caller's terminal" ||
	fail "attach: rc=$rc $out / $(differs --interactive --tty --detach-keys= "$img" opencode --server "$inner" --session s1)"
n0="$(wc -l <"$FIX/podman-calls")"
out="$(sc attach obs --session s1 2>&1 </dev/null)"
rc=$?
[ "$rc" = 1 ] && grep -qF "attach needs a terminal" <<<"$out" && [ "$(wc -l <"$FIX/podman-calls")" = "$n0" ] &&
	pass "attach without a terminal starts nothing" || fail "attach without a terminal: rc=$rc $out"
n=0
# The third: the output is no terminal, the error stream is one.
for half in '2>&1 < /dev/null' '2>&1 | while IFS= read -r l; do printf "%s\n" "$l"; done' '> /dev/null'; do
	n=$((n + 1))
	out="$(pty "${scenv[@]}" HOME="$work/home" SC="$SC" bash -o pipefail -c "bash \"\$SC\" attach obs $half" 2>&1)"
	rc=$?
	[ "$rc" = 1 ] && grep -qF "attach needs a terminal" <<<"$out" && [ "$(wc -l <"$FIX/podman-calls")" = "$n0" ] &&
		pass "attach with a terminal at one end only starts nothing ($n)" || fail "attach with half a terminal ($n): rc=$rc $out"
done
touch "$FIX/escapes"
tty attach obs >/dev/null 2>&1
rc=$?
[ "$rc" = 7 ] && pass "attach ends with the client's exit status" || fail "attach and the client's exit status: rc=$rc"
rm "$FIX/escapes"
# attach and run pass on the flags the launcher names and no other: not the
# three that answer every permission with yes, in any form opencode reads, and
# not the one that names a file: the client's container holds none of the caller's.
out="$(sc run obs -c --session=s1 --fork -m prov/model --agent build --format json --title=-t --thinking hello there 2>&1)"
rc=$?
[ "$rc" = 0 ] && client "$img" opencode run --server "$inner" -c --session=s1 --fork -m prov/model --agent build --format json --title=-t --thinking hello there &&
	pass "run passes on the flags it names" || fail "run with its flags: rc=$rc $out / $(tail -1 "$FIX/client-calls")"
out="$(tty attach obs --continue -s s1 --prompt=hi 2>&1)"
rc=$?
[ "$rc" = 0 ] && client --interactive --tty --detach-keys= "$img" opencode --server "$inner" --continue -s s1 --prompt=hi &&
	pass "attach passes on the flags it names" || fail "attach with its flags: rc=$rc $out / $(tail -1 "$FIX/client-calls")"
calls="$(wc -l <"$FIX/client-calls") $(wc -l <"$FIX/podman-calls")"
while IFS='|' read -r refused why; do
	# shellcheck disable=SC2086
	out="$(sc $refused 2>&1 </dev/null)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF -- "$why" <<<"$out" &&
		[ "$(wc -l <"$FIX/client-calls") $(wc -l <"$FIX/podman-calls")" = "$calls" ] &&
		pass "refused before anything runs: $refused" || fail "$refused: rc=$rc $out"
done <<'EOF'
run obs --auto hello|run passes on these opencode flags only
run obs --auto=true hello|run passes on these opencode flags only
run obs --yolo hello|run passes on these opencode flags only
run obs --dangerously-skip-permissions hello|run passes on these opencode flags only
run obs --no-auto hello|run passes on these opencode flags only
run obs hello --auto|run passes on these opencode flags only
run obs -c --auto hello|run passes on these opencode flags only
run obs -- --auto|run passes on these opencode flags only
run obs -- hello|run passes on these opencode flags only
run obs hello -- --yolo|run passes on these opencode flags only
run obs --help|run passes on these opencode flags only
run obs --standalone hello|run passes on these opencode flags only
run obs --server http://127.0.0.1:1 hello|run passes on these opencode flags only
run obs -x hello|run passes on these opencode flags only
run obs -cs s1 hello|run passes on these opencode flags only
run obs -f note hello|run passes on these opencode flags only
run obs --file=note hello|run passes on these opencode flags only
run obs --prompt hi hello|run passes on these opencode flags only
run obs -s --auto hello|-s needs a value
run obs -s -c hello|-s needs a value
run obs --model --agent build hello|--model needs a value
run obs hello --title|--title needs a value
run obs --continue=--auto hello|--continue takes no value
run obs -c=--auto hello|-c takes no value
run obs --thinking=--auto hello|--thinking takes no value
run obs --fork=x hello|--fork takes no value
attach obs --auto|attach passes on these opencode flags only
attach obs --auto=true|attach passes on these opencode flags only
attach obs --yolo|attach passes on these opencode flags only
attach obs --dangerously-skip-permissions|attach passes on these opencode flags only
attach obs -c --auto|attach passes on these opencode flags only
attach obs -- --auto|attach passes on these opencode flags only
attach obs --|attach passes on these opencode flags only
attach obs --print-logs|attach passes on these opencode flags only
attach obs --model prov/model|attach passes on these opencode flags only
attach obs --fork|attach passes on these opencode flags only
attach obs -f note|attach passes on these opencode flags only
attach obs -s --auto|-s needs a value
attach obs --prompt|--prompt needs a value
attach obs --continue=--auto|--continue takes no value
attach obs serve|attach takes flags only
attach obs /tmp|attach takes flags only
attach obs --session=s1 serve|attach takes flags only
attach obs -c serve|attach takes flags only
attach obs --prompt auth list|attach takes flags only
attach obs -s s1 web|attach takes flags only
EOF
# One word made of two flags of the list is no flag of it.
for refused in "attach|-c --continue" "attach|-s --session=--auto" "run|--title --thinking" "run|--agent --format=--auto"; do
	out="$(sc "${refused%%|*}" obs "${refused#*|}" hello 2>&1 </dev/null)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF -- "${refused%%|*} passes on these opencode flags only" <<<"$out" &&
		[ "$(wc -l <"$FIX/client-calls") $(wc -l <"$FIX/podman-calls")" = "$calls" ] &&
		pass "refused before anything runs: one word '${refused#*|}'" || fail "one word '${refused#*|}': rc=$rc $out"
done
! grep -qF "$pw" "$FIX/client-calls" "$FIX/podman-calls" && pass "the password is on no command line" ||
	fail "the password is on a command line"
[ -z "$(pwfiles)" ] && pass "up, run and attach leave the password in no file" ||
	fail "the password is in: $(pwfiles)"
! grep -q "^secret inspect.* $N-server-password$" "$FIX/podman-calls" &&
	pass "the launcher does not read the server password back: podman hands it to the containers" ||
	fail "the launcher read the server password back"

# The state volume is the agent's to write: an approval in it ends with the session.
approval per_c3
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] &&
	pass "run removes a saved approval, then starts the client" || fail "run with a saved approval: rc=$rc $out"
approval ../session/ses_1
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "DELETE /api/permission/saved/.." "$FIX/podman-calls" &&
	pass "run refuses a saved approval whose id is not one" || fail "run with a made-up id: rc=$rc $out"
approval per_d4
touch "$FIX/keeps"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses while a saved approval stays" ||
	fail "run with an approval that stays: rc=$rc $out"
rm "$FIX/keeps"
echo '{"error":"no"}' >"$FIX/saved"
: >"$FIX/client-calls"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when the saved approvals cannot be listed" ||
	fail "run without a list of approvals: rc=$rc $out"
echo '{"data":[]}' >"$FIX/saved"

# An approval belongs to a project: one of a project the server lists is found
# by that project's id, one of a project it does not list by the empty id.
echo '[{"id":"prj_main"},{"id":"prj_sub"}]' >"$FIX/projects"
approval per_s1 prj_sub
touch "$FIX/empty-lists-none"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] &&
	pass "run removes the approval of another project the server lists" ||
	fail "run with an approval of a listed project: rc=$rc $out"
rm "$FIX/empty-lists-none"
echo '[]' >"$FIX/projects"
approval per_e1 prj_evil
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] &&
	pass "run removes the approval of a project the server does not list" ||
	fail "run with an approval of an unlisted project: rc=$rc $out"
n=0
for projects in '{"error":"no"}' '' '[{"id":"../x"}]'; do
	n=$((n + 1))
	printf '%s' "$projects" >"$FIX/projects"
	: >"$FIX/client-calls"
	out="$(sc run obs hello 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "projectID=.." "$FIX/podman-calls" &&
		pass "run refuses when the projects cannot be listed ($n)" ||
		fail "run without a list of projects ($n): rc=$rc $out"
done
echo '[{"id":"prj_main"},{"id":"prj_sub"}]' >"$FIX/projects"
touch "$FIX/id-answers-nothing"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when a project's approvals do not come" ||
	fail "run without an answer for a project: rc=$rc $out"
rm "$FIX/id-answers-nothing"
echo '[{"id":"prj_main"}]' >"$FIX/projects"

# So are a session's own rules: the one on the second page of the list as well.
sessions "[{\"id\":\"ses_a\",\"permissions\":null},{\"id\":\"ses_b\",\"permissions\":[]},{\"id\":\"ses_c\",\"permissions\":$allow}]"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(jq -c 'map(.permissions)' "$FIX/sessions")" = "[null,[],[]]" ] && [ -s "$FIX/client-calls" ] &&
	pass "run clears the rules of a session on a later page, then starts the client" ||
	fail "run with session rules: rc=$rc $out"
sessions "[{\"id\":\"ses_d\",\"permissions\":$allow}]"
touch "$FIX/keeps-rules"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses while a session keeps its rules" ||
	fail "run with rules that stay: rc=$rc $out"
rm "$FIX/keeps-rules"
sessions "[{\"id\":\"../permission/saved/x\",\"permissions\":$allow}]"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "PATCH /api/session/.." "$FIX/podman-calls" &&
	pass "run refuses a session whose id is not one" || fail "run with a made-up session id: rc=$rc $out"
sessions '{"error":"no"}'
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when the sessions cannot be listed" ||
	fail "run without a list of sessions: rc=$rc $out"
sessions '[{"id":"ses_e","permissions":null}]'
touch "$FIX/bad-cursor"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a list whose next page is not named by a cursor" ||
	fail "run with a made-up cursor: rc=$rc $out"
rm "$FIX/bad-cursor"
touch "$FIX/endless"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a session list that does not end" ||
	fail "run with an endless session list: rc=$rc $out"
rm "$FIX/endless"
sessions '[]'
# What podman says of the container reaches the command line of the client's:
# an image that is no id, or a work directory podman cannot mount, starts none.
n=0
for bad in "" "${img:1}" "sha256:$img" "--volume=/:/host"; do
	n=$((n + 1))
	printf '%s\n' "$bad" >"$FIX/image"
	out="$(sc run obs hello 2>&1)"
	rc=$?
	[ "$rc" = 1 ] && [ ! -s "$FIX/client-calls" ] && [[ $out == *"cannot read the image of $N-obs-agent"* ]] &&
		pass "run refuses a container whose image is not named by its id ($n)" ||
		fail "run with the image '$bad': rc=$rc $out"
done
printf '%s\n' "$img" >"$FIX/image"
n=0
for wd in "" ws / "$work/a,b" "$work/a:b"; do
	n=$((n + 1))
	printf %s "$wd" >"$FIX/workdir"
	out="$(sc run obs hello 2>&1)"
	rc=$?
	[ "$rc" = 1 ] && [ ! -s "$FIX/client-calls" ] && [[ $out == *"cannot read the work directory of $N-obs-agent"* ]] &&
		pass "run refuses a container whose work directory is no path to mount ($n)" ||
		fail "run with the work directory '$wd': rc=$rc $out"
done
printf %s "$work/ws" >"$FIX/workdir"

# A reply reaches the terminal as text and colour, each stream on its own, and
# the client's exit status is the launcher's.
touch "$FIX/escapes"
sc run obs hello >"$work/rout" 2>"$work/rerr"
rc=$?
[ "$rc" = 7 ] && cmp -s "$work/rout" <(printf 'out]52;c;QUJD\033[31mred\033[0m[2Jx[35m2Jy0;t\nctl<>\n') &&
	cmp -s "$work/rerr" <(printf 'err]0;title\033[1mbold\033[0m\nctl<>\n') &&
	pass "run prints a reply without its control characters, colours apart" ||
	fail "run and control characters: rc=$rc $(od -c "$work/rout" | head -8) / $(od -c "$work/rerr" | head -8)"
rm "$FIX/escapes"

# Nothing the agent left in the work directory runs on the host: no command is
# looked up there.
: >"$FIX/client-calls"
n=0
base="$tools/userbin:$PATH"
for p in ":$base" ".:$base" "bin:$base" "$base:" "$tools/userbin:.:$PATH" "$tools/userbin::$PATH"; do
	n=$((n + 1))
	out="$(cd "$work" && "${scenv[@]}" PATH="$p" HOME="$work/home" bash "$SC" run obs hello 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && [ ! -e "$FIX/planted-client" ] && [ ! -s "$FIX/client-calls" ] &&
		pass "run refuses a PATH that looks commands up in the work directory ($n)" ||
		fail "run with an empty or relative PATH entry ($n): rc=$rc $out"
done
# Nor is a library loaded from there into the launcher's commands.
n=0
for p in "LD_LIBRARY_PATH=$tools/lib:" "LD_LIBRARY_PATH=lib" "LD_LIBRARY_PATH=$work/ws/bin" \
	"LD_PRELOAD=$tools/lib/a.so lib/x.so" "LD_PRELOAD=$work/ws/bin/x.so" "LD_AUDIT=lib/x.so" \
	"LD_AUDIT=$work/ws/bin/x.so" "LD_LIBRARY_PATH=$tools/"'$LIB'; do
	n=$((n + 1))
	out="$(ld "$p" run obs hello)"
	rc=$?
	[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] &&
		pass "run refuses a list of the loader that reaches the work directory ($n)" ||
		fail "run with $p: rc=$rc $out"
done
for p in "LD_LIBRARY_PATH=$tools/lib" "LD_LIBRARY_PATH=" "LD_PRELOAD=libc.so.6"; do
	: >"$FIX/client-calls"
	out="$(ld "$p" run obs hello)"
	rc=$?
	[ "$rc" = 0 ] && [ -s "$FIX/client-calls" ] && pass "run takes ${p:-an empty list}" || fail "run with $p: rc=$rc $out"
done
: >"$FIX/client-calls"
out="$("${scenv[@]}" PATH="$callerpath:$work/ws/bin" HOME="$work/home" bash "$SC" run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && [ ! -s "$FIX/client-calls" ] &&
	pass "run refuses a PATH entry in the work directory" || fail "run with a PATH entry in the work directory: rc=$rc $out"

out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "is already running" <<<"$out" && [ "$(grep -c '^start ' "$FIX/systemctl-calls")" = 1 ] &&
	[ "$(secret obs-server-password)" = "$pw" ] &&
	pass "up leaves a running instance and its password alone" || fail "up on a running instance: rc=$rc $out"
# The instance's own mounts do not stop it; another container's do.
printf '%s\n' "$work/ws" >"$FIX/others"
printf '%s\n' "$N-obs-agent" >"$FIX/own-name"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "is already running" <<<"$out" &&
	pass "up ignores what its own container writes" || fail "up and its own mounts: rc=$rc $out"
rm "$FIX/own-name"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "a running container writes $work/ws" <<<"$out" &&
	pass "up refuses what another container writes" || fail "up and another container's mounts: rc=$rc $out"
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" >"$FIX/others"
# A server that does not answer gets no client and gives no password.
touch "$FIX/silent"
for c in "run obs hello" "attach obs" "password obs"; do
	: >"$FIX/client-calls"
	: >"$FIX/podman-calls"
	# shellcheck disable=SC2086  # the command and its arguments
	if [ "$c" = "attach obs" ]; then out="$(tty $c 2>&1)"; else out="$(sc $c 2>&1)"; fi
	rc=$?
	[ "$rc" != 0 ] && grep -qF "the server of obs does not answer" <<<"$out" && [ ! -s "$FIX/client-calls" ] &&
		! grep -qF "$pw" <<<"$out" && ! grep -q 'permission/saved\|^run ' "$FIX/podman-calls" &&
		pass "${c%% *} refuses a server that does not answer" || fail "${c%% *} with a server that does not answer: rc=$rc $out"
done
rm "$FIX/silent"

# Starts that must leave no container behind.
restart() {
	sc down obs >/dev/null
	: >"$FIX/podman-calls"
	: >"$FIX/systemctl-calls"
	rm -f "$FIX/imported"
}
# A clock at the end of its range: the five minutes start_wait gives the server
# are over at once.
late() { "${scenv[@]}" SECONDS=9223372036854775800 HOME="$work/home" bash "$SC" "$@"; }
restart
touch "$FIX/silent"
out="$(late up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qxF "skill-container: the server does not answer; the unit is stopped" <<<"$out" &&
	! grep -q 'permission/saved\|/api/credential' "$FIX/podman-calls" &&
	pass "a server that never answers: the unit is stopped, nothing is sent" || fail "a server that never answers: rc=$rc $out"
# What the server printed on the way is shown as text.
restart
touch "$FIX/log-escapes"
late up obs >"$work/rout" 2>&1
rc=$?
[ "$rc" != 0 ] && grep -qaF "log]0;tline" "$work/rout" && grep -qaxF "ctl<>" "$work/rout" &&
	! grep -qa $'[\033\007]' "$work/rout" &&
	pass "a failed start shows the server's output without control characters" ||
	fail "failed start and control characters: rc=$rc $(od -c "$work/rout" | head -12)"
rm "$FIX/log-escapes" "$FIX/silent"
# A server that answers after a while: up waits for it, then goes on.
restart
echo 2 >"$FIX/answers-after"
: >"$FIX/project-calls"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" = 0 ] && ! stopped && [ -e "$FIX/imported" ] && grep -qxF "obs is up, work directory $work/ws" <<<"$out" &&
	[ "$(grep -c . "$FIX/project-calls")" -ge 3 ] &&
	pass "up waits until the server answers, then sends the credential" || fail "a server that answers late: rc=$rc $out"
rm "$FIX/answers-after"
# Every probe of a start writes to the journal: half a minute of one a second,
# then one every five seconds.
restart
echo 35 >"$FIX/answers-after"
: >"$FIX/sleep-calls"
touch "$FIX/sleep-fast"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(grep -cx 1 "$FIX/sleep-calls")" = 30 ] && [ "$(grep -cx 5 "$FIX/sleep-calls")" = 5 ] &&
	[ "$(wc -l <"$FIX/sleep-calls")" = 35 ] && [ "$(head -n 30 "$FIX/sleep-calls" | sort -u)" = 1 ] &&
	pass "a slow start probes each second for 30 probes, then every five seconds" ||
	fail "the pace of a slow start: rc=$rc $(sort "$FIX/sleep-calls" | uniq -c | tr '\n' ' ') $out"
rm -f "$FIX/sleep-fast" "$FIX/answers-after"
restart
approval per_e5
touch "$FIX/keeps"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] &&
	pass "a saved approval that stays: the unit is stopped, no credential is sent" ||
	fail "up with an approval that stays: rc=$rc $out"
rm "$FIX/keeps"
echo '{"data":[]}' >"$FIX/saved"
restart
touch "$FIX/stops"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ ! -e "$FIX/imported" ] &&
	pass "a container that stopped: no credential is sent" || fail "stopped container: rc=$rc $out"
rm "$FIX/stops"
restart
touch "$FIX/run-fails"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] &&
	pass "a container podman made and could not start is removed" || fail "a start podman failed: rc=$rc $out"
rm "$FIX/run-fails"
restart
touch "$FIX/import-fails"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && pass "a failed import: the unit is stopped" ||
	fail "failed import: rc=$rc $out"
rm "$FIX/import-fails"
restart
echo '{"error":"no"}' >"$FIX/logins"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "podman volume rm" <<<"$out" &&
	pass "model logins that cannot be listed: the unit is stopped, no credential is sent" ||
	fail "up without a list of model logins: rc=$rc $out"
restart
kept_login 'cred_a/../../session'
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] &&
	! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" &&
	pass "a kept model login with an unexpected id: no call is made with it, no credential is sent" ||
	fail "up with a model login id: rc=$rc $out"
restart
kept_login cred_old1
touch "$FIX/login-stays"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] &&
	grep -qF "podman volume rm" <<<"$out" &&
	pass "a kept model login that stays: the unit is stopped, no credential is sent" ||
	fail "up with a model login that stays: rc=$rc $out"
rm "$FIX/login-stays"
# An id is one value in the answer; split into lines, a line break in it makes two.
for id in 'cred_x\ncred_y' 'cred_a\n' ''; do
	restart
	kept_login "$id"
	out="$(sc up obs 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] &&
		! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" && grep -qF "podman volume rm" <<<"$out" &&
		pass "a kept model login with the id '$id': no call is made with it, no credential is sent" ||
		fail "up with the model login id '$id': rc=$rc $out"
done
# Nor is an id that is no text, whatever it holds.
restart
echo '{"data":[{"id":{"k":"SECRET-7"}}]}' >"$FIX/logins"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] &&
	! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" &&
	pass "a kept model login whose id is no text: no call is made, nothing of it is shown" ||
	fail "up with a model login id that is no text: rc=$rc $out"
restart
kept_login cred_old1
touch "$FIX/login-ghost"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] &&
	grep -q 'api DELETE /api/credential/cred_old1' "$FIX/podman-calls" && grep -qF "podman volume rm" <<<"$out" &&
	pass "a kept model login the server only claims to remove: the unit is stopped, no credential is sent" ||
	fail "up with a model login removed in name only: rc=$rc $out"
rm "$FIX/login-ghost"
restart
echo '{"data":[]}' >"$FIX/logins"
echo '{"error":"no"}' >"$FIX/logins-next"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "podman volume rm" <<<"$out" &&
	pass "model logins that cannot be listed again: the unit is stopped, no credential is sent" ||
	fail "up without a second list of model logins: rc=$rc $out"
# A list that could not be read is not an empty one, whatever the next one says.
restart
echo '{"error":"no"}' >"$FIX/logins"
echo '{"data":[]}' >"$FIX/logins-next"
out="$(sc up obs 2>&1)"
rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] &&
	pass "model logins that can be listed only the second time: the unit is stopped, no credential is sent" ||
	fail "up without a first list of model logins: rc=$rc $out"
rm -f "$FIX/logins-next"
echo '{"data":[]}' >"$FIX/logins"
# A hangup cannot be sent where the caller of this test ignores it.
sigs=(TERM)
[ -n "$(trap -p HUP)" ] || sigs+=(HUP)
for sig in "${sigs[@]}"; do
	restart
	touch "$FIX/silent"
	"${scenv[@]}" HOME="$work/home" bash "$SC" up obs >/dev/null 2>&1 &
	pid=$!
	for _ in $(seq 100); do
		grep -q "api GET /api/project" "$FIX/podman-calls" && break
		sleep 0.1
	done
	kill "-$sig" "$pid"
	wait "$pid"
	rc=$?
	[ "$rc" = 130 ] && stopped && [ ! -e "$FIX/imported" ] && pass "an up interrupted by $sig stops the unit" ||
		fail "up interrupted by $sig: rc=$rc"
done
rm "$FIX/silent"

# Each instance keeps its server password across restarts: it is created
# once, on the first start, and never rotated by up or update.
restart
out="$(sc up obs 2>&1)"
rc=$?
pw2="$(secret obs-server-password)"
[ "$rc" = 0 ] && [ "${#pw2}" = 32 ] && [ "$pw2" = "$pw" ] && ! grep -q '^secret create' "$FIX/podman-calls" &&
	pass "a restarted container keeps its server password" || fail "the second up: rc=$rc $out"
sc down obs >/dev/null
# Manual rotation: removing the secret makes the next start create a new one.
rm "$FIX/secrets/$N-obs-server-password"
: >"$FIX/podman-calls"
out="$(sc up obs 2>&1)"
rc=$?
pw3="$(secret obs-server-password)"
[ "$rc" = 0 ] && [ "${#pw3}" = 32 ] && [ "$pw3" != "$pw2" ] &&
	pass "a removed server password is created anew on the next start" || fail "rotation: rc=$rc $out"
sc down obs >/dev/null

# The memory graph is seeded into the volume once: a copy that keeps what a
# volume already holds, and nothing when the copy fails.
mkdir -p "$work/ws3"
: >"$FIX/seed-calls"
rm -f "$FIX/seeded"
out="$(cd "$work" && sc install seed --workdir ws3 --memory mem/memory.json --image img:1 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/seeded" ] && grep -q "cp -n /src/memory.json /seed/memory.jsonl" "$FIX/seed-calls" &&
	grep -qF "$N-seed-memory:/seed:U" "$FIX/seed-calls" && grep -qF "$work/mem:/src:ro,Z" "$FIX/seed-calls" &&
	pass "install seeds the memory graph into the volume" || fail "install --memory: rc=$rc $out"
touch "$FIX/seed-fails"
out="$(cd "$work" && sc install seed2 --workdir ws3 --memory mem/memory.json 2>&1)"
rc=$?
[ "$rc" != 0 ] && [ "$out" = "skill-container: the memory graph was not seeded: the units of seed2 are as they were" ] &&
	[ ! -e "$work/home/.config/containers/systemd/$N-agent@seed2.container.d" ] &&
	[ ! -L "$work/home/.config/containers/systemd/$N-agent@seed2.container" ] &&
	[ ! -e "$work/config/skill-container/$N/seed2.dir" ] && [ ! -e "$work/config/skill-container/$N/seed2.gitconfig" ] &&
	pass "a failed seed writes no unit" || fail "install with a failed seed: rc=$rc $out"
rm "$FIX/seed-fails"
# A re-install that fails leaves a working instance as it was, or says what to run.
instfiles() {
	local d=$work/home/.config/containers/systemd s=$work/config/skill-container/$N
	sha256sum "$d/$N-agent@$1.container.d/10-workdir.conf" "$s/$1.dir" "$s/$1.gitconfig" 2>&1
	readlink "$d/$N-agent@$1.container"
}
git config --file "$work/home/.gitconfig" user.name "Pat Packager"
git config --file "$work/home/.gitconfig" user.email pat@example.org
out="$(cd "$work" && sc install seed --workdir ws3 --as /seeded 2>&1)"
rc=$?
was="$(instfiles seed)"
[ "$rc" = 0 ] && [ -s "$work/config/skill-container/$N/seed.gitconfig" ] || fail "install for the re-install test: rc=$rc $out"
touch "$FIX/seed-fails"
: >"$FIX/systemctl-calls"
out="$(cd "$work" && sc install seed --workdir ws3 --as /other --memory mem/memory.json 2>&1)"
rc=$?
rm "$FIX/seed-fails"
[ "$rc" != 0 ] && [ "$out" = "skill-container: the memory graph was not seeded: the units of seed are as they were" ] &&
	[ "$(instfiles seed)" = "$was" ] && [ ! -s "$FIX/systemctl-calls" ] &&
	pass "a re-install whose seed fails leaves the instance as it was" || fail "re-install with a failed seed: rc=$rc $out"
out="$(sc up seed 2>&1)"
rc=$?
[ "$rc" = 0 ] && pass "up finds the instance after a failed re-install" || fail "up after a failed re-install: rc=$rc $out"
sc down seed >/dev/null
touch "$FIX/reload-fails"
out="$(cd "$work" && sc install seed --workdir ws3 --as /other 2>&1)"
rc=$?
rm "$FIX/reload-fails"
[ "$rc" != 0 ] &&
	[ "$out" = "skill-container: the units of seed are written, but systemd would not reload: run 'systemctl --user daemon-reload', then 'up'" ] &&
	grep -qxF "Volume=$work/ws3:/other:Z" "$work/home/.config/containers/systemd/$N-agent@seed.container.d/10-workdir.conf" &&
	[ "$(sed -n 2p "$work/config/skill-container/$N/seed.dir")" = /other ] &&
	[ -s "$work/config/skill-container/$N/seed.gitconfig" ] && [ -L "$work/home/.config/containers/systemd/$N-agent@seed.container" ] &&
	pass "a re-install that systemd does not reload keeps the new files" || fail "re-install without a reload: rc=$rc $out"
rm "$work/home/.gitconfig"

: >"$FIX/client-calls"
out="$(sc run obs hello 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "not running" <<<"$out" && [ ! -s "$FIX/client-calls" ] &&
	pass "run without a container says so" || fail "run without a container: rc=$rc $out"
out="$(sc down obs 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(tail -1 "$FIX/systemctl-calls")" = "stop $N-agent@obs.service" ] &&
	[ -n "$(secret openqa)" ] && pass "down stops the unit and keeps the secrets" ||
	fail "down: rc=$rc $out"
# install mounts the work directory where the sessions expect it, which need
# not be its path on the host.
out="$(sc install as --workdir "$work/ws" --as /inside/dir 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qxF "Volume=$work/ws:/inside/dir:Z" \
	"$work/home/.config/containers/systemd/$N-agent@as.container.d/10-workdir.conf" &&
	grep -qxF "WorkingDir=/inside/dir" \
		"$work/home/.config/containers/systemd/$N-agent@as.container.d/10-workdir.conf" &&
	[ "$(cat "$work/config/skill-container/$N/as.dir")" = "$(printf '%s\n' "$work/ws" /inside/dir localhost/$N-agent:latest)" ] &&
	pass "install mounts the work directory at --as" || fail "install --as: rc=$rc $out"
# install runs the fixed copy: a missing or changed one stops it first.
# A copy under the launcher's own name is not the fixed copy of this skill.
mv "$work/home/.local/bin/openqa-container" "$FIX/launcher.kept"
cp "$SC" "$work/home/.local/bin/skill-container"
out="$(sc install nol --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "copy the launcher to $work/home/.local/bin/openqa-container first" <<<"$out" &&
	[ ! -e "$work/config/skill-container/$N/nol.dir" ] &&
	pass "install without the fixed copy writes nothing" || fail "install without the fixed copy: rc=$rc $out"
rm "$work/home/.local/bin/skill-container"
printf 'changed\n' >"$work/home/.local/bin/openqa-container"
out="$(sc install nol --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "copy the launcher" <<<"$out" &&
	[ ! -e "$work/config/skill-container/$N/nol.dir" ] &&
	pass "install with a changed fixed copy writes nothing" || fail "install with a changed fixed copy: rc=$rc $out"
mv "$FIX/launcher.kept" "$work/home/.local/bin/openqa-container"
out="$(sc install nol --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ -e "$work/config/skill-container/$N/nol.dir" ] &&
	pass "install writes the state file again on a repeated run" || fail "install again: rc=$rc $out"
# password prints the secret of a running instance, and nothing when stopped.
out="$(sc up as 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "up for the password test: rc=$rc $out"
printf %s /inside/dir >"$FIX/workdir"
out="$(sc password as 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(secret as-server-password)" ] &&
	pass "password prints the server password of the instance" || fail "password: rc=$rc $out"
sc down as >/dev/null
out="$(sc password as 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "is not running" <<<"$out" &&
	pass "password without the instance says so" || fail "password without the instance: rc=$rc $out"
# idle and update: a quiet instance, a busy session, an attached client.
out="$(sc up nol 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "up for the idle test: rc=$rc $out"
printf %s "$work/ws" >"$FIX/workdir"
out="$(sc idle nol 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qxF "nol is idle" <<<"$out" &&
	pass "idle answers for a quiet instance" || fail "idle: rc=$rc $out"
# What a call into the container writes to its error stream is the agent's text.
touch "$FIX/exec-escape"
out="$(sc idle nol 2>&1)"
rc=$?
rm "$FIX/exec-escape"
[ "$rc" = 0 ] && grep -qF "inside says" <<<"$out" && ! grep -q $'\033' <<<"$out" &&
	pass "idle filters the error stream of a call into the container" || fail "idle printed a control sequence: rc=$rc"
sessions '[{"id":"ses_b","permissions":null,"time":{"busy":5,"idle":2}}]'
out="$(sc idle nol 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF ses_b <<<"$out" &&
	pass "idle names a busy session" || fail "idle with a busy session: rc=$rc $out"
# The state volume is the agent's: an id that is more than an id is not printed.
sessions '[{"id":"ses_\u001b]52;c;eA==\u0007\u001b[2J","permissions":null,"time":{"busy":5,"idle":2}}]'
out="$(sc idle nol 2>&1)"
rc=$?
[ "$rc" != 0 ] && ! grep -q $'\033' <<<"$out" && grep -qF "cannot list the sessions" <<<"$out" &&
	pass "idle prints no control sequence from a session id" || fail "idle with a crafted id: rc=$rc"
sessions '[]'
printf '%s\n' /srv/elsewhere >"$FIX/others"
# podman names the server in a client's network mode by its id; its name is taken as well.
byid="/spike-y container:$(cat "$FIX/ctr-id")"
for mode in "$byid" "/spike-y container:$N-nol-agent"; do
	printf '%s\n' '/beef01 bridge' "$mode" >"$FIX/netmode"
	out="$(sc idle nol 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qxF "skill-container: a client is on nol" <<<"$out" &&
		pass "idle sees a client named by ${mode##*:}" || fail "idle with a client: rc=$rc $out"
done
# A client of another container is none of this one's.
printf '%s\n' "/beef01 container:$(printf other | sha256sum | cut -d' ' -f1)" "/beef02 container:$N-nol-agentx" >"$FIX/netmode"
out="$(sc idle nol 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qxF "nol is idle" <<<"$out" && pass "idle takes another container's client for none" ||
	fail "idle with another container's client: rc=$rc $out"
# Busy with nothing new: update ends without a restart. With a new image it waits.
printf '%s\n' "$byid" >"$FIX/netmode"
: >"$FIX/systemctl-calls"
out="$(sc update nol 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qF "runs the newest" <<<"$out" && ! grep -q '^restart' "$FIX/systemctl-calls" &&
	pass "update on the newest image ends while a client is on" || fail "update with a client and no new image: rc=$rc $out"
echo 0123abcd >"$FIX/image-new"
out="$(sc update nol 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qxF "skill-container: nol is not idle: update waits for the night" <<<"$out" &&
	! grep -q '^restart' "$FIX/systemctl-calls" && pass "update with a new image waits while a client is on" ||
	fail "update with a client and a new image: rc=$rc $out"
# A podman that does not say which containers run is no idle one.
printf '%s\n' '/beef01 bridge' >"$FIX/netmode"
for what in id-fails id-empty ps-fails ps-empty modes-fails; do
	case $what in
	ps-empty) : >"$FIX/others" ;;
	id-empty) mv "$FIX/ctr-id" "$FIX/ctr-id.kept" && : >"$FIX/ctr-id" ;;
	*) touch "$FIX/$what" ;;
	esac
	out="$(sc idle nol 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qxF "skill-container: cannot list the containers on nol" <<<"$out" &&
		pass "idle with podman failing ($what) says so" || fail "idle with $what: rc=$rc $out"
	# update reads the containers before, for the work directory: there a failing ps stops it.
	if [ "$what" != ps-fails ]; then
		out="$(sc update nol 2>&1)"
		rc=$?
		[ "$rc" != 0 ] && grep -qxF "skill-container: cannot list the containers on nol" <<<"$out" &&
			! grep -q '^restart' "$FIX/systemctl-calls" && pass "update with podman failing ($what) restarts nothing" ||
			fail "update with $what: rc=$rc $out"
	fi
	rm -f "$FIX/$what"
	[ ! -e "$FIX/ctr-id.kept" ] || mv "$FIX/ctr-id.kept" "$FIX/ctr-id"
	printf '%s\n' /srv/elsewhere >"$FIX/others"
done
rm "$FIX/image-new"
printf '%s\n' '/beef01 bridge' '/beef02 bridge' >"$FIX/netmode"
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" >"$FIX/others"
pw3="$(secret nol-server-password)"
# The image it runs is still the newest: nothing ends the sessions.
: >"$FIX/systemctl-calls"
out="$(sc update nol 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qF "runs the newest" <<<"$out" && ! grep -q '^restart' "$FIX/systemctl-calls" &&
	pass "update leaves an instance on the newest image running" || fail "update without a new image: rc=$rc $out"
echo 0123abcd >"$FIX/image-new"
# The clock of a launcher that pulled for ten minutes: the wait starts at the restart.
touch "$FIX/exec-escape"
out="$("${scenv[@]}" SECONDS=600 HOME="$work/home" bash "$SC" update nol 2>&1)"
rc=$?
rm "$FIX/exec-escape"
! grep -q $'\033' <<<"$out" && pass "update shows no control sequence from inside the container" ||
	fail "update printed a control sequence"
[ "$rc" = 0 ] && grep -qxF "nol is updated" <<<"$out" && [ "$(secret nol-server-password)" = "$pw3" ] &&
	grep -qx "restart $N-agent@nol.service" "$FIX/systemctl-calls" && [ ! -e "$FIX/pull-calls" ] &&
	pass "update restarts a quiet instance on a new image, keeps its password, no pull for a local image" ||
	fail "update: rc=$rc $out"
rm "$FIX/image-new"
# A published image is pulled first.
sc down nol >/dev/null
out="$(sc install pub --workdir "$work/ws" --image registry.example/agent:latest 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "install with a custom image: rc=$rc $out"
out="$(sc up pub 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "up with a custom image: rc=$rc $out"
out="$(sc update pub 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qx "pull registry.example/agent:latest" "$FIX/pull-calls" &&
	pass "update pulls a published image" || fail "update with a custom image: rc=$rc $out"
# The pull comes before the check for clients, which comes right before the restart.
printf '%s\n' "/spike-y container:$(cat "$FIX/ctr-id")" >"$FIX/netmode"
echo 0123abcd >"$FIX/image-new"
: >"$FIX/podman-calls"
: >"$FIX/systemctl-calls"
rm -f "$FIX/pull-calls"
out="$(sc update pub 2>&1)"
rc=$?
pulled="$(grep -nx "pull registry.example/agent:latest" "$FIX/podman-calls" | cut -d: -f1)"
asked="$(grep -nxF "inspect --format {{.Id}} $N-pub-agent" "$FIX/podman-calls" | cut -d: -f1)"
[ "$rc" != 0 ] && grep -qxF "skill-container: pub is not idle: update waits for the night" <<<"$out" &&
	[ -n "$pulled" ] && [ -n "$asked" ] && [ "$pulled" -lt "$asked" ] && ! grep -q '^restart' "$FIX/systemctl-calls" &&
	pass "update pulls, then waits while a client is on" || fail "update pub with a client: rc=$rc $pulled $asked $out"
rm "$FIX/image-new"
printf '%s\n' '/beef01 bridge' '/beef02 bridge' >"$FIX/netmode"
sc down pub >/dev/null
touch "$FIX/pull-fails"
out="$(sc up pub 2>&1)" && out="$(sc update pub 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "was not pulled" <<<"$out" &&
	pass "update without the new image changes nothing" || fail "update with a failed pull: rc=$rc $out"
rm "$FIX/pull-fails"
sc down pub >/dev/null
sc down nol >/dev/null
# uninstall takes the units and settings of one instance; what holds its work stays.
pubdir="$work/home/.config/containers/systemd"
: >"$FIX/systemctl-calls"
out="$(sc uninstall pub 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ ! -e "$pubdir/$N-agent@pub.container.d" ] && [ ! -L "$pubdir/$N-agent@pub.container" ] &&
	[ ! -e "$work/config/skill-container/$N/pub.dir" ] && [ -f "$pubdir/$N-agent@.container" ] &&
	grep -qx "stop $N-agent@pub.service" "$FIX/systemctl-calls" &&
	grep -qx "stop $N-relay@pub.service" "$FIX/systemctl-calls" &&
	grep -qx "disable --now $N-update@pub.timer" "$FIX/systemctl-calls" &&
	grep -qx daemon-reload "$FIX/systemctl-calls" && [ -f "$FIX/secrets/$N-pub-server-password" ] &&
	[ -f "$work/config/skill-container/$N/nol.dir" ] &&
	pass "uninstall removes one instance's units and keeps its secret" || fail "uninstall: rc=$rc $out"
out="$(sc up pub 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "is not installed" <<<"$out" && pass "an uninstalled instance does not start" ||
	fail "up after uninstall: rc=$rc $out"
# A unit started by its name alone has no settings: it is stopped all the same.
: >"$FIX/systemctl-calls"
out="$(sc uninstall ghost 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -qx "stop $N-agent@ghost.service" "$FIX/systemctl-calls" &&
	pass "uninstall stops an instance that was never installed" || fail "uninstall of a stray unit: rc=$rc $out"
# What goes into the drop-in is one value a line: systemd would read more, and
# strips the blanks around WorkingDir= but not those inside Volume=.
mkdir "$work/ws/blank "
for bad in "--image=img:1"$'\n'"PodmanArgs=--privileged" "--image=img:1"$'\r'"PodmanArgs=--privileged" \
	"--as=$work/ws%t" "--as=$work/ws\\" "--as=$work/ws\$HOME" "--as=$work/ws\"x" "--as=$work/ws'x" "--as=$work/ws"$'\001' \
	"--as=$work/ws " "--as=$work/ws"$'\t' "--image= img:1" "--image=img:1 " "--workdir=$work/ws/blank "; do
	out="$(sc install inj --workdir "$work/ws" "${bad%%=*}" "${bad#*=}" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF 'a control character, a %, a $, a backslash or a quote, or with a blank at its start or end' <<<"$out" &&
		[ ! -e "$pubdir/$N-agent@inj.container.d" ] &&
		pass "install refuses ${bad%%=*} with $(printf %q "${bad#*=}" | tail -c 12)" ||
		fail "install ${bad%%=*} injection: rc=$rc $out"
done
rmdir "$work/ws/blank "
# The units come from beside the fixed copy: those beside the launcher that
# runs may lie where an agent writes, its own or another instance's.
mkdir -p "$work/elsewhere/tool"
cp "$SC" "$work/elsewhere/tool/skill-container"
cp -r "$HERE/../../contrib/container/systemd" "$work/elsewhere/tool/systemd"
echo "# AGENT-WRITTEN" >>"$work/elsewhere/tool/systemd/$N-relay@.service"
out="$("${scenv[@]}" HOME="$work/home" bash "$work/elsewhere/tool/skill-container" install inw --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" = 0 ] && ! grep -q AGENT-WRITTEN "$work/home/.config/systemd/user/$N-relay@.service" &&
	pass "install takes no units from beside the launcher that runs" || fail "units beside the launcher: rc=$rc $out"
sc uninstall inw >/dev/null
rm -r "$work/elsewhere/tool"
mv "$work/home/.local/bin/systemd" "$FIX/units.kept"
out="$(sc install inw --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "no units in" <<<"$out" && [ ! -L "$pubdir/$N-agent@inw.container" ] &&
	pass "install without units beside the fixed copy writes nothing" || fail "install without units: rc=$rc $out"
mv "$FIX/units.kept" "$work/home/.local/bin/systemd"
# install names the image in the instance's own lines, and the host's git identity.
grep -qxF "Image=localhost/$N-agent:latest" "$pubdir/$N-agent@nol.container.d/10-workdir.conf" &&
	pass "install pins the default image for the instance" || fail "no Image= line for nol"
git config --file "$work/home/.gitconfig" user.name "Pat Packager"
git config --file "$work/home/.gitconfig" user.email pat@example.org
gidconf="$work/config/skill-container/$N/gid.gitconfig"
out="$(sc install gid --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ "$(git config --file "$gidconf" user.email)" = pat@example.org ] &&
	[ "$(git config --file "$gidconf" user.name)" = "Pat Packager" ] &&
	grep -qxF "Volume=$gidconf:/home/agent/.config/git/config:ro,Z" "$pubdir/$N-agent@gid.container.d/10-workdir.conf" &&
	pass "install passes the host's git identity on" || fail "the git identity: rc=$rc $out"
# The file is the instance's: an install of another one leaves it.
rm "$work/home/.gitconfig"
out="$(sc install gi2 --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ -s "$gidconf" ] && [ ! -e "$work/config/skill-container/$N/gi2.gitconfig" ] &&
	! grep -q gitconfig "$pubdir/$N-agent@gi2.container.d/10-workdir.conf" &&
	pass "install without a git identity mounts none and leaves another instance's" ||
	fail "install without a git identity: rc=$rc $out"
out="$(sc install gid --workdir "$work/ws" 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ ! -e "$gidconf" ] && ! grep -q gitconfig "$pubdir/$N-agent@gid.container.d/10-workdir.conf" &&
	pass "a later install without a git identity removes the instance's own" ||
	fail "a stale git identity: rc=$rc $out"
git config --file "$work/home/.gitconfig" user.name "Pat Packager"
git config --file "$work/home/.gitconfig" user.email pat@example.org
sc install gid --workdir "$work/ws" >/dev/null 2>&1
sc uninstall gid >/dev/null
[ ! -e "$gidconf" ] && pass "uninstall removes the instance's git identity" || fail "uninstall leaves the git identity"
rm "$work/home/.gitconfig"
sc uninstall gi2 >/dev/null
# import copies the project, its graph and its sessions into the instance.
# From here on the host's opencode runs again: the count starts over after.
mkdir -p "$work/from/proj" "$work/impws" "$work/impws2" "$work/home/.local/share/mcp-memory"
printf 'work\n' >"$work/from/proj/file.txt"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' \
	>"$work/home/.local/share/mcp-memory/memory.json"
out="$(sc install imp --workdir "$work/impws" 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "install for the import test: rc=$rc $out"
out="$(sc up imp 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "up for the import test: rc=$rc $out"
# The count of the check at the end starts over below: what ran up to here is checked now.
[ "$(wc -l <"$FIX/opencode-calls")" = "$oc0" ] && pass "install, up, attach, run and down start no opencode on the host" ||
	fail "an opencode ran on the host before import: $(tail -n "+$((oc0 + 1))" "$FIX/opencode-calls")"
: >"$FIX/opencode-calls"
rm -f "$FIX/imported-session"
touch "$FIX/exec-escape"
out="$(sc import imp --from "$work/from" 2>&1)"
rc=$?
rm "$FIX/exec-escape"
! grep -q $'\033' <<<"$out" && pass "import shows no control sequence from inside the container" ||
	fail "import printed a control sequence"
[ "$rc" = 0 ] && [ "$(cat "$work/impws/proj/file.txt")" = work ] &&
	grep -q "cp /src/memory.json /seed/memory.jsonl" "$FIX/seed-calls" &&
	[ "$(cat "$FIX/imported-session")" = "$(cat "$FIX/host-export")" ] &&
	grep -qxF "imp imported $work/from: its files, the memory graph and 2 sessions" <<<"$out" &&
	[ "$(wc -l <"$FIX/opencode-calls")" = 3 ] &&
	pass "import copies the files, the graph and the sessions" || fail "import: rc=$rc $out"
out="$(sc import imp --from "$work/from" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "it is not empty" <<<"$out" &&
	pass "import into a used work directory says so" || fail "import again: rc=$rc $out"
sc down imp >/dev/null
out="$(sc install imp2 --workdir "$work/impws2" 2>&1)" && out="$(sc up imp2 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "up for the busy import test: rc=$rc $out"
touch "$FIX/export-busy"
rm -f "$FIX/imported-session"
out="$(sc import imp2 --from "$work/from" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "is busy" <<<"$out" && [ ! -e "$FIX/imported-session" ] &&
	[ -z "$(ls -A "$work/impws2")" ] &&
	pass "import with a busy session imports none" || fail "import with a busy session: rc=$rc $out"
rm "$FIX/export-busy"
sc down imp2 >/dev/null
out="$(sc import imp2 --from "$work/from" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "is not running" <<<"$out" &&
	pass "import without the instance says so" || fail "import without the instance: rc=$rc $out"
mkdir -p "$work/valws"
out="$(sc install valg --workdir "$work/valws" 2>&1)" && out="$(sc up valg 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "up for the validation import test: rc=$rc $out"
out="$(sc import valg --from "$work/from" --memory "$work/mem-mixed/memory.json" 2>&1)"
rc=$?
[ "$rc" != 0 ] && grep -qF "with entities and relations only" <<<"$out" && [ -z "$(ls -A "$work/valws")" ] &&
	pass "import refuses a bad graph before copying" || fail "import with a bad graph: rc=$rc $out"
# Not the home directory, what holds it, a dot-directory in it, or what holds the logins,
# podman's storage, its volumes or the runtime directory. Here the three lie apart.
mkdir -p "$work/home/proj" "$work/home/.local/share/proj" "$work/configx" "$work/config/proj" "$FIX/store/overlay" \
	"$FIX/storex" "$work/vp/vols/v" "$work/vp/other" "$work/rp/run/x" "$work/rp/other"
echo "$work/vp/vols" >"$FIX/volpath"
: >"$FIX/seed-calls"
# The work directory is not empty here: an import that took one of these would stop before copying.
: >"$work/valws/keep"
# $1 = the runtime directory, $2 = what --from names.
importing() {
	out="$("${scenv[@]}" XDG_RUNTIME_DIR="$1" HOME="$work/home" bash "$SC" import valg --from "$2" 2>&1)"
}
while read -r from rt; do
	importing "${rt:-$work/run}" "$from"
	rc=$?
	real="$(realpath -- "$from")"
	[ "$rc" != 0 ] && [ "$out" = "skill-container: refusing $real: import copies a project, not your home directory, a dot-directory in it, or what holds your logins, podman's storage or your runtime directory" ] &&
		[ "$(ls -A "$work/valws")" = keep ] && [ ! -s "$FIX/seed-calls" ] &&
		pass "import refuses to copy $from" || fail "import --from $from: rc=$rc $out"
done <<EOF
/
$work
$work/home
$work/home/.
$work/home/.local
$work/home/.local/share/proj
$work/home/.config
$work/config
$work/config/proj
$FIX
$FIX/store/overlay
$work/vp
$work/vp/vols/v
$work/rp $work/rp/run
$work/rp/run/x $work/rp/run
EOF
# Beside them a directory passes this check and meets the next: the work directory is not empty.
for from in "$FIX/storex" "$work/vp/other" "$work/rp/other"; do
	importing "$work/rp/run" "$from"
	rc=$?
	[ "$rc" != 0 ] && [ "$out" = "skill-container: refusing $work/valws: it is not empty; move its files away and run import again" ] &&
		[ ! -s "$FIX/seed-calls" ] && pass "import takes $from beside podman's storage and the runtime directory" ||
		fail "import --from $from: rc=$rc $out"
done
rm "$work/valws/keep"
echo "$FIX/store/volumes" >"$FIX/volpath"
# A project in the home directory, or beside the logins, passes that check.
for from in "$work/home/proj" "$work/configx"; do
	out="$(sc import valg --from "$from" --memory "$work/mem-mixed/memory.json" 2>&1)"
	rc=$?
	[ "$rc" != 0 ] && grep -qF "with entities and relations only" <<<"$out" && [ -z "$(ls -A "$work/valws")" ] &&
		pass "import takes $from as a project" || fail "import --from $from: rc=$rc $out"
done
sc down valg >/dev/null
: >"$FIX/opencode-calls"
oc0=0
[ ! -s "$FIX/untimed" ] && pass "every command in the container is bounded in time" ||
	fail "commands in the container without a timeout: $(sort -u "$FIX/untimed")"
[ ! -e "$FIX/planted-host" ] && [ ! -e "$FIX/planted-client" ] && [ ! -e "$FIX/launcher-path-client" ] &&
	pass "no command of the caller's PATH or the work directory ran in place of the launcher's" ||
	fail "a planted command ran: $(cd "$FIX" && echo planted-* launcher-path-clien[t])"
[ "$(wc -l <"$FIX/opencode-calls")" = "$oc0" ] && pass "up, attach, run and down start no opencode on the host" ||
	fail "an opencode ran on the host: $(tail -n "+$((oc0 + 1))" "$FIX/opencode-calls")"
[ ! -e "$FIX/env-leak" ] && pass "the server password is in the environment and the arguments of no command" ||
	fail "the server password reached: $(sort -u "$FIX/env-leak" | tr '\n' ' ')"
[ ! -e "$FIX/secret-leak" ] && pass "no login is in the arguments or the environment of a command" ||
	fail "a login reached: $(sort -u "$FIX/secret-leak" | tr '\n' ' ')"
left="$(leakfiles)"
[ -z "$left" ] && pass "no login is left in a file" || fail "a login is in: $left"
[ ! -e "$FIX/cwd-leak" ] && pass "no command starts in the work directory" ||
	fail "started in the work directory: $(sort -u "$FIX/cwd-leak" | tr '\n' ' ')"
# The launcher names no command by its path and sets PATH in two ways only:
# each command it runs is one of the checked ones.
[ "$(grep -owE 'PATH=[^ ]+' "$SC" | LC_ALL=C sort -u)" = "$(printf '%s\n' \
	'PATH=$userpath' 'PATH=${SKILL_CONTAINER_PATH:-/usr/local/bin:/usr/bin:/bin}')" ] &&
	! tail -n +2 "$SC" | grep -qE '/(s?bin|libexec)/|command +-p' &&
	pass "the launcher takes every command from its own PATH" ||
	fail "the launcher names a command by its path or sets another PATH"
out="$(sc frobnicate 2>&1)"
rc=$?
[ "$rc" = 2 ] && grep -q '^usage:' <<<"$out" && pass "an unknown command prints the usage" ||
	fail "unknown command: rc=$rc"

echo "---"
[ "$fails" = 0 ] && echo "all skill-container checks passed" || echo "$fails FAILED"
exit $((fails > 0))
