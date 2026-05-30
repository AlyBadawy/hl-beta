#!/bin/bash

# Configuration loader for YAML secrets file
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Get a configuration value from secrets.yaml
# Usage: get_config_value "/path/to/secrets.yaml" "section" "key"
# Example: get_config_value "config/secrets.yaml" "server" "ip"
# Returns the value via echo
get_config_value() {
  local config_file=$1
  local section=$2
  local key=$3

  if [ ! -f "$config_file" ]; then
    echo "ERROR: Config file not found: $config_file" >&2
    return 1
  fi

  # Extract value from section -> key in YAML
  # sed finds lines from "section:" to next non-indented line
  # grep finds the "key:" line within that section
  # sed extracts the value after the colon
  # xargs trims whitespace
  sed -n "/^${section}:/,/^[^ ]/p" "$config_file" | \
    grep "^\s*${key}:" | \
    sed 's/.*: //' | \
    xargs
}

# Load SSH configuration from secrets
# Sets SSH_USER and SERVER_IP variables
load_ssh_config() {
  local config_file=$1

  if [ ! -f "$config_file" ]; then
    echo "ERROR: Config file not found: $config_file" >&2
    return 1
  fi

  SSH_USER=$(get_config_value "$config_file" "server" "ssh_user")
  SERVER_IP=$(get_config_value "$config_file" "server" "ip")

  if [ -z "$SSH_USER" ] || [ -z "$SERVER_IP" ]; then
    echo "ERROR: Failed to load SSH configuration from $config_file" >&2
    return 1
  fi
}

# Load SMTP configuration from secrets
# Sets SMTP_SERVER, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM
load_smtp_config() {
  local config_file=$1

  if [ ! -f "$config_file" ]; then
    echo "ERROR: Config file not found: $config_file" >&2
    return 1
  fi

  SMTP_SERVER=$(get_config_value "$config_file" "smtp" "server")
  SMTP_PORT=$(get_config_value "$config_file" "smtp" "port")
  SMTP_USERNAME=$(get_config_value "$config_file" "smtp" "username")
  SMTP_PASSWORD=$(get_config_value "$config_file" "smtp" "password")
  SMTP_FROM=$(get_config_value "$config_file" "smtp" "from")

  if [ -z "$SMTP_SERVER" ] || [ -z "$SMTP_PORT" ] || [ -z "$SMTP_USERNAME" ] || [ -z "$SMTP_FROM" ]; then
    echo "ERROR: Failed to load SMTP configuration from $config_file" >&2
    return 1
  fi
}

# Load Git configuration from secrets
# Sets GIT_REPO, DOMAIN
load_git_config() {
  local config_file=$1

  if [ ! -f "$config_file" ]; then
    echo "ERROR: Config file not found: $config_file" >&2
    return 1
  fi

  GIT_REPO=$(get_config_value "$config_file" "git" "repo")
  DOMAIN=$(get_config_value "$config_file" "domain" "base")

  if [ -z "$GIT_REPO" ]; then
    echo "ERROR: git.repo not found in $config_file" >&2
    return 1
  fi

  if [ -z "$DOMAIN" ]; then
    echo "ERROR: domain.base not found in $config_file" >&2
    return 1
  fi
}

# Load NAS configuration from secrets
# Sets NAS_IP, NAS_BASE_SHARE, NAS_BASE_MOUNT
load_nas_config() {
  local config_file=$1

  if [ ! -f "$config_file" ]; then
    echo "ERROR: Config file not found: $config_file" >&2
    return 1
  fi

  NAS_IP=$(get_config_value "$config_file" "nas" "ip")
  NAS_BASE_SHARE=$(get_config_value "$config_file" "nas" "base_share")
  NAS_BASE_MOUNT=$(get_config_value "$config_file" "nas" "base_mount")

  if [ -z "$NAS_IP" ] || [ -z "$NAS_BASE_SHARE" ] || [ -z "$NAS_BASE_MOUNT" ]; then
    echo "ERROR: Failed to load NAS configuration from $config_file" >&2
    return 1
  fi
}
