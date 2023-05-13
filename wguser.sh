#!/bin/bash
#
# https://github.com/Nyr/wireguard-install
#
# Copyright (c) 2020 Nyr. Released under the MIT License.


# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

# Discard stdin. Needed when running from an one-liner which includes a newline
read -N 999999 -t 0.001

# Detect environments where $PATH does not include the sbin directories
if ! grep -q sbin <<< "$PATH"; then
	echo '$PATH does not include sbin. Try using "su -" instead of "su".'
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "This installer needs to be run with superuser privileges."
	exit
fi


new_client_setup () {
	# Given a list of the assigned internal IPv4 addresses, obtain the lowest still
	# available octet. Important to start looking at 2, because 1 is our gateway.
	octet=2
	while grep AllowedIPs /etc/wireguard/wg0.conf | cut -d "." -f 4 | cut -d "/" -f 1 | grep -q "$octet"; do
		(( octet++ ))
	done
	# Don't break the WireGuard configuration in case the address space is full
	if [[ "$octet" -eq 255 ]]; then
		echo "253 clients are already configured. The WireGuard internal subnet is full!"
		exit
	fi
	#octet=$unsanitized_client_ip
	key=$(wg genkey)
	psk=$(wg genpsk)
	# Configure client in the server
	cat << EOF >> /etc/wireguard/wg0.conf
# BEGIN_PEER $client
[Peer]
PublicKey = $(wg pubkey <<< $key)
PresharedKey = $psk
AllowedIPs = $unsanitized_client_ip/32$(grep -q 'fddd:2c4:2c4:2c4::1' /etc/wireguard/wg0.conf && echo ", fddd:2c4:2c4:2c4::$octet/128")
# END_PEER $client
EOF
	# Create client configuration
	cat << EOF > ~/"$client".conf
[Interface]
Address = $unsanitized_client_ip/24$(grep -q 'fddd:2c4:2c4:2c4::1' /etc/wireguard/wg0.conf && echo ", fddd:2c4:2c4:2c4::$octet/64")
DNS = $dns
PrivateKey = $key

[Peer]
PublicKey = $(grep PrivateKey /etc/wireguard/wg0.conf | cut -d " " -f 3 | wg pubkey)
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $(grep '^# ENDPOINT' /etc/wireguard/wg0.conf | cut -d " " -f 3):$(grep ListenPort /etc/wireguard/wg0.conf | cut -d " " -f 3)
PersistentKeepalive = 25
EOF
}

print_usage () {
    echo "Usage :"
    echo "    $0 list"
    echo "    $0 add [username] [ip]"
    echo "    $0 del [username]"
    exit 1
}

case "$1" in
    "add")
        if [ -z "$3" ]; then
            print_usage
        fi
        
        unsanitized_client=$2

        # Allow a limited set of characters to avoid conflicts
        client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
        while [[ -z "$client" ]] || grep -q "^# BEGIN_PEER $client$" /etc/wireguard/wg0.conf; do
            echo "$client: invalid name. or already exists."
            exit
        done
        
        unsanitized_client_ip=$3
        rm -f /tmp/validips
        for i in {2..254}
        do
           echo "10.0.0.$i" >> /tmp/validips
        done
        
        while grep -q $unsanitized_client_ip /etc/wireguard/wg0.conf || ! grep -q $unsanitized_client_ip /tmp/validips; do
            echo "$unsanitized_client_ip is in use or invalid"
            exit
        done
        dns="8.8.8.8, 8.8.4.4"
        new_client_setup
        # Append new client configuration to the WireGuard interface
        wg addconf wg0 <(sed -n "/^# BEGIN_PEER $client/,/^# END_PEER $client/p" /etc/wireguard/wg0.conf)
        echo
        qrencode -t UTF8 < ~/"$client.conf"
        echo -e '\xE2\x86\x91 That is a QR code containing your client configuration.'
        echo
        echo "$client added. Configuration available in:" ~/"$client.conf"
        exit
    ;;
    "list")
        cat /etc/wireguard/wg0.conf | grep -e BEGIN_PEER -e Allowed | sed -z 's/\nAllowed/ Allowed/g' | sed 's/# BEGIN_PEER //g' | sed 's/ AllowedIPs =//g' | sed 's/\/32,.*//g'
        exit
    ;;
    "del")
        client=$2
        if [ -z "$2" ]; then
            print_usage
        fi
        grep -q "^# BEGIN_PEER $client" /etc/wireguard/wg0.conf || { echo "$client does not Exist"; exit 1; }

        wg set wg0 peer "$(sed -n "/^# BEGIN_PEER $client$/,\$p" /etc/wireguard/wg0.conf | grep -m 1 PublicKey | cut -d " " -f 3)" remove
        # Remove from the configuration file
        sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" /etc/wireguard/wg0.conf
        echo "$client removed!"
        exit
    ;;
    *)
        print_usage
    ;;
esac

