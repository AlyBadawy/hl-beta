#!/bin/bash

# Validation helper functions for provisioning scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/validation.sh"

# Validate IPv4 address format
validate_ip() {
  local ip=$1
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 0
  else
    return 1
  fi
}

# Validate domain name format (RFC-based)
validate_domain() {
  local domain=$1
  if [[ $domain =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    return 0
  else
    return 1
  fi
}

# Validate port number (1-65535)
validate_port() {
  local port=$1
  if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
    return 0
  else
    return 1
  fi
}

# Validate email address format
validate_email() {
  local email=$1
  if [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 0
  else
    return 1
  fi
}

# Prompt user with validation
# Usage: prompt_with_validation "Prompt text" "default_value" "validator_function_name_or_empty"
# Returns: validated value (via echo)
prompt_with_validation() {
  local prompt=$1
  local default=$2
  local validator=$3
  local value=""

  # Color codes (ensure they're defined in calling script, fallback to empty)
  local YELLOW="${YELLOW:-}"
  local RED="${RED:-}"
  local NC="${NC:-}"

  while true; do
    read -p "$(echo -e ${YELLOW}${prompt}${NC}) [${default}]: " input
    value="${input:-$default}"

    if [ -z "$validator" ] || $validator "$value"; then
      echo "$value"
      return 0
    else
      echo -e "${RED}Invalid input. Please try again.${NC}"
    fi
  done
}
