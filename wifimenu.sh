#!/bin/bash

INTERFACE="wlan0"

# ROFI_THEME_PATH=""
TPATH="$HOME/temp/iwd_rofi_menu_files"

RAW_NETWORK_FILE="$TPATH/iwd_rofi_menu_ssid_raw.txt"                    # stores iwctl get-networks output
NETWORK_FILE="$TPATH/iwd_rofi_menu_ssid_formatted.txt"                  # stores formatted output (SSID,Security,Signal Strength)
TEMP_PASSWORD_FILE="$TPATH/iwd_rofi_menu_temp_ssid_password.txt"        # stores passphrase

CLEAN_UP_LIST=("$RAW_NETWORK_FILE" \
                "$NETWORK_FILE" \
                "$TEMP_PASSWORD_FILE" \
                "$TPATH" \
            )
MENU_OPTIONS=("  Enable Wi-Fi" \
                "󰖪  Disable Wi-Fi" \
                "󱚾  Network Metadata" \
                "󱚸  Scan Networks" \
                "󱚽  Connect" \
                "󱛅  Disconnect" \
            )
 
wifi=()                                                                 # stores network info [signal_strength, SSID, (security)]
ssid=()                                                                 # stores network SSIDs

mkdir -p "$TPATH"

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
    if [[ "$status" == "connected" ]]; then
        echo "ON"
    else
        echo "OFF"
    fi
}

# Store Network Info in files for later processing
# Issue: IF SSID contains 2 or more consecutive spaces it causes problem
#       cause the way formatting has been performed
function store_networks() {
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
                # Replace spaces with commas
                echo "$line" | sed 's/  \+/,/g'
                ((i++))
                continue
            fi
            # Subsequent non-empty lines: Replace spaces with commas
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

    store_networks
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

# Turn the interface power on/off
function power_on() {
    iwctl device "$INTERFACE" set-property Powered on
    sleep 2
}
function power_off() {
    iwctl device "$INTERFACE" set-property Powered off
}

# print wifi metadata
function wifi_status() {
    local metadata=$(iwctl station "$INTERFACE" show | sed '1,6d')

    # Clicking the a metadata feild, will copy the key + value to clipboard
    # Note: Formate it such that it will only copy the value
    echo "$metadata" | \
        rofi -dmenu -i -p "Wi-Fi Metadata:" \
        -theme-str 'window { width: 800px; height: 400px; }' \
        -theme-str 'entry { width: 800px; }' \
        xclip -selection clipboard
}


# get and connect to wifi 
function scan() {
    # Loop if 'Rescan' option selected
    local selected_wifi_index=1
    while (( selected_wifi_index == 1 )); do
        wifi=("󰿅  Exit" "󱛄  Rescan")
        get_networks
        # row number 0 based
        selected_wifi_index=$(printf "%s\n" "${wifi[@]}" | \
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
    local options=""
    local interface_status=$(check_interface_status)
    if [[ "$interface_status" == "OFF" ]]; then
        options+="${MENU_OPTIONS[0]}"
    else
        options+="${MENU_OPTIONS[1]}"

        local wifi_status=$(check_wifi_status)
        if [[ "$wifi_status" == "OFF" ]]; then
            options+="\n${MENU_OPTIONS[4]}"
        else
            options+="\n${MENU_OPTIONS[2]}\n${MENU_OPTIONS[3]}\n${MENU_OPTIONS[5]}"
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
        # Turn on Wi-Fi Interface
        "${MENU_OPTIONS[0]}")
            power_on
            main
            ;;
        # Turn off Wi-Fi Interface
        "${MENU_OPTIONS[1]}")
            power_off
            ;;
        # Connection Status
        "${MENU_OPTIONS[2]}")
            wifi_status
            main
            ;;
        # List Networks | Connect
        "${MENU_OPTIONS[3]}" | "${MENU_OPTIONS[4]}")
            scan
            ;;
        # Disconnect
        "${MENU_OPTIONS[5]}")
            iwctl station $INTERFACE disconnect
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