#!/usr/bin/env bash
# setup_and_test.sh - Automated Forgejo environment for testing migration script

set -e

# Optionally load GitHub settings from .env. This happens before the test settings below are
# defined so .env can't override them. The migration script is run with ENV_FILE=/dev/null so
# .env doesn't override the option matrix exported here either. .env is never written unless
# you choose to save the test settings at the end.
if [ -f .env ]; then
	read -r -p "Load GitHub settings from .env? (Y/n): " load_env
	if [[ ! "$load_env" =~ ^[nN] ]]; then
		set -a
		# shellcheck disable=SC1091
		. ./.env
		set +a
	fi
fi
export ENV_FILE=/dev/null

# Using development build to test bug #9629 fix (PR #11909)
# Will be updated to stable v15.0.0 when released on April 16, 2026
CONTAINER_IMAGE="codeberg.org/forgejo-experimental/forgejo:15.0-test"
CONTAINER_NAME="forgejo-test"
HTTP_PORT=3000
FORGEJO_USER="testuser"
FORGEJO_PASS="Password123!"
FORGEJO_EMAIL="test@example.com"
TOKEN_NAME="test-token-$(date +%s)"

# Cleanup previous runs
if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
	echo "Cleaning up existing container..."
	docker rm -f $CONTAINER_NAME
fi

echo "Starting Forgejo container..."
# Using environment variables to bypass the installation wizard
docker run -d --name "$CONTAINER_NAME" \
	-p "$HTTP_PORT:3000" \
	-e "FORGEJO__security__INSTALL_LOCK=true" \
	-e "FORGEJO__database__DB_TYPE=sqlite3" \
	-e "FORGEJO__server__OFFLINE_MODE=false" \
	$CONTAINER_IMAGE

echo "Waiting for Forgejo to be ready..."
MAX_RETRIES=30
COUNT=0
until curl -s "http://localhost:$HTTP_PORT/" >/dev/null; do
	sleep 2
	COUNT=$((COUNT + 1))
	if [ $COUNT -ge $MAX_RETRIES ]; then
		echo "Forgejo failed to start in time."
		docker logs $CONTAINER_NAME
		exit 1
	fi
	echo -n "."
done
echo " Ready!"

echo "Creating admin user: $FORGEJO_USER"
docker exec -u 1000 "$CONTAINER_NAME" forgejo admin user create \
	--username "$FORGEJO_USER" \
	--password "$FORGEJO_PASS" \
	--email "$FORGEJO_EMAIL" \
	--admin --must-change-password=false

echo "Generating access token..."
FORGEJO_TOKEN=$(docker exec -u 1000 "$CONTAINER_NAME" forgejo admin user generate-access-token \
	--username "$FORGEJO_USER" \
	--token-name "$TOKEN_NAME" \
	--scopes all \
	--raw)

if [ -z "$FORGEJO_TOKEN" ]; then
	echo "Failed to generate Forgejo token."
	exit 1
fi

export FORGEJO_URL="http://localhost:$HTTP_PORT"
export FORGEJO_USER="$FORGEJO_USER"
export FORGEJO_TOKEN="$FORGEJO_TOKEN"

echo "--------------------------------------------------"
echo "Forgejo is ready!"
echo "URL: $FORGEJO_URL"
echo "User: $FORGEJO_USER"
echo "Token: $FORGEJO_TOKEN"
echo "--------------------------------------------------"
echo "Now running github-forgejo-migrate.sh testing all option combinations"
echo "Note: You may be prompted for GITHUB_USER and GITHUB_TOKEN if they are not in your environment."
echo "--------------------------------------------------"

github_user_prompted=false
if [ -z "$GITHUB_USER" ]; then
	read -r -p "Enter GITHUB_USER for testing (e.g. your username): " GITHUB_USER
	export GITHUB_USER
	github_user_prompted=true
fi

strategies=("mirror" "clone")
booleans=("Yes" "No")

# Run combinations in DRY_RUN first
export DRY_RUN="Yes"
for strategy in "${strategies[@]}"; do
	for force_sync in "${booleans[@]}"; do
		for migrate_archive in "${booleans[@]}"; do
			for migrate_fork in "${booleans[@]}"; do
				echo "================================================================"
				echo "Testing DRY RUN: STRATEGY=$strategy FORCE_SYNC=$force_sync MIGRATE_ARCHIVE=$migrate_archive MIGRATE_FORKS=$migrate_fork"
				export STRATEGY="$strategy"
				export FORCE_SYNC="$force_sync"
				export MIGRATE_ARCHIVE_STATUS="$migrate_archive"
				export MIGRATE_FORKS="$migrate_fork"
				bash github-forgejo-migrate.sh
			done
		done
	done
done

echo "================================================================"
echo "Running one final REAL migration with default options..."
export DRY_RUN="No"
export STRATEGY="mirror"
export FORCE_SYNC="No"
export MIGRATE_ARCHIVE_STATUS="Yes"
export MIGRATE_FORKS="Yes"
bash github-forgejo-migrate.sh

echo "--------------------------------------------------"
echo "Migration script finished."
echo "You can check the results at $FORGEJO_URL"

echo ""
read -r -p "Do you want to stop and remove the test container? (y/N): " cleanup
if [[ "$cleanup" =~ ^[yY]$ ]]; then
	echo "Cleaning up..."
	docker rm -f "$CONTAINER_NAME"
	echo "Done."
else
	echo "Keeping container running."
	echo "To clean up later, run: docker rm -f $CONTAINER_NAME"

	# Only offer to save the test settings while the container (and its token) still exists.
	env_pattern='^[[:space:]]*(export[[:space:]]+)?FORGEJO_(URL|USER|TOKEN)='
	save_vars="FORGEJO_URL FORGEJO_USER FORGEJO_TOKEN"
	if $github_user_prompted; then
		env_pattern='^[[:space:]]*(export[[:space:]]+)?(FORGEJO_(URL|USER|TOKEN)|GITHUB_USER)='
		save_vars="$save_vars GITHUB_USER"
	fi
	current_url=""
	if [ -f .env ]; then
		current_url=$(grep -E '^[[:space:]]*(export[[:space:]]+)?FORGEJO_URL=' .env | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true)
	fi
	if [ -n "$current_url" ] && [ "$current_url" != "$FORGEJO_URL" ]; then
		echo "Warning: .env currently points FORGEJO_URL at $current_url; saving will replace it."
	fi
	read -r -p "Save the test settings ($save_vars) to .env? (y/N): " save_env
	if [[ "$save_env" =~ ^[yY] ]]; then
		(
			umask 077
			{
				grep -Ev "$env_pattern" .env 2>/dev/null || true
				for var in $save_vars; do
					printf "%s='%s'\n" "$var" "${!var}"
				done
			} >.env.tmp
		)
		mv .env.tmp .env
		chmod 600 .env
		echo "Saved $save_vars to .env"

		if command -v direnv >/dev/null 2>&1; then
			echo "Updating direnv..."
			direnv allow . || true
		fi
	fi
fi
