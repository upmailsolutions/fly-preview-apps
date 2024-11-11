#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

GITHUB_REPOSITORY_NAME=${GITHUB_REPOSITORY#$GITHUB_REPOSITORY_OWNER/}
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$GITHUB_REPOSITORY_OWNER-$GITHUB_REPOSITORY_NAME}"
# Change underscores to hyphens.
app="${app//_/-}"
app_db="${app}-db"
app_db="${INPUT_POSTGRES:-${app_db}}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  # finally, destroy the app
  if flyctl status --app "$app"; then
    flyctl apps destroy "$app" -y || true
  fi
  exit 0
fi

# Check if app exists,
# if not, launch it, but don't deploy yet
if ! flyctl status --app "$app"; then
  flyctl apps create "$app" --org "$org"
fi

# look for "migrate" file in the app files
# if it exists, the app probably needs DB.
if [ -e "rel/overlays/bin/migrate" ]; then
  # only create db if the app lauched successfully
  if flyctl status --app "$app"; then
    # Attach postgres cluster to the app if specified.
    if [ -n "$INPUT_POSTGRES" ]; then
      flyctl postgres attach "$INPUT_POSTGRES" --app "$app" || true
    else
      if flyctl status --app "$app_db"; then
        echo "$app_db DB already exists"
      else
        flyctl postgres create --name "$app_db" --org "$org" --region "$region" --vm-size shared-cpu-1x --initial-cluster-size 1 --volume-size 1

        # attaching db to the app if it was created successfully
        if flyctl postgres attach "$app_db" --app "$app" -y; then
          echo "$app_db DB attached to $app"
        else
          echo "Error attaching $app_db to $app, attachments exist"
        fi
      fi
    fi
  fi
fi

# Import any required secrets
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
if [ -n "$INPUT_VM" ]; then
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --remote-only --strategy immediate --ha=$INPUT_HA --vm-size "$INPUT_VMSIZE"
else
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --remote-only --strategy immediate --ha=$INPUT_HA --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY"
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT
