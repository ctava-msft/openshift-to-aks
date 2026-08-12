#!/bin/sh
set -eu

: "${VITE_AZURE_CLIENT_ID:?VITE_AZURE_CLIENT_ID is required}"
: "${VITE_AZURE_AUTHORITY:?VITE_AZURE_AUTHORITY is required}"
: "${VITE_AZURE_REDIRECT_URI:?VITE_AZURE_REDIRECT_URI is required}"

replace_token() {
    token="$1"
    value="$2"
    escaped_value=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
    find /usr/share/nginx/html -type f \( -name '*.js' -o -name '*.css' -o -name '*.html' \) \
        -exec sed -i "s|${token}|${escaped_value}|g" '{}' +
}

replace_token "__VITE_AZURE_CLIENT_ID__" "$VITE_AZURE_CLIENT_ID"
replace_token "__VITE_AZURE_AUTHORITY__" "$VITE_AZURE_AUTHORITY"
replace_token "__VITE_AZURE_REDIRECT_URI__" "$VITE_AZURE_REDIRECT_URI"
replace_token "__VITE_AZURE_TENANT_ID__" "${VITE_AZURE_TENANT_ID:-}"
replace_token "__VITE_CLINICAL_STAFF_GROUP_ID__" "${VITE_CLINICAL_STAFF_GROUP_ID:-}"
replace_token "__VITE_ADMIN_GROUP_ID__" "${VITE_ADMIN_GROUP_ID:-}"
replace_token "__VITE_AZURE_DOMAIN_HINT__" "${VITE_AZURE_DOMAIN_HINT:-}"
replace_token "__VITE_API_SCOPE__" "${VITE_API_SCOPE:-}"