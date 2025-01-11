#!/bin/bash

INTERFACE="wlan0"

# ROFI_THEME_PATH=""
TPATH="$HOME/temp/iwd_rofi_menu_files"

RAW_NETWORK_FILE="$TPATH/iwd_rofi_menu_ssid_raw.txt"                        # stores iwctl get-networks output
NETWORK_FILE="$TPATH/iwd_rofi_menu_ssid_structured.txt"                     # stores formatted output (SSID,Security,Signal Strength)
RAW_METADATA_FILE="$TPATH/iwd_rofi_menu_metadata_raw.txt"                   # stores iwctl show output
METADATA_FILE="$TPATH/iwd_rofi_menu_metadata_structured.txt"                # stores formatted output for iwctl show
TEMP_PASSWORD_FILE="$TPATH/iwd_rofi_menu_temp_ssid_password.txt"            # stores passphrase

CLEAN_UP_LIST=(
            "$RAW_NETWORK_FILE" \
            "$NETWORK_FILE" \
            "$RAW_METADATA_FILE" \
            "$METADATA_FILE" \
            "$TEMP_PASSWORD_FILE" \
            "$TPATH" \
            )
MENU_OPTIONS=(
            "󱛄  Refresh" \
            "  Enable Wi-Fi" \
            "󰖪  Disable Wi-Fi" \
            "󱚾  Network Info" \
            "󱚸  Scan Networks" \
            "󱚽  Connect" \
            "󱛅  Disconnect" \
            )
 
wifi=()                                                                 # stores network info [signal_strength, SSID, (security)]
ssid=()                                                                 # stores network SSIDs

mkdir -p "$TPATH"

function power_on() {
    iwctl device "$INTERFACE" set-property Powered on
    sleep 2
}

function power_off() {
    iwctl device "$INTERFACE" set-property Powered off
}

function disconnect() {
    iwctl station $INTERFACE disconnect
}

function check_interface_status() {
    local status=$(iwctl station "$INTERFACE" show | grep 'State' | awk '{print $2}')
    if [[ -n "$status" ]]; then
        echo "ON"
    else
        echo "OFF"
    fi
}

function check_wifi_status() {
    local status=$(iwctl station "$INTERFACE" show | grep 'State' | awk '{print $2}')
    if [[ "$status" == "disconnected" ]]; then
        echo "OFF"
    else
        echo "ON"
    fi
}

# Store Network Info in files for later processing
# Issue: IF SSID contains 2 or more consecutive spaces it causes problem
#       cause the way formatting has been performed
function helper_get_networks() {
    # get networks using iwctl 
    iwctl station "$INTERFACE" scan
    sleep 2
    iwctl station "$INTERFACE" get-networks > "$RAW_NETWORK_FILE"

    {
        # Add header
        echo "SSID,SECURITY,SIGNAL"

        # See iwctl get-networks output
        # Remove non-printable characters, then perform a loop
        local i=1
        local wifi_status=$(check_wifi_status)
        sed $'s/[^[:print:]\t]//g' "$RAW_NETWORK_FILE" | while read -r line; do
            # Skip the first 4 lines
            if (( i < 5 )); then
                ((i++))
                continue
            # 5th line
            elif (( i == 5 )); then
                # Depending upon wifi connection status, leading characters changes
                # Might be different on other versions, devices
                # Pull Request, If you find any better way of doing this. Thanks
                if [[ "$wifi_status" == "ON" ]]; then
                    line="${line:18}"
                else
                    line="${line:9}"
                fi
                # Replace 2 or more consecutive spaces with commas
                echo "$line" | sed 's/  \+/,/g'
                ((i++))
                continue
            fi
            # Skip non-empty lines & Replace 2 or more consecutive spaces with commas
            if [[ -z "$line" ]]; then
                continue
            fi
            echo "$line" | sed 's/  \+/,/g'
        done
    } > "$NETWORK_FILE"

    #   <number of filled star>[1;90m<number of empty star>[0m -> ██░░
    sed -e 's/\*\*\*\*\[1;90m\[0m/████/g' \
        -e 's/\*\*\*\[1;90m\*\[0m/███░/g' \
        -e 's/\*\*\[1;90m\*\*\[0m/██░░/g' \
        -e 's/\*\[1;90m\*\*\*\[0m/█░░░/g' \
        -e 's/\[1;90m\*\*\*\*\[0m/░░░░/g' \
        -e 's/\*\*\*\*/████/g' \
        "$NETWORK_FILE" > "${NETWORK_FILE}.tmp" && mv "${NETWORK_FILE}.tmp" "$NETWORK_FILE"
}

# Forwads the stored network info to rofi [Signal Strength SSID (Security)]
function get_networks() {
    ssid=()
    local security=()
    local signal=()

    helper_get_networks
    local local_file="$NETWORK_FILE"

    # CSV structure
    while IFS=',' read -r col1 col2 col3; do
        ssid+=("$col1")
        security+=("$col2")
        signal+=("$col3")
    done < <(tail -n +2 "$local_file")

    for ((i = 0; i < ${#ssid[@]}; i++)); do
        wifi+=("${signal[$i]} ${ssid[$i]} (${security[$i]})")
    done
}

# 2 Issues found in this function
function connect_to_network() {
    local selected_ssid="${ssid[$1]}"
    local known=$(iwctl known-networks list | grep -w "$selected_ssid")

    # Known Networks: Previously connected to and whose configuration is stored
    # Known Safe Networks: Security remains unchanged
    # Known Unsafe Networks: Security has been changed, requires passphrase
    if [[ -n "$known" ]]; then
        # Tries to connect
        local connection_output=$(timeout 10 iwctl station $INTERFACE connect "$selected_ssid" 2>&1)
        sleep 3
        # Issue: After connecting to a known unsafe network, 
        #       attempting to connect to another known safe network may still prompt for a password. 
        #       Although not providing the password won’t cause an issue and 
        #       it will eventually connect to that safe network.
        if [[ -z "$connection_output" ]]; then
            return
        fi
        # echo "Error connecting to $selected_ssid"
    fi

    # Stores password in a temp file
    # Pull Request, If you find any better way of doing this, thanks.
    (rofi -dmenu -password -p "Enter password for $selected_ssid:" \
        -theme-str 'window { width: 500px; height: 50px; }' \
        -theme-str 'entry { width: 500px; }' \
    ) > "$TEMP_PASSWORD_FILE"

    # Exit in case of any error
    # Note: Modify this to handle differnet kinds of error.
    # Issue: After unsuccessfully connecting to a known unsafe network, 
    #       if the user tries too early to connect to the same unsafe network program gets stuck.
    local connection_output=$(iwctl station $INTERFACE connect "$selected_ssid" --passphrase=$(<"$TEMP_PASSWORD_FILE") 2>&1)
    sleep 2
    if [[ -n "$connection_output" ]]; then
        rofi -e "Error connecting to $selected_ssid"
    fi
}

function helper_wifi_status() {
    iwctl station "$INTERFACE" show > "$RAW_METADATA_FILE"

    {
        # See iwctl show output
        # Remove non-printable characters, then perform a loop
        local i=1
        sed $'s/[^[:print:]\t]//g' "$RAW_METADATA_FILE" | while read -r line; do
            # Skip the first 5 lines
            if (( i <= 5 )); then
                ((i++))
                continue
            fi
            # Skip non-empty lines
            if [[ -z "$line" ]]; then
                continue
            fi
            # Replace 2 or more consecutive spaces with commas
            echo "$line" | sed -e 's/  \+/,/g'
        done
    } > "$METADATA_FILE"

    # store the 2nd column
    while IFS=, read -r key value; do
        local list+=("$value")
    done < "$METADATA_FILE"

    echo "${list[@]}"
}

# print wifi metadata
function wifi_status() {
    # stores the values od the metadata
    local values=($(helper_wifi_status))

    # adjast spacing dynamically
    local data=$(awk -F',' '
    BEGIN { max_key_length = 0; }
    {
        # Find the maximum length of the first column
        if (length($1) > max_key_length) max_key_length = length($1);
        keys[NR] = $1;
        values[NR] = $2;
    }
    END {
        for (i = 1; i <= NR; i++) {
            # Adjust spacing dynamically to align the second column
            printf "%-*s  %s\n", max_key_length, keys[i], values[i];
        }
    }' "$METADATA_FILE")

    local selected_index=$(
        echo -e "$data" | \
        rofi -dmenu -mouse -i -p "Network Info:" \
            -theme-str 'window { width: 700px; height: 400px; }' \
            -theme-str 'entry { width: 700px; }' \
            -format i \
    )

    # Copies the selected feild into clipboard
    echo "${values["$selected_index"]}" | xclip -selection clipboard
}

# get and connect to wifi 
function scan() {
    # Loop if 'Rescan' option selected
    local selected_wifi_index=1
    while (( selected_wifi_index == 1 )); do
        # If no option is selected 'selected_wifi_index' becomes 0
        # Adding 0th indexed option to make loop viable
        wifi=("󱚷  Return")
        # Adding option for looping
        wifi+=("󱛇  Rescan")
        get_networks
        # row number 0 based
        selected_wifi_index=$(
            printf "%s\n" "${wifi[@]}" | \
            rofi -dmenu -mouse -i -p "SSID:" \
                -theme-str 'window { width: 400px; height: 300px; }' \
                -theme-str 'entry { width: 400px; }' \
                -format i \
        )

    done

    # Connect if Index >= 2 i.e. a SSID was selected
    if [[ -n "$selected_wifi_index" ]] && (( selected_wifi_index > 1 )); then
        connect_to_network "$((selected_wifi_index - 2))"
    fi
}

function rofi_cmd() {
    # Appends to 'options' 
    local options="${MENU_OPTIONS[0]}"
    local interface_status=$(check_interface_status)
    if [[ "$interface_status" == "OFF" ]]; then
        options+="\n${MENU_OPTIONS[1]}"
    else
        options+="\n${MENU_OPTIONS[2]}"

        local wifi_status=$(check_wifi_status)
        if [[ "$wifi_status" == "OFF" ]]; then
            options+="\n${MENU_OPTIONS[5]}"
        else
            options+="\n${MENU_OPTIONS[3]}"
            options+="\n${MENU_OPTIONS[4]}"
            options+="\n${MENU_OPTIONS[6]}"
        fi
    fi

    local choice=$(echo -e "$options" | \
                    rofi -dmenu -mouse -i -p "Wi-Fi Menu:" \
                    -theme-str 'window { width: 400px; height: 200px; }' \
                    -theme-str 'entry { width: 400px; }' \
                )

    echo "$choice"
}

function run_cmd() {
    case "$1" in
        # Refresh menu
        "${MENU_OPTIONS[0]}")
            sleep 2
            main
            ;;
        # Turn on Wi-Fi Interface
        "${MENU_OPTIONS[1]}")
            power_on
            main
            ;;
        # Turn off Wi-Fi Interface
        "${MENU_OPTIONS[2]}")
            power_off
            ;;
        # Connection Status
        "${MENU_OPTIONS[3]}")
            wifi_status
            main
            ;;
        # List Networks | Connect
        "${MENU_OPTIONS[4]}" | "${MENU_OPTIONS[5]}")
            scan
            main
            ;;
        # Disconnect
        "${MENU_OPTIONS[6]}")
            disconnect
            ;;
        *)
            return
            ;;
    esac
}

function clean_up() {
    for item in "${CLEAN_UP_LIST[@]}"; do
        if [[ -e "$item" ]]; then
            if [[ -d "$item" ]]; then
                rmdir "$item"
            else
                rm "$item"
            fi
        fi
    done
}

function main() {
    local chosen_option=$(rofi_cmd)
    run_cmd "$chosen_option"
    clean_up
}

main