#!UseOBSRepositories
#!BuildTag: openqa-agent:latest

# skill.tar holds this repository under skill/.
FROM opensuse/tumbleweed:latest AS src
ADD skill.tar /src/

FROM opensuse/tumbleweed:latest

LABEL org.opencontainers.image.title="openQA agent"
LABEL org.opencontainers.image.description="opencode with the openqa skill and the tools it calls"
LABEL org.opencontainers.image.source="https://github.com/os-autoinst/openQA-skill"

# os-autoinst is here for /usr/lib/os-autoinst, which the test distribution's
# compile and unit-test gates want as os-autoinst/ in the checkout; the Test
# modules are those its unit tests load. os-autoinst-devel would bring qemu and
# a compiler: verification runs are cloned to an openQA instance instead.
RUN zypper -n in --no-recommends \
        opencode bugwarden mcp-server-memory mcp-server-sequential-thinking \
        openQA-client gh git-core openssh-clients \
        python3-base python3-PyYAML python3-Pillow \
        os-autoinst os-autoinst-distri-opensuse-deps make which \
        perl-Test-MockModule perl-Test-Warnings perl-Test-Exception perl-Test-Mock-Time \
        perl-Test-MockObject perl-Test-Most perl-Test-Fatal \
        perl-Perl-Tidy perl-Code-TidyAll perl-Perl-Critic-Community perl-Code-DRY \
        perl-JSON-Validator gnu_parallel python3-yamllint python3-gitlint ShellCheck \
        ca-certificates-suse \
        jq curl xz bzip2 tar file findutils grep sed gawk diffutils patch less ripgrep \
        hostname procps socat \
    && zypper clean -a \
    && rm -rf /var/tmp/* /run/zypp.pid /var/log/zypper.log /var/log/zypp/history

COPY --from=src /src/skill/contrib/harness/opencode-v2/opencode.jsonc /etc/opencode/
COPY --from=src /src/skill/skills/openqa/ /etc/opencode/skills/openqa/
COPY opencode.json CONTAINER.md skill.obsinfo /etc/opencode/
COPY ssh_known_hosts /etc/ssh/ssh_known_hosts
COPY ssh_config /etc/ssh/ssh_config.d/50-github.conf
COPY image-check /usr/local/bin/
COPY model-stub.py rule-table.txt /usr/local/share/image-check/

# opencode drops an agent file whose frontmatter it cannot read, and the playbooks
# carry another harness's: each gets a wrapper that points at it.
RUN set -eu; skill=/etc/opencode/skills/openqa; mkdir /etc/opencode/agent; \
    for f in "$skill"/agents/*.md; do \
        name=$(sed -n '2,/^---$/s/^name: //p' "$f"); \
        case $name in '' | *[!a-z0-9-]*) echo "no usable agent name in $f" >&2; exit 1 ;; esac; \
        { echo ---; sed -n '2,/^---$/{/^description: /p}' "$f"; echo "mode: subagent"; \
          sed -n '2,/^---$/p' "$f" | grep -q '^tools:.*Edit' || printf 'permission:\n  edit: deny\n'; \
          echo ---; \
          echo "Read $f in full, then follow it exactly."; \
          echo "The skill root, the base of every scripts/ and references/ path in it, is $skill."; \
        } > "/etc/opencode/agent/$name.md"; \
    done

# The agent runs as the caller's user: nothing baked here may be writable by it.
# The logins are mounted into one directory of their own at the top: a command
# that reads everything below ~/.config or /var does not come across them, and a
# rule on the directory's name covers them all. gh wants a config.yml beside its login and
# cannot write one at run time.
# A site policy file is looked up in ~/.config/openqa-skill; the link leads to the
# per-user directory the launcher mounts, and dangles when there is none.
RUN mkdir -p /work /home/agent/.config/openqa-skill /home/agent/.config/opencode \
        /home/agent/.config/git /home/agent/.local/share/mcp-memory \
        /agent-logins/openqa /agent-logins/gh \
        /agent-logins/bugzilla /agent-logins/ssh \
    && echo 'version: "1"' > /agent-logins/gh/config.yml \
    && ln -s ../opencode/openqa-policy.md /home/agent/.config/openqa-skill/policy.md \
    && echo 'unset OPENCODE_PASSWORD' > /etc/opencode/shell-env \
    && chmod 0644 /etc/ssh/ssh_known_hosts /etc/ssh/ssh_config.d/50-github.conf \
    && chown -R root:root /etc/opencode /home/agent /agent-logins \
        /usr/local/bin/image-check /usr/local/share/image-check \
    && chmod -R a+rX,go-w /etc/opencode /home/agent /agent-logins /usr/local/share/image-check \
    && chmod 0755 /home/agent /usr/local/bin/image-check

# BASH_ENV: the server runs each command in a bash, which reads that file first
# and so starts without the server password. openqa-cli and gh take the directory
# of their login from the two variables after it. GIT_SSH_COMMAND: ssh reads a
# user's config from the home directory of the password entry, which podman sets
# to the work directory; with -F it reads the one file of this image alone.
ENV HOME=/home/agent \
    BASH_ENV=/etc/opencode/shell-env \
    MEMORY_FILE_PATH=/home/agent/.local/share/mcp-memory/memory.jsonl \
    OPENQA_CONFIG=/agent-logins/openqa \
    GH_CONFIG_DIR=/agent-logins/gh \
    GIT_SSH_COMMAND="ssh -F /etc/ssh/ssh_config.d/50-github.conf" \
    PYTHONDONTWRITEBYTECODE=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1
WORKDIR /work

RUN image-check

CMD ["opencode", "serve", "--hostname", "127.0.0.1", "--port", "4096"]
