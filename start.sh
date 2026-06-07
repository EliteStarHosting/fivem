#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
Text="${GREEN}[STARTUP]${NC}"

echo -e "${Text} ${BLUE}Starting checks for all updates...${NC}"

RELEASE_PAGE=$(curl -sSL https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/)
CHANGELOGS_PAGE=$(curl -sSL https://changelogs-live.fivem.net/api/changelog/versions/linux/server)

if [[ "${AUTO_UPDATE}" == "1" ]]; then
    DOWNLOAD_LINK=$(echo $CHANGELOGS_PAGE | jq -r '.latest_download')
    rm -rf /home/container/alpine > /dev/null 2>&1
    echo -e "${Text} ${BLUE}Updating CitizenFX Resource Files...${NC}"
    curl -sSL ${DOWNLOAD_LINK} -o ${DOWNLOAD_LINK##*/} > /dev/null 2>&1
    tar -xvf ${DOWNLOAD_LINK##*/} > /dev/null 2>&1
    rm -rf ${DOWNLOAD_LINK##*/} run.sh > /dev/null 2>&1
    echo -e "${Text} ${BLUE}CitizenFX Resources updated successfully!${NC}"
else
    echo -e "${Text} ${BLUE}Auto Update is disabled!${NC}"
fi

# Patch yarn_builder.js to build Yarn resources with system Node instead of
# FXServer's bundled Node 22.
#
# Workaround for https://github.com/citizenfx/fivem/issues/3892
#
# CitizenFX builds Yarn resources via child_process.fork(). fork() inherits the
# parent's process.execArgv, and FXServer's patched parent node is launched with
# loader flags (--library-path, --start-node, --fork-node22). Simply overriding
# execPath kept those flags and made system node fail with
# "bad option: --library-path". The verified fix (see issue #3892) is a plain
# child_process.spawn('/usr/bin/node', [yarn_cli.js, 'install', ...]) which does
# NOT pass execArgv, so no loader flags leak in.
#
# The rewrite below is content-anchored (not line-number based) and idempotent:
# it normalises both a pristine fork() call and any previously-patched form to
# the same known-good spawn() call, so it is safe across artifact updates.
YARN_BUILDER="/home/container/alpine/opt/cfx-server/citizen/system_resources/yarn/yarn_builder.js"
if [ -f "$YARN_BUILDER" ]; then
    PATCH_RESULT=$(/usr/bin/node -e '
        const fs = require("fs");
        const f = process.argv[1];
        const src = fs.readFileSync(f, "utf8");
        const re = /const proc = child_process\.(?:fork|spawn)\([\s\S]*?\}\s*\)\s*;/;
        if (!re.test(src)) { process.stdout.write("ANCHOR_NOT_FOUND"); process.exit(0); }
        const repl =
            "const proc = child_process.spawn(\n" +
            "\t\t\t\t\x27/usr/bin/node\x27,\n" +
            "\t\t\t\t[require.resolve(\x27./yarn_cli.js\x27),\n" +
            "\t\t\t\t\x27install\x27, \x27--ignore-scripts\x27, \x27--cache-folder\x27, path.join(initCwd, \x27cache\x27, \x27yarn-cache\x27), \x27--mutex\x27, \x27file:\x27 + path.join(initCwd, \x27cache\x27, \x27yarn-mutex\x27)],\n" +
            "\t\t\t\t{\n" +
            "\t\t\t\t\tcwd: path.resolve(GetResourcePath(resourceName)),\n" +
            "\t\t\t\t\tstdio: \x27pipe\x27,\n" +
            "\t\t\t\t});";
        const out = src.replace(re, repl);
        if (out === src) { process.stdout.write("ALREADY_OK"); process.exit(0); }
        fs.writeFileSync(f, out);
        process.stdout.write("PATCHED");
    ' "$YARN_BUILDER" 2>/dev/null)
    case "$PATCH_RESULT" in
        PATCHED)
            echo -e "${Text} ${GREEN}Patched yarn_builder.js to build resources with system Node via spawn().${NC}" ;;
        ALREADY_OK)
            echo -e "${Text} ${BLUE}yarn_builder.js already uses the system Node spawn() build.${NC}" ;;
        *)
            echo -e "${RED}[WARNING] Could not locate the yarn_builder.js spawn call (got: ${PATCH_RESULT:-empty}) - Yarn resource builds may fail.${NC}" ;;
    esac
fi

echo -e "${Text} ${BLUE}Preparing environment variables...${NC}"

export TXHOST_DATA_PATH=/home/container/txData
export TXHOST_MAX_SLOTS=${MAX_PLAYERS}
export TXHOST_TXA_PORT=${TXADMIN_PORT}
export TXHOST_FXS_PORT=${SERVER_PORT}
export TXHOST_DEFAULT_CFXKEY=${FIVEM_LICENSE}
export TXHOST_PROVIDER_NAME=${PROVIDER_NAME}
export TXHOST_PROVIDER_LOGO=${PROVIDER_LOGO}

# Database auto-provisioning via Pterodactyl Application API (admin key)
# PTERO_URL and PTERO_ADMIN_KEY should be set as hidden egg variables
# (user_viewable: false, user_editable: false) so server owners cannot see them.
# P_SERVER_UUID is automatically injected by Pterodactyl.
if [[ -n "${PTERO_URL}" && -n "${PTERO_ADMIN_KEY}" && -n "${P_SERVER_UUID}" ]]; then
    echo -e "${Text} ${BLUE}Provisioning database via Pterodactyl Application API...${NC}"
    _BASE="${PTERO_URL%/}/api/application"
    _HDR=(-sSLg -H "Authorization: Bearer ${PTERO_ADMIN_KEY}" -H "Accept: application/json" -H "Content-Type: application/json")

    # 1. Resolve internal server ID from the UUID Pterodactyl injects.
    # -g (--globoff) prevents curl from interpreting [ ] in the query string as a range.
    # Try filter[uuid] first; fall back to listing all servers and matching client-side,
    # since some Pterodactyl versions don't honour the filter parameter.
    _SERVER=$(curl "${_HDR[@]}" "${_BASE}/servers?filter[uuid]=${P_SERVER_UUID}")
    _SRV_ID=$(echo "$_SERVER" | jq -r '.data[0].attributes.id // empty')

    if [[ -z "$_SRV_ID" ]]; then
        _ALL=$(curl "${_HDR[@]}" "${_BASE}/servers?per_page=100")
        _SRV_ID=$(echo "$_ALL" | jq -r --arg uuid "${P_SERVER_UUID}" \
            '.data[] | select(.attributes.uuid == $uuid) | .attributes.id' | head -1)
    fi

    if [[ -z "$_SRV_ID" ]]; then
        echo -e "${RED}[ERROR] Could not resolve server in Pterodactyl panel. Check PTERO_URL and PTERO_ADMIN_KEY.${NC}"
        echo -e "${RED}        API response: $(echo "$_ALL" | jq -r '.errors // .error // "no errors field"' 2>/dev/null)${NC}"
    else
        # 2. Check for an existing database
        _DB_LIST=$(curl "${_HDR[@]}" "${_BASE}/servers/${_SRV_ID}/databases?include=password,host")
        _DB_COUNT=$(echo "$_DB_LIST" | jq -r '.data | length')

        if [[ "$_DB_COUNT" -gt 0 ]]; then
            echo -e "${Text} ${BLUE}Found existing database, reusing it...${NC}"
            _DB=$(echo "$_DB_LIST" | jq -r '.data[0].attributes')
            DB_HOST=$(echo "$_DB_LIST" | jq -r '.data[0].attributes.relationships.host.attributes.host')
            DB_PORT=$(echo "$_DB_LIST" | jq -r '.data[0].attributes.relationships.host.attributes.port')
            DB_NAME=$(echo "$_DB_LIST" | jq -r '.data[0].attributes.database')
            DB_USER=$(echo "$_DB_LIST" | jq -r '.data[0].attributes.username')
            DB_PASSWORD=$(echo "$_DB_LIST" | jq -r '.data[0].attributes.relationships.password.attributes.password')
        else
            # 3. Fetch the first available database host ID
            _HOSTS=$(curl "${_HDR[@]}" "${_BASE}/databases/hosts")
            _HOST_ID=$(echo "$_HOSTS" | jq -r '.data[0].attributes.id // empty')

            if [[ -z "$_HOST_ID" ]]; then
                echo -e "${RED}[ERROR] No database hosts configured in Pterodactyl. Add one in Admin > Databases.${NC}"
            else
                echo -e "${Text} ${BLUE}No database found, creating one...${NC}"
                _DB_CREATE=$(curl "${_HDR[@]}" -X POST \
                    -d "{\"database\":\"fivem\",\"remote\":\"%\",\"host\":${_HOST_ID}}" \
                    "${_BASE}/servers/${_SRV_ID}/databases?include=password,host")

                DB_HOST=$(echo "$_DB_CREATE" | jq -r '.attributes.relationships.host.attributes.host')
                DB_PORT=$(echo "$_DB_CREATE" | jq -r '.attributes.relationships.host.attributes.port')
                DB_NAME=$(echo "$_DB_CREATE" | jq -r '.attributes.database')
                DB_USER=$(echo "$_DB_CREATE" | jq -r '.attributes.username')
                DB_PASSWORD=$(echo "$_DB_CREATE" | jq -r '.attributes.relationships.password.attributes.password')
            fi
        fi

        if [[ -n "$DB_HOST" && "$DB_HOST" != "null" ]]; then
            export TXHOST_DEFAULT_DBHOST="${DB_HOST}"
            export TXHOST_DEFAULT_DBPORT="${DB_PORT}"
            export TXHOST_DEFAULT_DBUSER="${DB_USER}"
            export TXHOST_DEFAULT_DBPASS="${DB_PASSWORD}"
            export TXHOST_DEFAULT_DBNAME="${DB_NAME}"
            echo -e "${Text} ${GREEN}Database '${DB_NAME}' ready and credentials passed to txAdmin.${NC}"
        else
            echo -e "${RED}[ERROR] Failed to provision database. Check that a database host exists in Admin > Databases.${NC}"
        fi
    fi
else
    echo -e "${Text} ${BLUE}No Pterodactyl admin API credentials provided, skipping DB provisioning.${NC}"
fi

SERVER_BIN_PATH="/home/container/alpine/opt/cfx-server/FXServer"
if [ ! -f "$SERVER_BIN_PATH" ]; then
    echo -e "${RED}[ERROR] FiveM server binary not found at ${SERVER_BIN_PATH}${NC}"
    exit 1
fi

echo -e "${Text} ${BLUE}Running the FiveM server with txAdmin...${NC}"
$(pwd)/alpine/opt/cfx-server/ld-musl-x86_64.so.1 \
  --library-path "$(pwd)/alpine/usr/lib/v8/:$(pwd)/alpine/lib/:$(pwd)/alpine/usr/lib/:$(pwd)/alpine/opt/cfx-server/lib/" \
  -- $(pwd)/alpine/opt/cfx-server/FXServer \
  +set citizen_dir $(pwd)/alpine/opt/cfx-server/citizen/ \
  $( [ "$TXADMIN_ENABLE" == "1" ] || printf %s '+exec server.cfg' )
