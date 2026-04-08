legacy_profile_dir_for() {
    local legacy_number="$1"
    local email="$2"
    printf '%s/profiles/account-%s-%s\n' "$LEGACY_BACKUP_DIR" "$legacy_number" "$(sanitize_slug "$email")"
}

state_account_config_path() {
    local account_id="$1"
    jq -r --arg id "$account_id" '.accounts[$id].configFile // empty' "$MANIFEST_FILE" | sed "s|^|$STATE_DIR/|"
}

state_account_profile_path() {
    local account_id="$1"
    jq -r --arg id "$account_id" '.accounts[$id].profileDir // empty' "$MANIFEST_FILE" | sed "s|^|$STATE_DIR/|"
}

state_account_email() {
    local account_id="$1"
    jq -r --arg id "$account_id" '.accounts[$id].email // empty' "$MANIFEST_FILE"
}

state_account_alias() {
    local account_id="$1"
    jq -r --arg id "$account_id" '.accounts[$id].alias // empty' "$MANIFEST_FILE"
}

state_account_exists_by_email() {
    local email="$1"
    jq -e --arg email "$email" '.accounts | to_entries[] | select(.value.email == $email)' "$MANIFEST_FILE" >/dev/null 2>&1
}

state_find_account_id() {
    local identifier="$1"
    local account_id
    account_id=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$MANIFEST_FILE" 2>/dev/null | head -n1)
    if [[ -n "$account_id" && "$account_id" != "null" ]]; then
        echo "$account_id"
        return 0
    fi
    account_id=$(jq -r --arg alias "$identifier" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$MANIFEST_FILE" 2>/dev/null | head -n1)
    if [[ -n "$account_id" && "$account_id" != "null" ]]; then
        echo "$account_id"
        return 0
    fi
    echo ""
}

state_current_active_managed_id() {
    local current_email
    current_email=$(read_current_global_email)
    if [[ "$current_email" == "none" ]]; then
        echo ""
        return 0
    fi
    state_find_account_id "$current_email"
}

state_write_manifest_jq() {
    local filter="${!#}"
    local args=("${@:1:$(($# - 1))}")
    local tmp

    tmp=$(mktemp "${MANIFEST_FILE}.XXXXXX")
    if ! jq "${args[@]}" "$filter" "$MANIFEST_FILE" > "$tmp"; then
        rm -f "$tmp"
        error "Failed to update manifest"
        return 1
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$MANIFEST_FILE"
}

state_add_account_record() {
    local account_id="$1"
    local email="$2"
    local uuid="$3"
    local alias_name="$4"
    local config_rel="$5"
    local profile_rel="$6"
    local imported_from="$7"
    local now
    now=$(iso8601_now)

    # shellcheck disable=SC2016  # jq filter references $id/$email/etc via --arg, not shell expansion
    state_write_manifest_jq \
        --arg id "$account_id" \
        --arg email "$email" \
        --arg uuid "$uuid" \
        --arg alias "$alias_name" \
        --arg configFile "$config_rel" \
        --arg profileDir "$profile_rel" \
        --arg importedFrom "$imported_from" \
        --arg now "$now" '
        .accounts[$id] = (
            {
                id: $id,
                email: $email,
                configFile: $configFile,
                profileDir: $profileDir,
                createdAt: $now,
                updatedAt: $now
            } +
            (if ($uuid | length) > 0 then {uuid: $uuid} else {} end) +
            (if ($alias | length) > 0 then {alias: $alias} else {} end) +
            (if ($importedFrom | length) > 0 then {importedFrom: $importedFrom} else {} end)
        ) |
        .order += [$id] |
        .lastUpdated = $now
        '
}

state_set_alias() {
    local account_id="$1"
    local alias_name="$2"
    local now
    now=$(iso8601_now)
    # shellcheck disable=SC2016  # jq filter references $id/$alias/$now via --arg, not shell expansion
    state_write_manifest_jq \
        --arg id "$account_id" \
        --arg alias "$alias_name" \
        --arg now "$now" '
        .accounts[$id].alias = $alias |
        .accounts[$id].updatedAt = $now |
        .lastUpdated = $now
        '
}

state_remove_alias() {
    local account_id="$1"
    local now
    now=$(iso8601_now)
    # shellcheck disable=SC2016  # jq filter references $id/$now via --arg, not shell expansion
    state_write_manifest_jq \
        --arg id "$account_id" \
        --arg now "$now" '
        .accounts[$id] |= del(.alias) |
        .accounts[$id].updatedAt = $now |
        .lastUpdated = $now
        '
}

state_set_active_account() {
    local account_id="$1"
    local now
    now=$(iso8601_now)
    # shellcheck disable=SC2016  # jq filter references $id/$now via --arg, not shell expansion
    state_write_manifest_jq \
        --arg id "$account_id" \
        --arg now "$now" '
        .activeAccountId = $id |
        .lastUpdated = $now
        '
}

state_remove_account_record() {
    local account_id="$1"
    local now
    now=$(iso8601_now)
    # shellcheck disable=SC2016  # jq filter references $id/$now via --arg, not shell expansion
    state_write_manifest_jq \
        --arg id "$account_id" \
        --arg now "$now" '
        del(.accounts[$id]) |
        .order = [.order[] | select(. != $id)] |
        .activeAccountId = (if .activeAccountId == $id then null else .activeAccountId end) |
        .lastUpdated = $now
        '
}

state_alias_in_use_by_other() {
    local alias_name="$1"
    local account_id="$2"
    local other_id
    other_id=$(jq -r --arg alias "$alias_name" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$MANIFEST_FILE" 2>/dev/null | head -n1)
    if [[ -n "$other_id" && "$other_id" != "null" && "$other_id" != "$account_id" ]]; then
        echo "$other_id"
        return 0
    fi
    echo ""
}

state_list_render() {
    local active_id
    active_id=$(state_current_active_managed_id)
    jq -r --arg active "$active_id" '
        if (.order | length) == 0 then
            ""
        else
            .order[] as $id |
            .accounts[$id] |
            "  \(.email)" +
            (if .alias then " [\(.alias)]" else "" end) +
            (if $id == $active then " (active)" else "" end)
        end
    ' "$MANIFEST_FILE"
}

save_account_config_snapshot() {
    local source_config="$1"
    local dest="$2"
    copy_json_file_secure "$source_config" "$dest"
}

legacy_notice() {
    echo "Legacy claude-switch data detected at $(pretty_path "$LEGACY_BACKUP_DIR")."
    echo "Run 'claude-switch import-legacy' to migrate it into v2."
}

ensure_v2_ready_or_notice() {
    if manifest_exists; then
        manifest_assert_valid || return 1
        return 0
    fi
    if legacy_state_exists; then
        legacy_notice
        return 1
    fi
    manifest_init_empty
    return 0
}

legacy_importable_accounts() {
    jq -r '.sequence[]' "$LEGACY_SEQUENCE_FILE"
}

command_import_legacy() {
    local legacy_number email alias_name uuid account_id config_rel profile_rel config_dest profile_dest legacy_config
    local warnings=()

    check_command_backend_requirements "import-legacy" || return 1

    if ! legacy_state_exists; then
        error "No legacy claude-switch state found at $LEGACY_BACKUP_DIR"
        return 1
    fi

    state_dirs_init
    if manifest_exists && [[ "$(manifest_account_count)" -gt 0 ]]; then
        error "v2 state already contains accounts. Remove $(pretty_path "$STATE_DIR") first if you want to re-import."
        return 1
    fi
    manifest_init_empty

    while IFS= read -r legacy_number; do
        email=$(jq -r --arg num "$legacy_number" '.accounts[$num].email // empty' "$LEGACY_SEQUENCE_FILE")
        alias_name=$(jq -r --arg num "$legacy_number" '.accounts[$num].alias // empty' "$LEGACY_SEQUENCE_FILE")
        uuid=$(jq -r --arg num "$legacy_number" '.accounts[$num].uuid // empty' "$LEGACY_SEQUENCE_FILE")
        if [[ -z "$email" ]]; then
            warnings+=("Skipped legacy account $legacy_number with no email")
            continue
        fi

        account_id="legacy-${legacy_number}-$(sanitize_slug "$email")"
        config_rel="configs/${account_id}.json"
        profile_rel="profiles/${account_id}-$(sanitize_slug "$email")"
        config_dest="$STATE_DIR/$config_rel"
        profile_dest="$STATE_DIR/$profile_rel"
        legacy_config="$LEGACY_BACKUP_DIR/configs/.claude-config-${legacy_number}-${email}.json"

        if [[ ! -f "$legacy_config" ]]; then
            warnings+=("Imported $email without a config snapshot")
        else
            copy_json_file_secure "$legacy_config" "$config_dest" || return 1
        fi
        copy_tree_secure "$(legacy_profile_dir_for "$legacy_number" "$email")" "$profile_dest"
        state_add_account_record "$account_id" "$email" "$uuid" "$alias_name" "$config_rel" "$profile_rel" "legacy:${legacy_number}" || return 1

        local creds
        creds=$(legacy_account_credentials_read "$legacy_number" "$email")
        if [[ -n "$creds" ]]; then
            stored_account_credentials_write "$account_id" "$email" "$creds" || return 1
        else
            warnings+=("Imported $email without stored credentials")
        fi
    done < <(legacy_importable_accounts)

    local active_legacy active_id now
    active_legacy=$(jq -r '.activeAccountNumber // empty' "$LEGACY_SEQUENCE_FILE")
    if [[ -n "$active_legacy" && "$active_legacy" != "null" ]]; then
        active_id="legacy-${active_legacy}-$(sanitize_slug "$(jq -r --arg num "$active_legacy" '.accounts[$num].email // empty' "$LEGACY_SEQUENCE_FILE")")"
        state_set_active_account "$active_id" || true
    fi

    now=$(iso8601_now)
    # shellcheck disable=SC2016  # jq filter references $now via --arg, not shell expansion
    state_write_manifest_jq --arg now "$now" '
        .importedLegacy = true |
        .lastUpdated = $now
    '

    echo "Imported $(manifest_account_count) account(s) from legacy state."
    if [[ ${#warnings[@]} -gt 0 ]]; then
        local warning
        for warning in "${warnings[@]}"; do
            warn "$warning"
        done
    fi
    return 0
}
