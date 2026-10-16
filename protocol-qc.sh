#!/bin/sh
# AGOS only. Usage: sh protocol-qc.sh ACTUAL_REPO_BUNDLE EXPECTED_HEAD [LOCAL_IMAGE]
# Supply the actual task-owned repo1421325843 bundle and its independently known HEAD.
# No image build/pull, published port, host mount, remote Docker, or source execution.
set -eu
umask 077

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] \
    || fail 'Usage: sh protocol-qc.sh ACTUAL_REPO_BUNDLE EXPECTED_HEAD [LOCAL_IMAGE]'
[ "$(uname -s)" = Linux ] || fail 'QC is restricted to the local AGOS Linux host.'
case "$(hostname -s | tr '[:upper:]' '[:lower:]')" in
    automation-marketing-agos) ;;
    *) fail 'QC is restricted to the pinned Automation-Marketing-AGOS host.' ;;
esac

source_bundle=$1
expected_head=$2
image=${3:-private-git-fixture-20261016:latest}
[ -f "$source_bundle" ] && [ -s "$source_bundle" ] || fail 'Supply a nonempty actual repository bundle.'
case "${#expected_head}" in
    40|64) ;;
    *) fail 'EXPECTED_HEAD must be a full hexadecimal Git object ID.' ;;
esac
case "$expected_head" in
    *[!0-9a-f]*) fail 'EXPECTED_HEAD must be a lowercase hexadecimal Git object ID.' ;;
esac

# An explicit Unix socket bypasses saved remote Docker contexts and environment.
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
docker_local() {
    command docker --host unix:///var/run/docker.sock "$@"
}

container_id=
cleanup() {
    status=$?
    if [ -n "$container_id" ]; then
        if [ "$status" -ne 0 ]; then
            docker_local logs --tail 30 "$container_id" >&2 || :
        fi
        docker_local rm --force "$container_id" > /dev/null 2>&1 || :
    fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

container_id=$(docker_local run --detach --pull=never --network none \
    --cpus 1 --memory 256m --pids-limit 128 "$image")
attempt=0
until docker_local exec "$container_id" curl --disable --fail --silent \
    --output /dev/null http://127.0.0.1:8080/health.html > /dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail 'The isolated fixture did not become ready.'
    sleep 1
done

docker_local exec -i "$container_id" sh -s <<'PRE_IMPORT'
set -eu
umask 077
expect_status() {
    expected=$1
    shift
    actual=$(curl --disable --silent --show-error --output /dev/null --write-out '%{http_code}' "$@")
    if [ "$actual" != "$expected" ]; then
        printf 'Unexpected HTTP status: expected %s, received %s.\n' "$expected" "$actual" >&2
        exit 1
    fi
}
test "$(stat -c %a /run/mirror-read-token)" = 600
test ! -e /srv/git/fixture.git
expect_status 200 http://127.0.0.1:8080/health.html
expect_status 401 'http://127.0.0.1:8080/git/fixture.git/info/refs?service=git-upload-pack'
expect_status 401 --config - 'http://127.0.0.1:8080/git/fixture.git/info/refs?service=git-upload-pack' <<'WRONG_AUTH'
user = "fixture-reader:deliberately-wrong"
WRONG_AUTH
# Stream the real credential into a root-only file, never an argument or log.
{
    printf 'user = "fixture-reader:'
    tr -d '\n' < /run/mirror-read-token
    printf '"\n'
} > /run/fixture-qc.curlrc
expect_status 404 --config /run/fixture-qc.curlrc \
    'http://127.0.0.1:8080/git/fixture.git/info/refs?service=git-upload-pack'
PRE_IMPORT

# The only source import is the supplied bundle, delivered over docker-exec stdin.
docker_local exec -i "$container_id" sh -c '
set -eu
umask 077
trap '\''rm -f /run/fixture-source.bundle'\'' 0
cat > /run/fixture-source.bundle
git clone --bare --quiet -- /run/fixture-source.bundle /srv/git/fixture.git
git --git-dir=/srv/git/fixture.git config http.receivepack false
chown -R root:daemon /srv/git/fixture.git
chmod -R u=rwX,g=rX,o= /srv/git/fixture.git
' < "$source_bundle"

docker_local exec --user daemon "$container_id" sh -c '
set -eu
test -r /srv/git/fixture.git/HEAD
test ! -w /srv/git/fixture.git
test ! -r /run/mirror-read-token
'

docker_local exec -i "$container_id" sh -s -- "$expected_head" <<'POST_IMPORT'
set -eu
umask 077
expected_head=$1
export LC_ALL=C GIT_TERMINAL_PROMPT=0
expect_status() {
    expected=$1
    shift
    actual=$(curl --disable --silent --show-error --output /dev/null --write-out '%{http_code}' "$@")
    if [ "$actual" != "$expected" ]; then
        printf 'Unexpected HTTP status: expected %s, received %s.\n' "$expected" "$actual" >&2
        exit 1
    fi
}
test "$(git --git-dir=/srv/git/fixture.git rev-parse --verify HEAD)" = "$expected_head"
test "$(git --git-dir=/srv/git/fixture.git config --get http.receivepack)" = false
expect_status 200 --config /run/fixture-qc.curlrc \
    'http://127.0.0.1:8080/git/fixture.git/info/refs?service=git-upload-pack'
expect_status 401 'http://127.0.0.1:8080/git/fixture.git/info/refs?service=git-upload-pack'
expect_status 401 --config - 'http://127.0.0.1:8080/git/fixture.git/info/refs?service=git-upload-pack' <<'WRONG_AUTH'
user = "fixture-reader:deliberately-wrong"
WRONG_AUTH
cat > /run/fixture-qc-askpass <<'ASKPASS'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' fixture-reader ;;
    *Password*) cat /run/mirror-read-token ;;
    *) exit 1 ;;
esac
ASKPASS
chmod 0700 /run/fixture-qc-askpass
export GIT_ASKPASS=/run/fixture-qc-askpass
git -c credential.helper= clone --quiet --depth=1 --no-checkout \
    http://127.0.0.1:8080/git/fixture.git /run/fixture-qc-clone
test "$(git -C /run/fixture-qc-clone rev-parse --verify HEAD)" = "$expected_head"
test "$(git -C /run/fixture-qc-clone rev-parse --is-shallow-repository)" = true
test "$(git -C /run/fixture-qc-clone rev-list --count HEAD)" = 1
expect_status 403 --config /run/fixture-qc.curlrc \
    'http://127.0.0.1:8080/git/fixture.git/info/refs?service=git-receive-pack'
expect_status 403 --config /run/fixture-qc.curlrc --request POST \
    --header 'Content-Type: application/x-git-receive-pack-request' --data-binary 0000 \
    http://127.0.0.1:8080/git/fixture.git/git-receive-pack
probe_ref=refs/heads/fixture-qc-write-probe
if git --git-dir=/srv/git/fixture.git show-ref --verify --quiet "$probe_ref"; then
    printf '%s\n' 'The reserved QC probe ref already exists in the supplied source.' >&2
    exit 1
fi
if git -C /run/fixture-qc-clone -c credential.helper= push --porcelain \
    origin "HEAD:$probe_ref" > /run/fixture-qc-push.log 2>&1; then
    printf '%s\n' 'Read-only acceptance failed: push unexpectedly succeeded.' >&2
    exit 1
fi
if ! grep -Eq '403|git-receive-pack.*(not permitted|not supported)' /run/fixture-qc-push.log; then
    printf '%s\n' 'Push failed without the expected protocol-denial evidence.' >&2
    exit 1
fi
if git --git-dir=/srv/git/fixture.git show-ref --verify --quiet "$probe_ref"; then
    printf '%s\n' 'Read-only acceptance failed: the probe ref was written.' >&2
    exit 1
fi
expect_status 200 http://127.0.0.1:8080/health.html
POST_IMPORT

printf '%s\n' 'PASS: readiness, authentication, actual-bundle shallow clone, expected HEAD, and push denial.'
