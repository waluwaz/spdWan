#!/bin/sh

############################################################
##        https://github.com/waluwaz/spdWan               ##
##                   _  								  ##
##                  | |							          ##
##   ___  _ __    __| |									  ##
##  / __|| '_ \  / _` |									  ##
##  \__ \| |_) || (_| |									  ##
##  |___/| .__/  \__,_|	Wan								  ##
##       | |                                              ##
##       |_|                                              ##
##														  ##
##         inspired by and built upon spdMerlin           ##
##                                                        ##
##                                                        ##
############################################################

#############        Shellcheck directives      ############
# shellcheck disable=SC2018
# shellcheck disable=SC2019
# shellcheck disable=SC2059
############################################################

### Start of script variables ###
# wistuplu: It is undesirable to have two flavours of spdMerlin triggering speedtests at the same time.
# spdWan will use the same lockfile as spdMerlin
# By the way, maybe this lock mechanism should be made "script-agnostic", and be common for all scripts
# relying on ookla / speedtest. The filename could become ookla.lock, or speedtest.lock, or speedtest-scripts.lock. 
#
# Having different scriptnames, will probably split the resultsets in two.
# This gives the flexibility of changing the database layout etc, such as adding the servername in the results/csv.
# Unfortunately, it also deprives the user from a common vision on all test results from the WebUI. To be analyzed...
readonly LOCK_NAME="spdMerlin"
readonly SCRIPT_NAME="spdMerlin"
readonly SCRIPT_NAME_LOWER=$(echo $SCRIPT_NAME | tr 'A-Z' 'a-z')
readonly SCRIPT_VERSION="v0.0.3"
SCRIPT_BRANCH="master"
SCRIPT_REPO="https://raw.githubusercontent.com/waluwaz/$SCRIPT_NAME/$SCRIPT_BRANCH"
readonly SCRIPT_DIR="/jffs/addons/$SCRIPT_NAME_LOWER.d"
readonly SCRIPT_WEBPAGE_DIR="$(readlink /www/user)"
readonly SCRIPT_WEB_DIR="$SCRIPT_WEBPAGE_DIR/$SCRIPT_NAME_LOWER"
readonly SHARED_DIR="/jffs/addons/shared-jy"
readonly SHARED_REPO="https://raw.githubusercontent.com/jackyaz/shared-jy/master"
readonly SHARED_WEB_DIR="$SCRIPT_WEBPAGE_DIR/shared-jy"

readonly HOME_DIR="/$(readlink "$HOME")"
readonly OOKLA_DIR="$SCRIPT_DIR/ookla"
readonly OOKLA_LICENSE_DIR="$SCRIPT_DIR/ooklalicense"
readonly OOKLA_HOME_DIR="$HOME_DIR/.config/ookla"

[ -z "$(nvram get odmpid)" ] && ROUTER_MODEL=$(nvram get productid) || ROUTER_MODEL=$(nvram get odmpid)
[ -f /opt/bin/sqlite3 ] && SQLITE3_PATH=/opt/bin/sqlite3 || SQLITE3_PATH=/usr/sbin/sqlite3
[ "$(uname -m)" = "aarch64" ] && ARCH="aarch64" || ARCH="arm"
### End of script variables ###

### Start of output format variables ###
readonly CRIT="\\e[41m"
readonly ERR="\\e[31m"
readonly WARN="\\e[33m"
readonly PASS="\\e[32m"
readonly SETTING="\\e[1m\\e[36m"
### End of output format variables ###

### Start of Speedtest Server Variables ###
serverno=""
servername=""
### End of Speedtest Server Variables ###

# $1 = print to syslog, $2 = message to print, $3 = log level
# shellcheck disable=SC2059
Print_Output(){
	if [ "$1" = "true" ]; then
		logger -t "$SCRIPT_NAME" "$2"
	fi
	printf "\\e[1m${3}%s\\e[0m\\n\\n" "$2"
}

Firmware_Version_Check(){
	if nvram get rc_support | grep -qF "am_addons"; then
		return 0
	else
		return 1
	fi
}

### Code for these functions inspired by https://github.com/Adamm00 - credit to @Adamm ###
Check_Lock(){
	if [ -f "/tmp/$LOCK_NAME.lock" ]; then
		ageoflock=$(($(date +%s) - $(date +%s -r /tmp/$LOCK_NAME.lock)))
		if [ "$ageoflock" -gt 600 ]; then
			Print_Output true "Stale lock file found (>600 seconds old) - purging lock" "$ERR"
			kill "$(sed -n '1p' /tmp/$LOCK_NAME.lock)" >/dev/null 2>&1
			Clear_Lock
			echo "$$" > "/tmp/$LOCK_NAME.lock"
			return 0
		else
			Print_Output true "Lock file found (age: $ageoflock seconds) - stopping to prevent duplicate runs" "$ERR"
			if [ -z "$1" ]; then
				exit 1
			else
				if [ "$1" = "webui" ]; then
					echo 'var spdteststatus = "LOCKED";' > /tmp/detect_spdtest.js
					exit 1
				fi
				return 1
			fi
		fi
	else
		echo "$$" > "/tmp/$LOCK_NAME.lock"
		return 0
	fi
}

Clear_Lock(){
	rm -f "/tmp/$LOCK_NAME.lock" 2>/dev/null
	return 0
}

Check_Swap(){
	if [ "$(wc -l < /proc/swaps)" -ge 2 ]; then return 0; else return 1; fi
}

############################################################################

Set_Version_Custom_Settings(){
	SETTINGSFILE="/jffs/addons/custom_settings.txt"
	case "$1" in
		local)
			if [ -f "$SETTINGSFILE" ]; then
				if [ "$(grep -c "spdmerlin_version_local" $SETTINGSFILE)" -gt 0 ]; then
					if [ "$2" != "$(grep "spdmerlin_version_local" /jffs/addons/custom_settings.txt | cut -f2 -d' ')" ]; then
						sed -i "s/spdmerlin_version_local.*/spdmerlin_version_local $2/" "$SETTINGSFILE"
					fi
				else
					echo "spdmerlin_version_local $2" >> "$SETTINGSFILE"
				fi
			else
				echo "spdmerlin_version_local $2" >> "$SETTINGSFILE"
			fi
		;;
		server)
			if [ -f "$SETTINGSFILE" ]; then
				if [ "$(grep -c "spdmerlin_version_server" $SETTINGSFILE)" -gt 0 ]; then
					if [ "$2" != "$(grep "spdmerlin_version_server" /jffs/addons/custom_settings.txt | cut -f2 -d' ')" ]; then
						sed -i "s/spdmerlin_version_server.*/spdmerlin_version_server $2/" "$SETTINGSFILE"
					fi
				else
					echo "spdmerlin_version_server $2" >> "$SETTINGSFILE"
				fi
			else
				echo "spdmerlin_version_server $2" >> "$SETTINGSFILE"
			fi
		;;
	esac
}

Update_Check(){
	echo 'var updatestatus = "InProgress";' > "$SCRIPT_WEB_DIR/detect_update.js"
	doupdate="false"
	localver=$(grep "SCRIPT_VERSION=" "/jffs/scripts/$SCRIPT_NAME_LOWER" | grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})')
	/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME_LOWER.sh" | grep -qF "jackyaz" || { Print_Output true "404 error detected - stopping update" "$ERR"; return 1; }
	serverver=$(/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME_LOWER.sh" | grep "SCRIPT_VERSION=" | grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})')
	if [ "$localver" != "$serverver" ]; then
		doupdate="version"
		Set_Version_Custom_Settings server "$serverver"
		echo 'var updatestatus = "'"$serverver"'";'  > "$SCRIPT_WEB_DIR/detect_update.js"
	else
		localmd5="$(md5sum "/jffs/scripts/$SCRIPT_NAME_LOWER" | awk '{print $1}')"
		remotemd5="$(curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME_LOWER.sh" | md5sum | awk '{print $1}')"
		if [ "$localmd5" != "$remotemd5" ]; then
			doupdate="md5"
			Set_Version_Custom_Settings server "$serverver-hotfix"
			echo 'var updatestatus = "'"$serverver-hotfix"'";'  > "$SCRIPT_WEB_DIR/detect_update.js"
		fi
	fi
	if [ "$doupdate" = "false" ]; then
		echo 'var updatestatus = "None";'  > "$SCRIPT_WEB_DIR/detect_update.js"
	fi
	echo "$doupdate,$localver,$serverver"
}

Update_Version(){
	if [ -z "$1" ]; then
		updatecheckresult="$(Update_Check)"
		isupdate="$(echo "$updatecheckresult" | cut -f1 -d',')"
		localver="$(echo "$updatecheckresult" | cut -f2 -d',')"
		serverver="$(echo "$updatecheckresult" | cut -f3 -d',')"
		
		if [ "$isupdate" = "version" ]; then
			Print_Output true "New version of $SCRIPT_NAME available - $serverver" "$PASS"
		elif [ "$isupdate" = "md5" ]; then
			Print_Output true "MD5 hash of $SCRIPT_NAME does not match - hotfix available - $serverver" "$PASS"
		fi
		
		if [ "$isupdate" != "false" ]; then
			printf "\\n\\e[1mDo you want to continue with the update? (y/n)\\e[0m  "
			read -r confirm
			case "$confirm" in
				y|Y)
					printf "\\n"
					Update_File shared-jy.tar.gz
					Update_File "$ARCH.tar.gz"
					Update_File spdstats_www.asp
					
					/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME_LOWER.sh" -o "/jffs/scripts/$SCRIPT_NAME_LOWER" && Print_Output true "$SCRIPT_NAME successfully updated"
					chmod 0755 "/jffs/scripts/$SCRIPT_NAME_LOWER"
					Set_Version_Custom_Settings local "$serverver"
					Set_Version_Custom_Settings server "$serverver"
					Clear_Lock
					PressEnter
					exec "$0"
					exit 0
				;;
				*)
					printf "\\n"
					Clear_Lock
					return 1
				;;
			esac
					
		else
			Print_Output true "No updates available - latest is $localver" "$WARN"
			Clear_Lock
		fi
	fi
	
	if [ "$1" = "force" ]; then
		serverver=$(/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME_LOWER.sh" | grep "SCRIPT_VERSION=" | grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})')
		Print_Output true "Downloading latest version ($serverver) of $SCRIPT_NAME" "$PASS"
		Update_File shared-jy.tar.gz
		Update_File "$ARCH.tar.gz"
		Update_File spdstats_www.asp
		/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME_LOWER.sh" -o "/jffs/scripts/$SCRIPT_NAME_LOWER" && Print_Output true "$SCRIPT_NAME successfully updated"
		chmod 0755 "/jffs/scripts/$SCRIPT_NAME_LOWER"
		Set_Version_Custom_Settings local "$serverver"
		Set_Version_Custom_Settings server "$serverver"
		Clear_Lock
		if [ -z "$2" ]; then
			PressEnter
			exec "$0"
		elif [ "$2" = "unattended" ]; then
			exec "$0" postupdate
		fi
		exit 0
	fi
}

Update_File(){
	if [ "$1" = "$ARCH.tar.gz" ]; then
		tmpfile="/tmp/$1"
		Download_File "$SCRIPT_REPO/$1" "$tmpfile"
		tar -xzf "$tmpfile" -C "/tmp"
		rm -f "$tmpfile"
		localmd5="$(md5sum "$OOKLA_DIR/speedtest" | awk '{print $1}')"
		tmpmd5="$(md5sum /tmp/speedtest | awk '{print $1}')"
		if [ "$localmd5" != "$tmpmd5" ]; then
			rm -f "$OOKLA_DIR"/*
			Download_File "$SCRIPT_REPO/$1" "$OOKLA_DIR/$1"
			tar -xzf "$OOKLA_DIR/$1" -C "$OOKLA_DIR"
			rm -f "$OOKLA_DIR/$1"
			chmod 0755 "$OOKLA_DIR/speedtest"
			Print_Output true "New version of Speedtest CLI downloaded to $OOKLA_DIR/speedtest" "$PASS"
		fi
		rm -f "/tmp/speedtest*"
	elif [ "$1" = "spdstats_www.asp" ]; then
		tmpfile="/tmp/$1"
		Download_File "$SCRIPT_REPO/$1" "$tmpfile"
		if ! diff -q "$tmpfile" "$SCRIPT_DIR/$1" >/dev/null 2>&1; then
			if [ -f "$SCRIPT_DIR/$1" ]; then
				Get_WebUI_Page "$SCRIPT_DIR/$1"
				sed -i "\\~$MyPage~d" /tmp/menuTree.js
				rm -f "$SCRIPT_WEBPAGE_DIR/$MyPage" 2>/dev/null
			fi
			Download_File "$SCRIPT_REPO/$1" "$SCRIPT_DIR/$1"
			Print_Output true "New version of $1 downloaded" "$PASS"
			Mount_WebUI
		fi
		rm -f "$tmpfile"
	elif [ "$1" = "shared-jy.tar.gz" ]; then
		if [ ! -f "$SHARED_DIR/$1.md5" ]; then
			Download_File "$SHARED_REPO/$1" "$SHARED_DIR/$1"
			Download_File "$SHARED_REPO/$1.md5" "$SHARED_DIR/$1.md5"
			tar -xzf "$SHARED_DIR/$1" -C "$SHARED_DIR"
			rm -f "$SHARED_DIR/$1"
			Print_Output true "New version of $1 downloaded" "$PASS"
		else
			localmd5="$(cat "$SHARED_DIR/$1.md5")"
			remotemd5="$(curl -fsL --retry 3 "$SHARED_REPO/$1.md5")"
			if [ "$localmd5" != "$remotemd5" ]; then
				Download_File "$SHARED_REPO/$1" "$SHARED_DIR/$1"
				Download_File "$SHARED_REPO/$1.md5" "$SHARED_DIR/$1.md5"
				tar -xzf "$SHARED_DIR/$1" -C "$SHARED_DIR"
				rm -f "$SHARED_DIR/$1"
				Print_Output true "New version of $1 downloaded" "$PASS"
			fi
		fi
	else
		return 1
	fi
}

Validate_Bandwidth(){
	if echo "$1" | /bin/grep -oq "^[0-9]*\.\?[0-9]*$"; then
		return 0
	else
		return 1
	fi
}

Validate_Number(){
	if [ "$1" -eq "$1" ] 2>/dev/null; then
		return 0
	else
		return 1
	fi
}

License_Acceptance(){
	case "$1" in
		check)
			if [ -f "$HOME_DIR/.config/ookla/speedtest-cli.json" ]; then
				return 0
			else
				return 1
			fi
		;;
		accept)
			while true; do
				printf "\\n\\n==============================================================================\\n"
				printf "\\nYou may only use this Speedtest software and information generated\\n"
				printf "from it for personal, non-commercial use, through a command line\\n"
				printf "interface on a personal computer. Your use of this software is subject\\n"
				printf "to the End User License Agreement, Terms of Use and Privacy Policy at\\n"
				printf "these URLs:\\n"
				printf "\\n    https://www.speedtest.net/about/eula\\n"
				printf "    https://www.speedtest.net/about/terms\\n"
				printf "    https://www.speedtest.net/about/privacy\\n\\n"
				printf "==============================================================================\\n\\n"
				printf "Ookla collects certain data through Speedtest that may be considered\\n"
				printf "personally identifiable, such as your IP address, unique device\\n"
				printf "identifiers or location. Ookla believes it has a legitimate interest\\n"
				printf "to share this data with internet providers, hardware manufacturers and\\n"
				printf "industry regulators to help them understand and create a better and\\n"
				printf "faster internet. For further information including how the data may be\\n"
				printf "shared, where the data may be transferred and Ookla's contact details,\\n"
				printf "please see our Privacy Policy at:\\n"
				printf "\\n    http://www.speedtest.net/privacy\\n"
				printf "\\n==============================================================================\\n\\n"
				
				printf "\\n\\e[1mYou must accept the license agreements for Speedtest CLI to use %s. Do you want to continue? (y/n)\\e[0m\\n" "$SCRIPT_NAME"
				printf "\\e[1mNote: This will require an initial speedtest to run, please be patient\\e[0m\\n"
				printf "\\e[1mEnter answer:\\e[0m  "
				read -r confirm
				case "$confirm" in
					y|Y)
						"$OOKLA_DIR/speedtest" --accept-license --accept-gdpr >/dev/null 2>&1
						License_Acceptance save
						return 0
					;;
					*)
						Print_Output true "Licenses not accepted, stopping" "$ERR"
						return 1
					;;
				esac
			done
		;;
		save)
			if [ ! -f "$OOKLA_LICENSE_DIR/speedtest-cli.json" ]; then
				cp "$HOME_DIR/.config/ookla/speedtest-cli.json" "$OOKLA_LICENSE_DIR/speedtest-cli.json"
				Print_Output true "Licenses accepted and saved to persistent storage" "$PASS"
			fi
		;;
		load)
			if [ -f "$OOKLA_LICENSE_DIR/speedtest-cli.json" ]; then
				cp "$OOKLA_LICENSE_DIR/speedtest-cli.json" "$HOME_DIR/.config/ookla/speedtest-cli.json"
				return 0
			else
				Print_Output true "Licenses haven't been accepted previously, nothing to load" "$ERR"
				return 1
			fi
		;;
	esac
}

Create_Dirs(){
	if [ ! -d "$SCRIPT_DIR" ]; then
		mkdir -p "$SCRIPT_DIR"
	fi
	
	if [ ! -d "$SCRIPT_STORAGE_DIR" ]; then
		mkdir -p "$SCRIPT_STORAGE_DIR"
	fi
	
	if [ ! -d "$CSV_OUTPUT_DIR" ]; then
		mkdir -p "$CSV_OUTPUT_DIR"
	fi
	
	if [ ! -d "$OOKLA_DIR" ]; then
		mkdir -p "$OOKLA_DIR"
	fi
	
	if [ ! -d "$OOKLA_LICENSE_DIR" ]; then
		mkdir -p "$OOKLA_LICENSE_DIR"
	fi
	
	if [ ! -d "$OOKLA_HOME_DIR" ]; then
		mkdir -p "$OOKLA_HOME_DIR"
	fi
	
	if [ ! -d "$SHARED_DIR" ]; then
		mkdir -p "$SHARED_DIR"
	fi
	
	if [ ! -d "$SCRIPT_WEBPAGE_DIR" ]; then
		mkdir -p "$SCRIPT_WEBPAGE_DIR"
	fi
	
	if [ ! -d "$SCRIPT_WEB_DIR" ]; then
		mkdir -p "$SCRIPT_WEB_DIR"
	fi
}

Create_Symlinks(){
	printf "WAN\\n" > "$SCRIPT_INTERFACES"
	
	for index in 1 2 3 4 5; do
		comment=""
#		if [ ! -f "/sys/class/net/tun1$index/operstate" ] || [ "$(cat "/sys/class/net/tun1$index/operstate")" = "down" ]; then
#			comment=" #excluded - interface not up#"
#		fi
		if [ "$index" -lt 5 ]; then
			printf "VPNC%s%s\\n" "$index" "$comment" >> "$SCRIPT_INTERFACES"
		else
			printf "VPNC%s%s\\n" "$index" "$comment" >> "$SCRIPT_INTERFACES"
		fi
	done
	
	if [ "$1" = "force" ]; then
		rm -f "$SCRIPT_INTERFACES_USER"
	fi
	
	if [ ! -f "$SCRIPT_INTERFACES_USER" ]; then
		touch "$SCRIPT_INTERFACES_USER"
	fi
	
	while IFS='' read -r line || [ -n "$line" ]; do
		if [ "$(grep -c "$(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')" "$SCRIPT_INTERFACES_USER")" -eq 0 ]; then
			printf "%s\\n" "$line" >> "$SCRIPT_INTERFACES_USER"
		fi
	done < "$SCRIPT_INTERFACES"
	
	interfacecount="$(wc -l < "$SCRIPT_INTERFACES_USER")"
	COUNTER=1
	until [ $COUNTER -gt "$interfacecount" ]; do
		Set_Interface_State "$COUNTER"
		COUNTER=$((COUNTER + 1))
	done
	
	rm -rf "${SCRIPT_WEB_DIR:?}/"* 2>/dev/null
	
	ln -s /tmp/spd-stats.txt "$SCRIPT_WEB_DIR/spd-stats.htm" 2>/dev/null
	ln -s /tmp/spd-result.txt "$SCRIPT_WEB_DIR/spd-result.htm" 2>/dev/null
	ln -s /tmp/detect_spdtest.js "$SCRIPT_WEB_DIR/detect_spdtest.js" 2>/dev/null
	
	ln -s "$SCRIPT_CONF" "$SCRIPT_WEB_DIR/config.htm" 2>/dev/null
	ln -s "$SCRIPT_INTERFACES_USER"  "$SCRIPT_WEB_DIR/interfaces_user.htm" 2>/dev/null
	ln -s "$SCRIPT_STORAGE_DIR/spdjs.js" "$SCRIPT_WEB_DIR/spdjs.js" 2>/dev/null
	ln -s "$SCRIPT_STORAGE_DIR/spdtitletext.js" "$SCRIPT_WEB_DIR/spdtitletext.js" 2>/dev/null
	
	ln -s "$CSV_OUTPUT_DIR" "$SCRIPT_WEB_DIR/csv" 2>/dev/null
	
	if [ ! -d "$SHARED_WEB_DIR" ]; then
		ln -s "$SHARED_DIR" "$SHARED_WEB_DIR" 2>/dev/null
	fi
}

Conf_FromSettings(){
	SETTINGSFILE="/jffs/addons/custom_settings.txt"
	TMPFILE="/tmp/spdmerlin_settings.txt"
	if [ -f "$SETTINGSFILE" ]; then
		if [ "$(grep "spdmerlin_" $SETTINGSFILE | grep -v "version" -c)" -gt 0 ]; then
			Print_Output true "Updated settings from WebUI found, merging into $SCRIPT_CONF" "$PASS"
			cp -a "$SCRIPT_CONF" "$SCRIPT_CONF.bak"
			grep "spdmerlin_" "$SETTINGSFILE" | grep -v "version" > "$TMPFILE"
			sed -i "s/spdmerlin_//g;s/ /=/g" "$TMPFILE"
			while IFS='' read -r line || [ -n "$line" ]; do
				SETTINGNAME="$(echo "$line" | cut -f1 -d'=' | awk '{ print toupper($1) }')"
				SETTINGVALUE="$(echo "$line" | cut -f2- -d'=' | sed "s/=/ /g")"
				sed -i "s~$SETTINGNAME=.*~$SETTINGNAME=$SETTINGVALUE~" "$SCRIPT_CONF"
			done < "$TMPFILE"
			grep 'spdmerlin_version' "$SETTINGSFILE" > "$TMPFILE"
			sed -i "\\~spdmerlin_~d" "$SETTINGSFILE"
			mv "$SETTINGSFILE" "$SETTINGSFILE.bak"
			cat "$SETTINGSFILE.bak" "$TMPFILE" > "$SETTINGSFILE"
			rm -f "$TMPFILE"
			rm -f "$SETTINGSFILE.bak"
			
			ScriptStorageLocation "$(ScriptStorageLocation check)"
			Create_Symlinks
			
			if AutomaticMode check; then
				Auto_Cron delete 2>/dev/null
				Auto_Cron create 2>/dev/null
			else
				Auto_Cron delete 2>/dev/null
			fi
			
			if [ "$(AutoBWEnable check)" = "true" ]; then
				if [ "$(ExcludeFromQoS check)" = "false" ]; then
					Print_Output true "Enabling Exclude from QoS (required for AutoBW)"
					ExcludeFromQoS enable
				fi
			fi
			
			Generate_CSVs
			
			Print_Output true "Merge of updated settings from WebUI completed successfully" "$PASS"
		else
			Print_Output true "No updated settings from WebUI found, no merge into $SCRIPT_CONF necessary" "$PASS"
		fi
	fi
}

Interfaces_FromSettings(){
	SETTINGSFILE="/jffs/addons/custom_settings.txt"
	if [ -f "$SETTINGSFILE" ]; then
		if grep -q "spdmerlin_ifaces_enabled" "$SETTINGSFILE"; then
			Print_Output true "Updated interfaces from WebUI found, merging into $SCRIPT_INTERFACES_USER" "$PASS"
			cp -a "$SCRIPT_INTERFACES_USER" "$SCRIPT_INTERFACES_USER.bak"
			SETTINGVALUE="$(grep "spdmerlin_ifaces_enabled" "$SETTINGSFILE" | cut -f2 -d' ')"
			sed -i "\\~spdmerlin_ifaces_enabled~d" "$SETTINGSFILE"
			
			printf "WAN #excluded#\\n" > "$SCRIPT_INTERFACES"
			
			for index in 1 2 3 4 5; do
				comment=" #excluded#"
#				if [ ! -f "/sys/class/net/tun1$index/operstate" ] || [ "$(cat "/sys/class/net/tun1$index/operstate")" = "down" ]; then
#					comment=" #excluded - interface not up#"
#				fi
				printf "VPNC%s%s\\n" "$index" "$comment" >> "$SCRIPT_INTERFACES"
			done
			
			echo "" > "$SCRIPT_INTERFACES_USER"
			
			while IFS='' read -r line || [ -n "$line" ]; do
				if [ "$(grep -c "$(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')" "$SCRIPT_INTERFACES_USER")" -eq 0 ]; then
					printf "%s\\n" "$line" >> "$SCRIPT_INTERFACES_USER"
				fi
			done < "$SCRIPT_INTERFACES"
			
			interfacecount="$(wc -l < "$SCRIPT_INTERFACES_USER")"
			COUNTER=1
			until [ $COUNTER -gt "$interfacecount" ]; do
				Set_Interface_State "$COUNTER"
				COUNTER=$((COUNTER + 1))
			done
			
			for iface in $(echo "$SETTINGVALUE" | sed "s/,/ /g"); do
				ifacelinenumber="$(grep -n "$iface" "$SCRIPT_INTERFACES_USER" | cut -f1 -d':')"
				interfaceline="$(sed "$ifacelinenumber!d" "$SCRIPT_INTERFACES_USER" | awk '{$1=$1};1')"
				
				if echo "$interfaceline" | grep -q "#excluded" ; then
					IFACE_LOWER="$(Get_Interface_From_Name "$(echo "$interfaceline" | cut -f1 -d"#" | sed 's/ *$//')" | tr "A-Z" "a-z")"
#					if [ ! -f "/sys/class/net/$IFACE_LOWER/operstate" ] || [ "$(cat "/sys/class/net/$IFACE_LOWER/operstate")" = "down" ]; then
#						sed -i "$ifacelinenumber"'s/ #excluded#/ #excluded - interface not up#/' "$SCRIPT_INTERFACES_USER"
#					else
						sed -i "$ifacelinenumber"'s/ #excluded - interface not up#//' "$SCRIPT_INTERFACES_USER"
						sed -i "$ifacelinenumber"'s/ #excluded#//' "$SCRIPT_INTERFACES_USER"
#					fi
				else
					IFACE_LOWER="$(Get_Interface_From_Name "$(echo "$interfaceline" | cut -f1 -d"#" | sed 's/ *$//')" | tr "A-Z" "a-z")"
#					if [ ! -f "/sys/class/net/$IFACE_LOWER/operstate" ] || [ "$(cat "/sys/class/net/$IFACE_LOWER/operstate")" = "down" ]; then
#						sed -i "$ifacelinenumber"'s/$/ #excluded - interface not up#/' "$SCRIPT_INTERFACES_USER"
#					fi
				fi
			done
			
			awk 'NF' "$SCRIPT_INTERFACES_USER" > /tmp/spd-interfaces
			mv /tmp/spd-interfaces "$SCRIPT_INTERFACES_USER"
			
			Print_Output true "Merge of updated interfaces from WebUI completed successfully" "$PASS"
		else
			Print_Output true "No updated interfaces from WebUI found, no merge into $SCRIPT_INTERFACES_USER necessary" "$PASS"
		fi
	fi
}

Conf_Exists(){
	if [ -f "$SCRIPT_CONF" ]; then
		dos2unix "$SCRIPT_CONF"
		chmod 0644 "$SCRIPT_CONF"
		sed -i -e 's/"//g' "$SCRIPT_CONF"
		if grep -q "SCHEDULESTART" "$SCRIPT_CONF"; then
			{
				echo "SCHDAYS=*";
				echo "SCHHOURS=*";
				echo "SCHMINS=12,42";
			} >> "$SCRIPT_CONF"
			sed -i '/SCHEDULESTART/d;/SCHEDULEEND/d;/MINUTE/d;/TESTFREQUENCY/d' "$SCRIPT_CONF"
			if AutomaticMode check; then
				Auto_Cron delete 2>/dev/null
				Auto_Cron create 2>/dev/null
			else
				Auto_Cron delete 2>/dev/null
			fi
		fi
		if ! grep -q "AUTOBW_AVERAGE_CALC" "$SCRIPT_CONF"; then
			echo "AUTOBW_AVERAGE_CALC=10" >> "$SCRIPT_CONF"
		fi
		return 0
	else
		{ echo "PREFERREDSERVER_WAN=0|None configured"; echo "USEPREFERRED_WAN=false"; echo "AUTOMATED=true" ; echo "OUTPUTDATAMODE=raw"; echo "OUTPUTTIMEMODE=unix"; echo "STORAGELOCATION=jffs"; } >> "$SCRIPT_CONF"
		for index in 1 2 3 4 5; do
			{ echo "PREFERREDSERVER_VPNC$index=0|None configured"; echo "USEPREFERRED_VPNC$index=false"; } >> "$SCRIPT_CONF"
		done
		{ echo "AUTOBW_ENABLED=false"; echo "AUTOBW_SF_DOWN=95"; echo "AUTOBW_SF_UP=95"; echo "AUTOBW_ULIMIT_DOWN=0"; echo "AUTOBW_LLIMIT_DOWN=0"; echo "AUTOBW_ULIMIT_UP=0"; echo "AUTOBW_LLIMIT_UP=0"; echo "AUTOBW_THRESHOLD_UP=10"; echo "AUTOBW_THRESHOLD_DOWN=10"; echo "AUTOBW_AVERAGE_CALC=10"; echo "STORERESULTURL=false"; echo "EXCLUDEFROMQOS=true"; echo "SCHDAYS=*"; echo "SCHHOURS=*"; echo "SCHMINS=12,42";} >> "$SCRIPT_CONF"
		return 1
	fi
}

Auto_ServiceEvent(){
	case $1 in
		create)
			if [ -f /jffs/scripts/service-event ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/service-event)
				# shellcheck disable=SC2016
				STARTUPLINECOUNTEX=$(grep -cx "/jffs/scripts/$SCRIPT_NAME_LOWER service_event"' "$@" & # '"$SCRIPT_NAME" /jffs/scripts/service-event)
				
				if [ "$STARTUPLINECOUNT" -gt 1 ] || { [ "$STARTUPLINECOUNTEX" -eq 0 ] && [ "$STARTUPLINECOUNT" -gt 0 ]; }; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/service-event
				fi
				
				if [ "$STARTUPLINECOUNTEX" -eq 0 ]; then
					# shellcheck disable=SC2016
					echo "/jffs/scripts/$SCRIPT_NAME_LOWER service_event"' "$@" & # '"$SCRIPT_NAME" >> /jffs/scripts/service-event
				fi
			else
				echo "#!/bin/sh" > /jffs/scripts/service-event
				echo "" >> /jffs/scripts/service-event
				# shellcheck disable=SC2016
				echo "/jffs/scripts/$SCRIPT_NAME_LOWER service_event"' "$@" & # '"$SCRIPT_NAME" >> /jffs/scripts/service-event
				chmod 0755 /jffs/scripts/service-event
			fi
		;;
		delete)
			if [ -f /jffs/scripts/service-event ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/service-event)
				
				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/service-event
				fi
			fi
		;;
	esac
}

Auto_Startup(){
	case $1 in
		create)
			if [ -f /jffs/scripts/services-start ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/services-start)
				
				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/services-start
				fi
			fi
			
			if [ -f /jffs/scripts/post-mount ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/post-mount)
				STARTUPLINECOUNTEX=$(grep -cx "/jffs/scripts/$SCRIPT_NAME_LOWER startup"' "$@" & # '"$SCRIPT_NAME" /jffs/scripts/post-mount)
				
				if [ "$STARTUPLINECOUNT" -gt 1 ] || { [ "$STARTUPLINECOUNTEX" -eq 0 ] && [ "$STARTUPLINECOUNT" -gt 0 ]; }; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/post-mount
				fi
				
				if [ "$STARTUPLINECOUNTEX" -eq 0 ]; then
					echo "/jffs/scripts/$SCRIPT_NAME_LOWER startup"' "$@" & # '"$SCRIPT_NAME" >> /jffs/scripts/post-mount
				fi
			else
				echo "#!/bin/sh" > /jffs/scripts/post-mount
				echo "" >> /jffs/scripts/post-mount
				echo "/jffs/scripts/$SCRIPT_NAME_LOWER startup"' "$@" & # '"$SCRIPT_NAME" >> /jffs/scripts/post-mount
				chmod 0755 /jffs/scripts/post-mount
			fi
		;;
		delete)
			if [ -f /jffs/scripts/services-start ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/services-start)
				
				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/services-start
				fi
			fi
			
			if [ -f /jffs/scripts/post-mount ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/post-mount)
				
				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/post-mount
				fi
			fi
		;;
	esac
}

Auto_Cron(){
	case $1 in
		create)
			STARTUPLINECOUNT=$(cru l | grep -c "$SCRIPT_NAME")
			
			if [ "$STARTUPLINECOUNT" -eq 0 ]; then
				CRU_DAYNUMBERS="$(grep "SCHDAYS" "$SCRIPT_CONF" | cut -f2 -d"=" | sed 's/Sun/0/;s/Mon/1/;s/Tues/2/;s/Wed/3/;s/Thurs/4/;s/Fri/5/;s/Sat/6/;')"
				CRU_HOURS="$(grep "SCHHOURS" "$SCRIPT_CONF" | cut -f2 -d"=")"
				CRU_MINUTES="$(grep "SCHMINS" "$SCRIPT_CONF" | cut -f2 -d"=")"
				cru a "$SCRIPT_NAME" "$CRU_MINUTES $CRU_HOURS * * $CRU_DAYNUMBERS /jffs/scripts/$SCRIPT_NAME_LOWER generate"
			fi
		;;
		delete)
			STARTUPLINECOUNT=$(cru l | grep -c "$SCRIPT_NAME")
			
			if [ "$STARTUPLINECOUNT" -gt 0 ]; then
				cru d "$SCRIPT_NAME"
			fi
		;;
	esac
}

Get_Interface_From_Name(){
	IFACE=""
	case "$1" in
		WAN)
			if [ "$(nvram get sw_mode)" -ne 1 ]; then
				IFACE="br0"
			elif [ "$(nvram get wan0_proto)" = "pppoe" ] || [ "$(nvram get wan0_proto)" = "pptp" ] || [ "$(nvram get wan0_proto)" = "l2tp" ]; then
				IFACE="ppp0"
			else
				IFACE="$(nvram get wan0_ifname)"
			fi
		;;
		VPNC1)
			IFACE="tun11"
		;;
		VPNC2)
			IFACE="tun12"
		;;
		VPNC3)
			IFACE="tun13"
		;;
		VPNC4)
			IFACE="tun14"
		;;
		VPNC5)
			IFACE="tun15"
		;;
	esac
	
	echo "$IFACE"
}

Set_Interface_State(){
	interfaceline="$(sed "$1!d" "$SCRIPT_INTERFACES_USER" | awk '{$1=$1};1')"
	if echo "$interfaceline" | grep -q "VPN" ; then
		if echo "$interfaceline" | grep -q "#excluded" ; then
			IFACE_LOWER="$(Get_Interface_From_Name "$(echo "$interfaceline" | cut -f1 -d"#" | sed 's/ *$//')" | tr "A-Z" "a-z")"
#			if [ ! -f "/sys/class/net/$IFACE_LOWER/operstate" ] || [ "$(cat "/sys/class/net/$IFACE_LOWER/operstate")" = "down" ]; then
#				sed -i "$1"'s/ #excluded#/ #excluded - interface not up#/' "$SCRIPT_INTERFACES_USER"
#			else
				sed -i "$1"'s/ #excluded - interface not up#/ #excluded#/' "$SCRIPT_INTERFACES_USER"
#			fi
		fi
	fi
}

Generate_Interface_List(){
	ScriptHeader
	goback="false"
	printf "Retrieving list of interfaces...\\n\\n"
	interfacecount="$(wc -l < "$SCRIPT_INTERFACES_USER")"
	COUNTER=1
	until [ $COUNTER -gt "$interfacecount" ]; do
		Set_Interface_State "$COUNTER"
		interfaceline="$(sed "$COUNTER!d" "$SCRIPT_INTERFACES_USER" | awk '{$1=$1};1')"
		printf "%s)  %s\\n" "$COUNTER" "$interfaceline"
		COUNTER=$((COUNTER + 1))
	done
	
	printf "\\ne)  Go back\\n"
	
	while true; do
	printf "\\n\\e[1mPlease select a chart to toggle inclusion in %s (1-%s):\\e[0m  " "$SCRIPT_NAME" "$interfacecount"
	read -r interface
	
	if [ "$interface" = "e" ]; then
		goback="true"
		break
	elif ! Validate_Number "$interface"; then
		printf "\\n\\e[31mPlease enter a valid number (1-%s)\\e[0m\\n" "$interfacecount"
	else
		if [ "$interface" -lt 1 ] || [ "$interface" -gt "$interfacecount" ]; then
			printf "\\n\\e[31mPlease enter a number between 1 and %s\\e[0m\\n" "$interfacecount"
		else
			interfaceline="$(sed "$interface!d" "$SCRIPT_INTERFACES_USER" | awk '{$1=$1};1')"
			if echo "$interfaceline" | grep -q "#excluded" ; then
				IFACE_LOWER="$(Get_Interface_From_Name "$(echo "$interfaceline" | cut -f1 -d"#" | sed 's/ *$//')" | tr "A-Z" "a-z")"
#				if [ ! -f "/sys/class/net/$IFACE_LOWER/operstate" ] || [ "$(cat "/sys/class/net/$IFACE_LOWER/operstate")" = "down" ]; then
#					sed -i "$interface"'s/ #excluded#/ #excluded - interface not up#/' "$SCRIPT_INTERFACES_USER"
#				else
					sed -i "$interface"'s/ #excluded - interface not up#//' "$SCRIPT_INTERFACES_USER"
					sed -i "$interface"'s/ #excluded#//' "$SCRIPT_INTERFACES_USER"
#				fi
			else
				IFACE_LOWER="$(Get_Interface_From_Name "$(echo "$interfaceline" | cut -f1 -d"#" | sed 's/ *$//')" | tr "A-Z" "a-z")"
#				if [ ! -f "/sys/class/net/$IFACE_LOWER/operstate" ] || [ "$(cat "/sys/class/net/$IFACE_LOWER/operstate")" = "down" ]; then
#					sed -i "$interface"'s/$/ #excluded - interface not up#/' "$SCRIPT_INTERFACES_USER"
#				else
					sed -i "$interface"'s/$/ #excluded#/' "$SCRIPT_INTERFACES_USER"
#				fi
			fi
			
			sed -i 's/ *$//' "$SCRIPT_INTERFACES_USER"
			printf "\\n"
			break
		fi
	fi
	done
	
	if [ "$goback" != "true" ]; then
		Generate_Interface_List
	fi
}

Download_File(){
	/usr/sbin/curl -fsL --retry 3 "$1" -o "$2"
}

Get_WebUI_Page(){
	MyPage="none"
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		page="/www/user/user$i.asp"
		if [ -f "$page" ] && [ "$(md5sum < "$1")" = "$(md5sum < "$page")" ]; then
			MyPage="user$i.asp"
			return
		elif [ "$MyPage" = "none" ] && [ ! -f "$page" ]; then
			MyPage="user$i.asp"
		fi
	done
}

### function based on @dave14305's FlexQoS webconfigpage function ###
Get_WebUI_URL(){
	urlpage=""
	urlproto=""
	urldomain=""
	urlport=""
	
	urlpage="$(sed -nE "/$SCRIPT_NAME/ s/.*url\: \"(user[0-9]+\.asp)\".*/\1/p" /tmp/menuTree.js)"
	if [ "$(nvram get http_enable)" -eq 1 ]; then
		urlproto="https"
	else
		urlproto="http"
	fi
	if [ -n "$(nvram get lan_domain)" ]; then
		urldomain="$(nvram get lan_hostname).$(nvram get lan_domain)"
	else
		urldomain="$(nvram get lan_ipaddr)"
	fi
	if [ "$(nvram get ${urlproto}_lanport)" -eq 80 ] || [ "$(nvram get ${urlproto}_lanport)" -eq 443 ]; then
		urlport=""
	else
		urlport=":$(nvram get ${urlproto}_lanport)"
	fi
	
	if echo "$urlpage" | grep -qE "user[0-9]+\.asp"; then
		echo "${urlproto}://${urldomain}${urlport}/${urlpage}" | tr "A-Z" "a-z"
	else
		echo "WebUI page not found"
	fi
}
### ###

### locking mechanism code credit to Martineau (@MartineauUK) ###
Mount_WebUI(){
	Print_Output true "Mounting WebUI tab for $SCRIPT_NAME" "$PASS"
	LOCKFILE=/tmp/addonwebui.lock
	FD=386
	eval exec "$FD>$LOCKFILE"
	flock -x "$FD"
	Get_WebUI_Page "$SCRIPT_DIR/spdstats_www.asp"
	if [ "$MyPage" = "none" ]; then
		Print_Output true "Unable to mount $SCRIPT_NAME WebUI page, exiting" "$CRIT"
		flock -u "$FD"
		return 1
	fi
	cp -f "$SCRIPT_DIR/spdstats_www.asp" "$SCRIPT_WEBPAGE_DIR/$MyPage"
	echo "$SCRIPT_NAME" > "$SCRIPT_WEBPAGE_DIR/$(echo $MyPage | cut -f1 -d'.').title"
	
	if [ "$(uname -o)" = "ASUSWRT-Merlin" ]; then
		if [ ! -f /tmp/index_style.css ]; then
			cp -f /www/index_style.css /tmp/
		fi
		
		if ! grep -q '.menu_Addons' /tmp/index_style.css ; then
			echo ".menu_Addons { background: url(ext/shared-jy/addons.png); }" >> /tmp/index_style.css
		fi
		
		umount /www/index_style.css 2>/dev/null
		mount -o bind /tmp/index_style.css /www/index_style.css
		
		if [ ! -f /tmp/menuTree.js ]; then
			cp -f /www/require/modules/menuTree.js /tmp/
		fi
		
		sed -i "\\~$MyPage~d" /tmp/menuTree.js
		
		if ! grep -q 'menuName: "Addons"' /tmp/menuTree.js ; then
			lineinsbefore="$(( $(grep -n "exclude:" /tmp/menuTree.js | cut -f1 -d':') - 1))"
			sed -i "$lineinsbefore"'i,\n{\nmenuName: "Addons",\nindex: "menu_Addons",\ntab: [\n{url: "ext/shared-jy/redirect.htm", tabName: "Help & Support"},\n{url: "NULL", tabName: "__INHERIT__"}\n]\n}' /tmp/menuTree.js
		fi
		
		if grep -q "javascript:window.open('/ext/shared-jy/redirect.htm'" /tmp/menuTree.js ; then
			sed -i "s~javascript:window.open('/ext/shared-jy/redirect.htm','_blank')~javascript:var helpwindow=window.open('/ext/shared-jy/redirect.htm','_blank')~" /tmp/menuTree.js
		fi
		if ! grep -q "javascript:var helpwindow=window.open('/ext/shared-jy/redirect.htm'" /tmp/menuTree.js ; then
			sed -i "s~ext/shared-jy/redirect.htm~javascript:var helpwindow=window.open('/ext/shared-jy/redirect.htm','_blank')~" /tmp/menuTree.js
		fi
		sed -i "/url: \"javascript:var helpwindow=window.open('\/ext\/shared-jy\/redirect.htm'/i {url: \"$MyPage\", tabName: \"$SCRIPT_NAME\"}," /tmp/menuTree.js
		
		umount /www/require/modules/menuTree.js 2>/dev/null
		mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
	fi
	flock -u "$FD"
	Print_Output true "Mounted $SCRIPT_NAME WebUI page as $MyPage" "$PASS"
}

AutomaticMode(){
	case "$1" in
		enable)
			sed -i 's/^AUTOMATED.*$/AUTOMATED=true/' "$SCRIPT_CONF"
			Auto_Cron create 2>/dev/null
		;;
		disable)
			sed -i 's/^AUTOMATED.*$/AUTOMATED=false/' "$SCRIPT_CONF"
			Auto_Cron delete 2>/dev/null
		;;
		check)
			AUTOMATED=$(grep "AUTOMATED" "$SCRIPT_CONF" | cut -f2 -d"=")
			if [ "$AUTOMATED" = "true" ]; then return 0; else return 1; fi
		;;
	esac
}

TestSchedule(){
	case "$1" in
		update)
			sed -i 's/^SCHDAYS.*$/SCHDAYS='"$(echo "$2" | sed 's/0/Sun/;s/1/Mon/;s/2/Tues/;s/3/Wed/;s/4/Thurs/;s/5/Fri/;s/6/Sat/;')"'/' "$SCRIPT_CONF"
			sed -i 's~^SCHHOURS.*$~SCHHOURS='"$3"'~' "$SCRIPT_CONF"
			sed -i 's~^SCHMINS.*$~SCHMINS='"$4"'~' "$SCRIPT_CONF"
			Auto_Cron delete 2>/dev/null
			Auto_Cron create 2>/dev/null
		;;
		check)
			SCHDAYS=$(grep "SCHDAYS" "$SCRIPT_CONF" | cut -f2 -d"=")
			SCHHOURS=$(grep "SCHHOURS" "$SCRIPT_CONF" | cut -f2 -d"=")
			SCHMINS=$(grep "SCHMINS" "$SCRIPT_CONF" | cut -f2 -d"=")
			echo "$SCHDAYS|$SCHHOURS|$SCHMINS"
		;;
	esac
}

ScriptStorageLocation(){
	case "$1" in
		usb)
			sed -i 's/^STORAGELOCATION.*$/STORAGELOCATION=usb/' "$SCRIPT_CONF"
			mkdir -p "/opt/share/$SCRIPT_NAME_LOWER.d/"
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/csv" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/.interfaces" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/.interfaces_user" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/config" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/config.bak" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/spdjs.js" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/spdtitletext.js" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d/spdstats.db" "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/jffs/addons/$SCRIPT_NAME_LOWER.d"/.tableupgraded* "/opt/share/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			SCRIPT_CONF="/opt/share/$SCRIPT_NAME_LOWER.d/config"
			ScriptStorageLocation load
		;;
		jffs)
			sed -i 's/^STORAGELOCATION.*$/STORAGELOCATION=jffs/' "$SCRIPT_CONF"
			mkdir -p "/jffs/addons/$SCRIPT_NAME_LOWER.d/"
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/csv" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/.interfaces" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/.interfaces_user" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/config" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/config.bak" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/spdjs.js" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/spdtitletext.js" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/spdstats.db" "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			mv "/opt/share/$SCRIPT_NAME_LOWER.d/"/.tableupgraded* "/jffs/addons/$SCRIPT_NAME_LOWER.d/" 2>/dev/null
			SCRIPT_CONF="/jffs/addons/$SCRIPT_NAME_LOWER.d/config"
			ScriptStorageLocation load
		;;
		check)
			STORAGELOCATION=$(grep "STORAGELOCATION" "$SCRIPT_CONF" | cut -f2 -d"=")
			echo "$STORAGELOCATION"
		;;
		load)
			STORAGELOCATION=$(grep "STORAGELOCATION" "$SCRIPT_CONF" | cut -f2 -d"=")
			if [ "$STORAGELOCATION" = "usb" ]; then
				SCRIPT_STORAGE_DIR="/opt/share/$SCRIPT_NAME_LOWER.d"
			elif [ "$STORAGELOCATION" = "jffs" ]; then
				SCRIPT_STORAGE_DIR="/jffs/addons/$SCRIPT_NAME_LOWER.d"
			fi
			
			SCRIPT_INTERFACES="$SCRIPT_STORAGE_DIR/.interfaces"
			SCRIPT_INTERFACES_USER="$SCRIPT_STORAGE_DIR/.interfaces_user"
			CSV_OUTPUT_DIR="$SCRIPT_STORAGE_DIR/csv"
		;;
	esac
}

OutputDataMode(){
	case "$1" in
		raw)
			sed -i 's/^OUTPUTDATAMODE.*$/OUTPUTDATAMODE=raw/' "$SCRIPT_CONF"
			Generate_CSVs
		;;
		average)
			sed -i 's/^OUTPUTDATAMODE.*$/OUTPUTDATAMODE=average/' "$SCRIPT_CONF"
			Generate_CSVs
		;;
		check)
			OUTPUTDATAMODE=$(grep "OUTPUTDATAMODE" "$SCRIPT_CONF" | cut -f2 -d"=")
			echo "$OUTPUTDATAMODE"
		;;
	esac
}

OutputTimeMode(){
	case "$1" in
		unix)
			sed -i 's/^OUTPUTTIMEMODE.*$/OUTPUTTIMEMODE=unix/' "$SCRIPT_CONF"
			Generate_CSVs
		;;
		non-unix)
			sed -i 's/^OUTPUTTIMEMODE.*$/OUTPUTTIMEMODE=non-unix/' "$SCRIPT_CONF"
			Generate_CSVs
		;;
		check)
			OUTPUTTIMEMODE=$(grep "OUTPUTTIMEMODE" "$SCRIPT_CONF" | cut -f2 -d"=")
			echo "$OUTPUTTIMEMODE"
		;;
	esac
}

StoreResultURL(){
	case "$1" in
	enable)
		sed -i 's/^STORERESULTURL.*$/STORERESULTURL=true/' "$SCRIPT_CONF"
	;;
	disable)
		sed -i 's/^STORERESULTURL.*$/STORERESULTURL=false/' "$SCRIPT_CONF"
	;;
	check)
		STORERESULTURL=$(grep "STORERESULTURL" "$SCRIPT_CONF" | cut -f2 -d"=")
		echo "$STORERESULTURL"
	;;
	esac
}

ExcludeFromQoS(){
	case "$1" in
	enable)
		sed -i 's/^EXCLUDEFROMQOS.*$/EXCLUDEFROMQOS=true/' "$SCRIPT_CONF"
	;;
	disable)
		sed -i 's/^EXCLUDEFROMQOS.*$/EXCLUDEFROMQOS=false/' "$SCRIPT_CONF"
	;;
	check)
		EXCLUDEFROMQOS=$(grep "EXCLUDEFROMQOS" "$SCRIPT_CONF" | cut -f2 -d"=")
		echo "$EXCLUDEFROMQOS"
	;;
	esac
}

AutoBWEnable(){
	case "$1" in
	enable)
		sed -i 's/^AUTOBW_ENABLED.*$/AUTOBW_ENABLED=true/' "$SCRIPT_CONF"
	;;
	disable)
		sed -i 's/^AUTOBW_ENABLED.*$/AUTOBW_ENABLED=false/' "$SCRIPT_CONF"
	;;
	check)
		AUTOBW_ENABLED=$(grep "AUTOBW_ENABLED" "$SCRIPT_CONF" | cut -f2 -d"=")
		echo "$AUTOBW_ENABLED"
	;;
	esac
}

AutoBWConf(){
	case "$1" in
		update)
			sed -i 's/^AUTOBW_'"$2"'_'"$3"'.*$/AUTOBW_'"$2"'_'"$3"'='"$4"'/' "$SCRIPT_CONF"
		;;
		check)
			grep "AUTOBW_${2}_$3" "$SCRIPT_CONF" | cut -f2 -d"="
		;;
	esac
}

WritePlainData_ToJS(){
	inputfile="$1"
	outputfile="$2"
	shift;shift
	i=0
	for var in "$@"; do
		i=$((i+1))
		{
			echo "var $var;"
			echo "$var = [];"
			echo "${var}.unshift('$(awk -v i=$i '{printf t $i} {t=","}' "$inputfile" | sed "s~,~\\',\\'~g")');"
			echo
		} >> "$outputfile"
	done
}

WriteStats_ToJS(){
	echo "function $3(){" >> "$2"
	html='document.getElementById("'"$4"'").innerHTML="'
	while IFS='' read -r line || [ -n "$line" ]; do
		html="${html}${line}\\r\\n"
	done < "$1"
	html="$html"'"'
	printf "%s\\r\\n}\\r\\n" "$html" >> "$2"
}

#$1 fieldname $2 tablename $3 frequency (hours) $4 length (days) $5 outputfile $6 outputfrequency $7 interfacename $8 sqlfile $9 timestamp
WriteSql_ToFile(){
	timenow="$9"
	maxcount="$(echo "$3" "$4" | awk '{printf ((24*$2)/$1)}')"
	multiplier="$(echo "$3" | awk '{printf (60*60*$1)}')"
	{
		echo ".mode csv"
		echo ".headers off"
		echo ".output ${5}${6}_${7}.tmp"
	} >> "$8"
	
	echo "SELECT '$1' Metric, Min([Timestamp]) Time, IFNULL(Avg([$1]),'NaN') Value FROM $2 WHERE ([Timestamp] >= $timenow - ($multiplier*$maxcount)) GROUP BY ([Timestamp]/($multiplier));" >> "$8"
}

#$1 iface name
Generate_LastXResults(){
	{
		echo ".mode csv"
		echo ".output /tmp/spd-lastx.csv"
	} > /tmp/spd-lastx.sql
	echo "SELECT [Timestamp],[Download],[Upload],[Latency],[Jitter],[PktLoss],[DataDownload],[DataUpload],[ResultURL]FROM spdstats_$1 ORDER BY [Timestamp] DESC LIMIT 10;" >> /tmp/spd-lastx.sql
	"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-lastx.sql
	sed -i 's/,,/,null,/g;s/,/ /g;s/"//g;' /tmp/spd-lastx.csv
	WritePlainData_ToJS /tmp/spd-lastx.csv "$SCRIPT_STORAGE_DIR/spdjs.js" "DataTimestamp_$1" "DataDownload_$1" "DataUpload_$1" "DataLatency_$1" "DataJitter_$1" "DataPktLoss_$1" "DataDataDownload_$1" "DataDataUpload_$1" "DataResultURL_$1"
	rm -f /tmp/spd-lastx.sql
	rm -f /tmp/spd-lastx.csv
}

GenerateServerList(){
	if [ ! -f /opt/bin/jq ]; then
		opkg update
		opkg install jq
	fi
	promptforservername="$2"
	printf "Generating list of closest servers for %s...\\n\\n" "$1"
	serverlist="$("$OOKLA_DIR/speedtest" --servers --format="json" --accept-license --accept-gdpr)" 2>/dev/null
	if [ -z "$serverlist" ]; then
		Print_Output true "Error retrieving server list for for WAN" "$CRIT"
		serverno="exit"
		return 1
	fi
	servercount="$(echo "$serverlist" | jq '.servers | length')"
	COUNTER=1
	until [ $COUNTER -gt "$servercount" ]; do
		serverdetails="$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .id')|$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .name + " (" + .location + ", " + .country + ")"')"
		
		if [ "$COUNTER" -lt 10 ]; then
			printf "%s)  %s\\n" "$COUNTER" "$serverdetails"
		elif [ "$COUNTER" -ge 10 ]; then
			printf "%s) %s\\n" "$COUNTER" "$serverdetails"
		fi
		COUNTER=$((COUNTER + 1))
	done
	
	printf "\\ne)  Go back\\n"
	
	while true; do
		printf "\\n\\e[1mPlease select a server from the list above (1-%s):\\e[0m\\n" "$servercount"
		printf "\\n\\e[1mOr press c to enter a known server ID\\e[0m\\n"
		printf "\\e[1mEnter answer:\\e[0m  "
		read -r server
		
		if [ "$server" = "e" ]; then
			serverno="exit"
			break
		elif [ "$server" = "c" ]; then
				while true; do
					printf "\\n\\e[1mPlease enter server ID (WARNING: this is not validated) or e to go back\\e[0m  "
					read -r customserver
					if [ "$customserver" = "e" ]; then
						break
					elif ! Validate_Number "$customserver"; then
						printf "\\n\\e[31mPlease enter a valid number\\e[0m\\n"
					else
						serverno="$customserver"
						if [ "$promptforservername" != "no" ]; then
							while true; do
								printf "\\n\\e[1mWould you like to enter a name for this server? (default: Custom) (y/n)?\\e[0m  "
								read -r servername_select
								
								if [ "$servername_select" = "n" ] || [ "$servername_select" = "N" ]; then
									servername="Custom"
									break
								elif [ "$servername_select" = "y" ] || [ "$servername_select" = "Y" ]; then
									printf "\\n\\e[1mPlease enter the name for this server:\\e[0m  "
									read -r servername
									printf "\\n\\e[1m%s\\e[0m\\n" "$servername"
									printf "\\n\\e[1mIs that correct (y/n)?\\e[0m  "
									read -r servername_confirm
									if [ "$servername_confirm" = "y" ] || [ "$servername_confirm" = "Y" ]; then
										break
									else
										printf "\\n\\e[31mPlease enter y or n\\e[0m\\n"
									fi
								else
									printf "\\n\\e[31mPlease enter y or n\\e[0m\\n"
								fi
							done
						else
							servername="Custom"
						fi
						
						printf "\\n"
						return 0
					fi
				done
		elif ! Validate_Number "$server"; then
			printf "\\n\\e[31mPlease enter a valid number (1-%s)\\e[0m\\n" "$servercount"
		else
			if [ "$server" -lt 1 ] || [ "$server" -gt "$servercount" ]; then
				printf "\\n\\e[31mPlease enter a number between 1 and %s\\e[0m\\n" "$servercount"
			else
				serverno="$(echo "$serverlist" | jq -r --argjson index "$((server-1))" '.servers[$index] | .id')"
				servername="$(echo "$serverlist" | jq -r --argjson index "$((server-1))" '.servers[$index] | .name + " (" + .location + ", " + .country + ")"')"
				printf "\\n"
				break
			fi
		fi
	done
}

GenerateServerList_WebUI(){
	if [ ! -f /opt/bin/jq ]; then
		opkg update
		opkg install jq
	fi
	serverlistfile="$2"
	rm -f "/tmp/$serverlistfile.txt"
	rm -f "$SCRIPT_WEB_DIR/$serverlistfile.htm"
	
	spdifacename="$1"
	
	if [ "$spdifacename" = "ALL" ]; then
		while IFS='' read -r line || [ -n "$line" ]; do
			if [ "$(echo "$line" | grep -c "interface not up")" -eq 0 ]; then
				IFACELIST="$IFACELIST $(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
			fi
		done < "$SCRIPT_INTERFACES_USER"
		IFACELIST="$(echo "$IFACELIST" | cut -c2-)"
		
		for IFACE_NAME in $IFACELIST; do
			serverlist="$("$OOKLA_DIR/speedtest"  --servers --format="json" --accept-license --accept-gdpr)" 2>/dev/null
			servercount="$(echo "$serverlist" | jq '.servers | length')"
			COUNTER=1
			until [ $COUNTER -gt "$servercount" ]; do
				printf "%s|%s\\n" "$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .id')" "$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .name + " (" + .location + ", " + .country + ")"')"  >> "/tmp/$serverlistfile.tmp"
				COUNTER=$((COUNTER + 1))
			done
			#shellcheck disable=SC2039
			printf "-----\\n" >> "/tmp/$serverlistfile.tmp"
		done
	else
		serverlist="$("$OOKLA_DIR/speedtest"  --servers --format="json" --accept-license --accept-gdpr)" 2>/dev/null
		servercount="$(echo "$serverlist" | jq '.servers | length')"
		COUNTER=1
		until [ $COUNTER -gt "$servercount" ]; do
			printf "%s|%s\\n" "$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .id')" "$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .name + " (" + .location + ", " + .country + ")"')"  >> "/tmp/$serverlistfile.tmp"
			COUNTER=$((COUNTER + 1))
		done
	fi
	sleep 1
	mv "/tmp/$serverlistfile.tmp" "/tmp/$serverlistfile.txt"
	ln -s "/tmp/$serverlistfile.txt" "$SCRIPT_WEB_DIR/$serverlistfile.htm" 2>/dev/null
}

PreferredServer(){
	case "$1" in
		update)
			GenerateServerList "$2"
			if [ "$serverno" != "exit" ]; then
				sed -i 's/^PREFERREDSERVER_'"$2"'.*$/PREFERREDSERVER_'"$2"'='"$serverno|$servername"'/' "$SCRIPT_CONF"
			else
				return 1
			fi
		;;
		enable)
			sed -i 's/^USEPREFERRED_'"$2"'.*$/USEPREFERRED_'"$2"'=true/' "$SCRIPT_CONF"
		;;
		disable)
			sed -i 's/^USEPREFERRED_'"$2"'.*$/USEPREFERRED_'"$2"'=false/' "$SCRIPT_CONF"
		;;
		check)
			USEPREFERRED=$(grep "USEPREFERRED_$2" "$SCRIPT_CONF" | cut -f2 -d"=")
			if [ "$USEPREFERRED" = "true" ]; then return 0; else return 1; fi
		;;
		list)
			PREFERREDSERVER=$(grep "PREFERREDSERVER_$2" "$SCRIPT_CONF" | cut -f2 -d"=")
			echo "$PREFERREDSERVER"
		;;
	esac
}

Run_Speedtest(){
	if [ ! -f /opt/bin/xargs ]; then
		Print_Output true "Installing findutils from Entware"
		opkg update
		opkg install findutils
	fi
	#shellcheck disable=SC2009
	if [ -n "$PPID" ]; then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME_LOWER" | grep generate | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME_LOWER" | grep generate | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	Create_Dirs
	Conf_Exists
	Auto_Startup create 2>/dev/null
	if AutomaticMode check; then Auto_Cron create 2>/dev/null; else Auto_Cron delete 2>/dev/null; fi
	Auto_ServiceEvent create 2>/dev/null
	Shortcut_Script create
	ScriptStorageLocation load
	Create_Symlinks
	License_Acceptance load
	
	mode="$1"
	specificiface="$2"
	speedtestserverno=""
	speedtestservername=""
	
	echo 'var spdteststatus = "InProgress";' > /tmp/detect_spdtest.js
	
	tmpfile=/tmp/spd-stats.txt
	resultfile=/tmp/spd-result.txt
	printf "" > "$resultfile"
	
	if [ -n "$(pidof speedtest)" ]; then
		killall speedtest
	fi
	
	if Check_Swap ; then
		if [ "$(echo "$mode" | grep -c "webui")" -eq 0 ]; then
			if ! License_Acceptance check ; then
				if [ "$mode" != "schedule" ]; then
					if ! License_Acceptance accept; then
						echo 'var spdteststatus = "NoLicense";' > /tmp/detect_spdtest.js
						Clear_Lock
						return 1
					fi
				else
					echo 'var spdteststatus = "NoLicense";' > /tmp/detect_spdtest.js
					Print_Output true "Licenses not accepted, please run spdmerlin at the command line / SSH to accept them" "$ERR"
					return 1
				fi
			fi
		fi
		
		IFACELIST=""
		if [ -z "$specificiface" ]; then
			while IFS='' read -r line || [ -n "$line" ]; do
				if [ "$(echo "$line" | grep -c "#")" -eq 0 ]; then
					IFACELIST="$IFACELIST $(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
				fi
			done < "$SCRIPT_INTERFACES_USER"
			IFACELIST="$(echo "$IFACELIST" | cut -c2-)"
		elif [ "$specificiface" = "All" ]; then
			while IFS='' read -r line || [ -n "$line" ]; do
				if [ "$(echo "$line" | grep -c "interface not up")" -eq 0 ]; then
					IFACELIST="$IFACELIST $(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
				fi
			done < "$SCRIPT_INTERFACES_USER"
			IFACELIST="$(echo "$IFACELIST" | cut -c2-)"
		else
			IFACELIST="$specificiface"
		fi
		
		if [ "$IFACELIST" != "" ]; then
			if [ "$(ExcludeFromQoS check)" = "true" ]; then
				stoppedqos="false"
				if [ "$(nvram get qos_enable)" -eq 1 ] && [ "$(nvram get qos_type)" -eq 1 ]; then
					for ACTION in -D -A ; do
						for proto in tcp udp; do
							iptables "$ACTION" OUTPUT -p "$proto" -o "$(Get_Interface_From_Name WAN)" -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables "$ACTION" OUTPUT -p "$proto" -o tun1+ -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle "$ACTION" OUTPUT -p "$proto" -o "$(Get_Interface_From_Name WAN)" -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle "$ACTION" POSTROUTING -p "$proto" -o "$(Get_Interface_From_Name WAN)" -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle "$ACTION" OUTPUT -p "$proto" -o tun1+ -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle "$ACTION" POSTROUTING -p "$proto" -o tun1+ -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
						done
						stoppedqos="true"
					done
				elif [ "$(nvram get qos_enable)" -eq 1 ] && [ "$(nvram get qos_type)" -ne 1 ] && [ -f /tmp/qos ]; then
					/tmp/qos stop >/dev/null 2>&1
					stoppedqos="true"
				elif [ "$(nvram get qos_enable)" -eq 0 ] && [ -f /jffs/addons/cake-qos/cake-qos ]; then
					/jffs/addons/cake-qos/cake-qos stop >/dev/null 2>&1
					stoppedqos="true"
				fi
			fi
			
			applyautobw="false"
			
			if [ "$mode" = "schedule" ] && [ "$(AutoBWEnable check)" = "true" ]; then
				applyautobw="true"
			fi
			
			for IFACE_NAME in $IFACELIST; do
				IFACE="$(Get_Interface_From_Name "$IFACE_NAME")"
				IFACE_LOWER="$(echo "$IFACE" | tr "A-Z" "a-z")"
#				if [ ! -f "/sys/class/net/$IFACE_LOWER/operstate" ] || [ "$(cat "/sys/class/net/$IFACE_LOWER/operstate")" = "down" ]; then
#					Print_Output true "$IFACE not up, please check. Skipping speedtest for $IFACE_NAME" "$WARN"
#					continue
#				else
					if [ "$mode" = "webui_user" ]; then
						mode="user"
					elif [ "$mode" = "webui_auto" ]; then
						mode="auto"
					elif [ "$mode" = "webui_onetime" ]; then
						mode="user"
					fi
					
					if [ "$mode" = "schedule" ]; then
						if PreferredServer check "$IFACE_NAME"; then
							speedtestserverno="$(PreferredServer list "$IFACE_NAME" | cut -f1 -d"|")"
							speedtestservername="$(PreferredServer list "$IFACE_NAME" | cut -f2 -d"|")"
						else
							mode="auto"
						fi
					elif [ "$mode" = "onetime" ]; then
						GenerateServerList "$IFACE_NAME" no
						if [ "$serverno" != "exit" ]; then
							speedtestserverno="$serverno"
							speedtestservername="$servername"
						else
							Clear_Lock
							return 1
						fi
					elif [ "$mode" = "user" ]; then
						speedtestserverno="$(PreferredServer list "$IFACE_NAME" | cut -f1 -d"|")"
						speedtestservername="$(PreferredServer list "$IFACE_NAME" | cut -f2 -d"|")"
					fi
					
					echo 'var spdteststatus = "InProgress_'"$IFACE_NAME"'";' > /tmp/detect_spdtest.js
					printf "" > "$tmpfile"
					
					if [ "$mode" = "auto" ]; then
						Print_Output true "Starting speedtest using auto-selected server for $IFACE_NAME interface" "$PASS"
						"$OOKLA_DIR/speedtest"  --format="human-readable" --unit="Mbps" --progress="yes" --accept-license --accept-gdpr | tee "$tmpfile" &
						speedtestcount=0
						while [ -n "$(pidof speedtest)" ] && [ "$speedtestcount" -lt 120 ]; do
							speedtestcount="$((speedtestcount + 1))"
							sleep 1
						done
						if [ "$speedtestcount" -ge 120 ]; then
							Print_Output true "Speedtest for $IFACE_NAME hung (> 2 mins), killing process" "$CRIT"
							killall speedtest
							continue
						fi
					else
						if [ "$speedtestserverno" -ne 0 ]; then
							Print_Output true "Starting speedtest using $speedtestservername for $IFACE_NAME interface" "$PASS"
							"$OOKLA_DIR/speedtest"  --server-id="$speedtestserverno" --format="human-readable" --unit="Mbps" --progress="yes" --accept-license --accept-gdpr | tee "$tmpfile" &
							speedtestcount=0
							while [ -n "$(pidof speedtest)" ] && [ "$speedtestcount" -lt 120 ]; do
								speedtestcount="$((speedtestcount + 1))"
								sleep 1
							done
							if [ "$speedtestcount" -ge 120 ]; then
								Print_Output true "Speedtest for $IFACE_NAME hung (> 2 mins), killing process" "$CRIT"
								killall speedtest
								continue
							fi
						else
							Print_Output true "Starting speedtest using using auto-selected server for $IFACE_NAME interface" "$PASS"
							"$OOKLA_DIR/speedtest"  --format="human-readable" --unit="Mbps" --progress="yes" --accept-license --accept-gdpr | tee "$tmpfile" &
							speedtestcount=0
							while [ -n "$(pidof speedtest)" ] && [ "$speedtestcount" -lt 120 ]; do
								speedtestcount="$((speedtestcount + 1))"
								sleep 1
							done
							if [ "$speedtestcount" -ge 120 ]; then
								Print_Output true "Speedtest for $IFACE_NAME hung (> 2 mins), killing process" "$CRIT"
								killall speedtest
								continue
							fi
						fi
					fi
					
					if [ ! -f "$tmpfile" ] || [ -z "$(cat "$tmpfile")" ] || [ "$(grep -c FAILED $tmpfile)" -gt 0 ]; then
						Print_Output true "Error running speedtest for $IFACE_NAME" "$CRIT"
						continue
					fi
					
					ScriptStorageLocation load
					
					TZ=$(cat /etc/TZ)
					export TZ
					
					timenow=$(date +"%s")
					timenowfriendly=$(date +"%c")
					
					download="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $2}')"
					upload="$(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $2}')"
					latency="$(grep Latency "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $2}')"
					jitter="$(grep Latency "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $4}' | tr -d '(')"
					pktloss="$(grep 'Packet Loss' "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $3}' | tr -d '%')"
					resulturl="$(grep 'Result URL' "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $3}')"
					datadownload="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $6}')"
					dataupload="$(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print $6}')"
					
					datadownloadunit="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print substr($7,1,length($7)-1)}')"
					datauploadunit="$(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk 'BEGIN{FS=" "}{print substr($7,1,length($7)-1)}')"
					
					! Validate_Bandwidth "$download" && download=0;
					! Validate_Bandwidth "$upload" && upload=0;
					! Validate_Bandwidth "$latency" && latency="null";
					! Validate_Bandwidth "$jitter" && jitter="null";
					! Validate_Bandwidth "$pktloss" && pktloss="null";
					! Validate_Bandwidth "$datadownload" && datadownload=0;
					! Validate_Bandwidth "$dataupload" && dataupload=0;
					
					if [ "$datadownloadunit" = "GB" ]; then
						datadownload="$(echo "$datadownload" | awk '{printf ($1*1024)}')"
					fi
					
					if [ "$datauploadunit" = "GB" ]; then
						dataupload="$(echo "$dataupload" | awk '{printf ($1*1024)}')"
					fi
					
					echo "CREATE TABLE IF NOT EXISTS [spdstats_$IFACE_NAME] ([StatID] INTEGER PRIMARY KEY NOT NULL, [Timestamp] NUMERIC NOT NULL, [Download] REAL NOT NULL,[Upload] REAL NOT NULL, [Latency] REAL, [Jitter] REAL, [PktLoss] REAL, [ResultURL] TEXT, [DataDownload] REAL NOT NULL,[DataUpload] REAL NOT NULL);" > /tmp/spd-stats.sql
					"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					
					STORERESULTURL="$(StoreResultURL check)"
					
					if [ "$STORERESULTURL" = "true" ]; then
						echo "INSERT INTO spdstats_$IFACE_NAME ([Timestamp],[Download],[Upload],[Latency],[Jitter],[PktLoss],[ResultURL],[DataDownload],[DataUpload]) values($timenow,$download,$upload,$latency,$jitter,$pktloss,'$resulturl',$datadownload,$dataupload);" > /tmp/spd-stats.sql
					elif [ "$STORERESULTURL" = "false" ]; then
						echo "INSERT INTO spdstats_$IFACE_NAME ([Timestamp],[Download],[Upload],[Latency],[Jitter],[PktLoss],[ResultURL],[DataDownload],[DataUpload]) values($timenow,$download,$upload,$latency,$jitter,$pktloss,'',$datadownload,$dataupload);" > /tmp/spd-stats.sql
					fi
					"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					
					echo "DELETE FROM [spdstats_$IFACE_NAME] WHERE [Timestamp] < ($timenow - (86400*30));" > /tmp/spd-stats.sql
					"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					rm -f /tmp/spd-stats.sql
					
					spdtestresult="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};'| awk '{$1=$1};1') - $(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};'| awk '{$1=$1};1')"
					spdtestresult2="$(grep Latency "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{$1=$1};1') - $(grep 'Packet Loss' "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{$1=$1};1')"
					
					printf "\\n"
					Print_Output true "Speedtest results - $spdtestresult" "$PASS"
					Print_Output true "Connection quality - $spdtestresult2" "$PASS"
					
					{
						printf "Speedtest result for %s\\n" "$IFACE_NAME"
						printf "\\nBandwidth - %s\\n" "$spdtestresult"
						printf "Quality - %s\\n\\n" "$spdtestresult2"
						grep "Result URL" "$tmpfile" | awk '{$1=$1};1'
						printf "\\n\\n\\n"
					} >> "$resultfile"
					#extStats
					extStats="/jffs/addons/extstats.d/mod_spdstats.sh"
					if [ -f "$extStats" ]; then
						sh "$extStats" ext "$download" "$upload"
					fi
#				fi
# When instructed to run for several probes, it will only test 1 server if the first test looks OK 
# (i.e. reaches the upper limit for download for AutoBW).
# The rational is that if the first server indicates bad performance, it is interpreted as an interesting context to test them all.
# Note that the servers are  defined in a specific order. First servers that are far from my ISP (more likely to produce bad results).
# Then servers which are close to my ISP. 
#				if [ "$mode" = "schedule" ]; then
					if [ "$IFACE_NAME"=WAN ]
					then
						if [ "$(echo $download | awk 'BEGIN{FS="."}{print $1}')" -gt "$(($(AutoBWConf check ULIMIT DOWN)*1))" ]
						then 
							break
						fi
					fi
#				fi
			done
			
			if [ "$(ExcludeFromQoS check)" = "true" ]; then
				if [ "$stoppedqos" = "true" ]; then
					if [ "$(nvram get qos_enable)" -eq 1 ] && [ "$(nvram get qos_type)" -eq 1 ]; then
						for proto in tcp udp; do
							iptables -D OUTPUT -p "$proto" -o "$(Get_Interface_From_Name WAN)" -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -D OUTPUT -p "$proto" -o tun1+ -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle -D OUTPUT -p "$proto" -o "$(Get_Interface_From_Name WAN)" -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle -D POSTROUTING -p "$proto" -o "$(Get_Interface_From_Name WAN)" -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle -D OUTPUT -p "$proto" -o tun1+ -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
							iptables -t mangle -D POSTROUTING -p "$proto" -o tun1+ -j MARK --set-xmark 0x80000000/0xC0000000 2>/dev/null
						done
					elif [ "$(nvram get qos_enable)" -eq 1 ] && [ "$(nvram get qos_type)" -ne 1 ] && [ -f /tmp/qos ]; then
						/tmp/qos start >/dev/null 2>&1
					elif [ "$(nvram get qos_enable)" -eq 0 ] && [ -f /jffs/addons/cake-qos/cake-qos ]; then
						/jffs/addons/cake-qos/cake-qos start >/dev/null 2>&1
					fi
				fi
			fi
			
			Generate_CSVs
			
			echo "Stats last updated: $timenowfriendly" > /tmp/spdstatstitle.txt
			rm -f "$SCRIPT_STORAGE_DIR/spdtitletext.js"
			WriteStats_ToJS /tmp/spdstatstitle.txt "$SCRIPT_STORAGE_DIR/spdtitletext.js" SetSPDStatsTitle statstitle
			
			echo 'var spdteststatus = "Done";' > /tmp/detect_spdtest.js
			
			rm -f "$tmpfile"
			rm -f /tmp/spdstatstitle.txt
			
			if [ "$applyautobw" = "true" ]; then
				Menu_AutoBW_Update
			fi
			
			Clear_Lock
		else
			echo 'var spdteststatus = "Error";' > /tmp/detect_spdtest.js
			Print_Output true "No interfaces enabled, exiting" "$CRIT"
			Clear_Lock
			return 1
		fi
		Clear_Lock
	else
		echo 'var spdteststatus = "NoSwap";' > /tmp/detect_spdtest.js
		Print_Output true "Swap file not active, exiting" "$CRIT"
		Clear_Lock
		return 1
	fi
}

Run_Speedtest_WebUI(){
	spdteststring="$(echo "$1" | sed "s/${SCRIPT_NAME_LOWER}spdtest_//;s/%/ /g")";
	spdtestmode="webui_$(echo "$spdteststring" | cut -f1 -d'_')";
	spdifacename="$(echo "$spdteststring" | cut -f2 -d'_')";
	
	cp -a "$SCRIPT_CONF" "$SCRIPT_CONF.bak"
	
	if [ "$spdtestmode" = "webui_onetime" ]; then
		spdtestserverlist="$(echo "$spdteststring" | cut -f3 -d'_')";
		if [ "$spdifacename" = "All" ]; then
			while IFS='' read -r line || [ -n "$line" ]; do
				if [ "$(echo "$line" | grep -c "interface not up")" -eq 0 ]; then
					IFACELIST="$IFACELIST $(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
				fi
			done < "$SCRIPT_INTERFACES_USER"
			IFACELIST="$(echo "$IFACELIST" | cut -c2-)"
			
			COUNT=1
			for IFACE_NAME in $IFACELIST; do
				spdtestserver="$(grep -m1 "$(echo "$spdtestserverlist" | cut -f"$COUNT" -d'+')" /tmp/spdmerlin_manual_serverlist.txt)"
				sed -i 's/^PREFERREDSERVER_'"$IFACE_NAME"'.*$/PREFERREDSERVER_'"$IFACE_NAME"'='"$spdtestserver"'/' "$SCRIPT_CONF"
				COUNT=$((COUNT+1))
			done
		else
			spdtestserver="$(grep -m1 "$spdtestserverlist" /tmp/spdmerlin_manual_serverlist.txt)"
			sed -i 's/^PREFERREDSERVER_'"$spdifacename"'.*$/PREFERREDSERVER_'"$spdifacename"'='"$spdtestserver"'/' "$SCRIPT_CONF"
		fi
	fi
	
	Run_Speedtest "$spdtestmode" "$spdifacename"
	cp -a "$SCRIPT_CONF.bak" "$SCRIPT_CONF"
}

Process_Upgrade(){
	# shellcheck disable=SC2028
	if [ ! -f "$SCRIPT_STORAGE_DIR/spdtitletext.js" ]; then
		{
			echo 'function SetSPDStatsTitle(){';
			echo 'document.getElementById("statstitle").innerHTML="Stats last updated: Not yet updated\r\n";';
			echo "}";
		} > "$SCRIPT_STORAGE_DIR/spdtitletext.js"
	fi
	
	if [ "$(AutoBWEnable check)" = "true" ]; then
		if [ "$(ExcludeFromQoS check)" = "false" ]; then
			Print_Output false "Enabling Exclude from QoS (required for AutoBW)"
			ExcludeFromQoS enable
			PressEnter
		fi
	fi
}

Generate_CSVs(){
	OUTPUTDATAMODE="$(OutputDataMode check)"
	OUTPUTTIMEMODE="$(OutputTimeMode check)"
	STORERESULTURL="$(StoreResultURL check)"
	IFACELIST=""
	
	while IFS='' read -r line || [ -n "$line" ]; do
		IFACELIST="$IFACELIST $(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
	done < "$SCRIPT_INTERFACES_USER"
	IFACELIST="$(echo "$IFACELIST" | cut -c2-)"
	
	if [ "$IFACELIST" != "" ]; then
		rm -f "$SCRIPT_STORAGE_DIR/spdjs.js"
		
		for IFACE_NAME in $IFACELIST; do
			IFACE="$(Get_Interface_From_Name "$IFACE_NAME")"
				
			TZ=$(cat /etc/TZ)
			export TZ
			
			timenow=$(date +"%s")
			timenowfriendly=$(date +"%c")
			
			metriclist="Download Upload Latency Jitter PktLoss DataDownload DataUpload"
			
			for metric in $metriclist; do
				{
					echo ".mode csv"
					echo ".headers off"
					echo ".output $CSV_OUTPUT_DIR/${metric}daily_$IFACE_NAME.tmp"
					echo "SELECT '$metric' Metric,[Timestamp] Time,[$metric] Value FROM spdstats_$IFACE_NAME WHERE [Timestamp] >= ($timenow - 86400);"
				} > /tmp/spd-stats.sql
				"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
				rm -f /tmp/spd-stats.sql
				
				if [ "$OUTPUTDATAMODE" = "raw" ]; then
					{
						echo ".mode csv"
						echo ".headers off"
						echo ".output $CSV_OUTPUT_DIR/${metric}weekly_$IFACE_NAME.tmp"
						echo "SELECT '$metric' Metric,[Timestamp] Time,[$metric] Value FROM spdstats_$IFACE_NAME WHERE [Timestamp] >= ($timenow - 86400*7);"
					} > /tmp/spd-stats.sql
					"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					rm -f /tmp/spd-stats.sql
					
					{
						echo ".mode csv"
						echo ".headers off"
						echo ".output $CSV_OUTPUT_DIR/${metric}monthly_$IFACE_NAME.tmp"
						echo "SELECT '$metric' Metric,[Timestamp] Time,[$metric] Value FROM spdstats_$IFACE_NAME WHERE [Timestamp] >= ($timenow - 86400*30);"
					} > /tmp/spd-stats.sql
					"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					rm -f /tmp/spd-stats.sql
				elif [ "$OUTPUTDATAMODE" = "average" ]; then
					WriteSql_ToFile "$metric" "spdstats_$IFACE_NAME" 1 7 "$CSV_OUTPUT_DIR/$metric" weekly "$IFACE_NAME" /tmp/spd-stats.sql "$timenow"
					"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					rm -f /tmp/spd-stats.sql
					
					WriteSql_ToFile "$metric" "spdstats_$IFACE_NAME" 3 30 "$CSV_OUTPUT_DIR/$metric" monthly "$IFACE_NAME" /tmp/spd-stats.sql "$timenow"
					"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					rm -f /tmp/spd-stats.sql
				fi
			done
			
			cat "$CSV_OUTPUT_DIR/Downloaddaily_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/Uploaddaily_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/Combineddaily_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/Downloadweekly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/Uploadweekly_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/Combinedweekly_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/Downloadmonthly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/Uploadmonthly_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/Combinedmonthly_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/Latencydaily_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/Jitterdaily_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/PktLossdaily_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/Qualitydaily_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/Latencyweekly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/Jitterweekly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/PktLossweekly_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/Qualityweekly_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/Latencymonthly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/Jittermonthly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/PktLossmonthly_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/Qualitymonthly_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/DataDownloaddaily_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/DataUploaddaily_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/DataUsagedaily_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/DataDownloadweekly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/DataUploadweekly_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/DataUsageweekly_$IFACE_NAME.htm" 2> /dev/null
			cat "$CSV_OUTPUT_DIR/DataDownloadmonthly_$IFACE_NAME.tmp" "$CSV_OUTPUT_DIR/DataUploadmonthly_$IFACE_NAME.tmp" > "$CSV_OUTPUT_DIR/DataUsagemonthly_$IFACE_NAME.htm" 2> /dev/null
			
			csvlist="Combined Quality DataUsage"
			for csvfile in $csvlist; do
				sed -i '1i Metric,Time,Value' "$CSV_OUTPUT_DIR/${csvfile}daily_$IFACE_NAME.htm"
				sed -i '1i Metric,Time,Value' "$CSV_OUTPUT_DIR/${csvfile}weekly_$IFACE_NAME.htm"
				sed -i '1i Metric,Time,Value' "$CSV_OUTPUT_DIR/${csvfile}monthly_$IFACE_NAME.htm"
			done
			
			INCLUDEURL=""
			if [ "$STORERESULTURL" = "true" ]; then
				INCLUDEURL=",[ResultURL]"
			fi
			
			{
				echo ".mode csv"
				echo ".headers on"
				echo ".output $CSV_OUTPUT_DIR/CompleteResults_$IFACE_NAME.htm"
			} > /tmp/spd-complete.sql
			echo "SELECT [Timestamp],[Download],[Upload],[Latency],[Jitter],[PktLoss]$INCLUDEURL,[DataDownload],[DataUpload] FROM spdstats_$IFACE_NAME WHERE [Timestamp] >= ($timenow - 86400*30) ORDER BY [Timestamp] DESC;" >> /tmp/spd-complete.sql
			"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-complete.sql
			rm -f /tmp/spd-complete.sql
			
			rm -f "$CSV_OUTPUT_DIR/Download"*
			rm -f "$CSV_OUTPUT_DIR/Upload"*
			rm -f "$CSV_OUTPUT_DIR/Latency"*
			rm -f "$CSV_OUTPUT_DIR/Jitter"*
			rm -f "$CSV_OUTPUT_DIR/PktLoss"*
			rm -f "$CSV_OUTPUT_DIR/DataDownload"*
			rm -f "$CSV_OUTPUT_DIR/DataUpload"*
			
			Generate_LastXResults "$IFACE_NAME"
			rm -f /tmp/spd-stats.sql
		done
		
		dos2unix "$CSV_OUTPUT_DIR/"*.htm
		
		tmpoutputdir="/tmp/${SCRIPT_NAME_LOWER}results"
		mkdir -p "$tmpoutputdir"
		mv "$CSV_OUTPUT_DIR/CompleteResults"*.htm "$tmpoutputdir/."
		
		if [ "$OUTPUTTIMEMODE" = "unix" ]; then
			find "$tmpoutputdir/" -name '*.htm' -exec sh -c 'i="$1"; mv -- "$i" "${i%.htm}.csv"' _ {} \;
		elif [ "$OUTPUTTIMEMODE" = "non-unix" ]; then
			for i in "$tmpoutputdir/"*".htm"; do
				awk -F"," 'NR==1 {OFS=","; print} NR>1 {OFS=","; $1=strftime("%Y-%m-%d %H:%M:%S", $1); print }' "$i" > "$i.out"
			done
			
			find "$tmpoutputdir/" -name '*.htm.out' -exec sh -c 'i="$1"; mv -- "$i" "${i%.htm.out}.csv"' _ {} \;
			rm -f "$tmpoutputdir/"*.htm
		fi
		
		if [ ! -f /opt/bin/7za ]; then
			opkg update
			opkg install p7zip
		fi
		/opt/bin/7za a -y -bsp0 -bso0 -tzip "/tmp/${SCRIPT_NAME_LOWER}data.zip" "$tmpoutputdir/*"
		mv "/tmp/${SCRIPT_NAME_LOWER}data.zip" "$CSV_OUTPUT_DIR"
		rm -rf "$tmpoutputdir"
	fi
}

# shellcheck disable=SC2012
Reset_DB(){
	SIZEAVAIL="$(df -P -k "$SCRIPT_STORAGE_DIR" | awk '{print $4}' | tail -n 1)"
	SIZEDB="$(ls -l "$SCRIPT_STORAGE_DIR/spdstats.db" | awk '{print $5}')"
	if [ "$SIZEDB" -gt "$SIZEAVAIL" ]; then
		Print_Output true "Database size exceeds available space. $(ls -lh "$SCRIPT_STORAGE_DIR/spdstats.db" | awk '{print $5}')B is required to create backup." "$ERR"
		return 1
	else
		Print_Output true "Sufficient free space to back up database, proceeding..." "$PASS"
		if ! cp -a "$SCRIPT_STORAGE_DIR/spdstats.db" "$SCRIPT_STORAGE_DIR/spdstats.db.bak"; then
			Print_Output true "Database backup failed, please check storage device" "$WARN"
		fi
		
		tablelist="WAN VPNC1 VPNC2 VPNC3 VPNC4 VPNC5"
		for dbtable in $tablelist; do
			echo "DELETE FROM [spdstats_$dbtable];" > /tmp/spd-stats.sql
			"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
			rm -f /tmp/spd-stats.sql
		done
		
		Print_Output true "Database reset complete" "$WARN"
	fi
}


Shortcut_Script(){
	case $1 in
		create)
			if [ -d "/opt/bin" ] && [ ! -f "/opt/bin/$SCRIPT_NAME_LOWER" ] && [ -f "/jffs/scripts/$SCRIPT_NAME_LOWER" ]; then
				ln -s "/jffs/scripts/$SCRIPT_NAME_LOWER" /opt/bin
				chmod 0755 "/opt/bin/$SCRIPT_NAME_LOWER"
			fi
		;;
		delete)
			if [ -f "/opt/bin/$SCRIPT_NAME_LOWER" ]; then
				rm -f "/opt/bin/$SCRIPT_NAME_LOWER"
			fi
		;;
	esac
}

PressEnter(){
	while true; do
		printf "Press enter to continue..."
		read -r key
		case "$key" in
			*)
				break
			;;
		esac
	done
	return 0
}

ScriptHeader(){
	clear
	
	printf "\\n"
	printf "\\e[1m####################################################################\\e[0m\\n"
	printf "\\e[1m##                       _  __  __              _  _              ##\\e[0m\\n"
	printf "\\e[1m##                      | ||  \/  |            | |(_)             ##\\e[0m\\n"
	printf "\\e[1m##       ___  _ __    __| || \  / |  ___  _ __ | | _  _ __        ##\\e[0m\\n"
	printf "\\e[1m##      / __|| '_ \  / _  || |\/| | / _ \| '__|| || || '_ \       ##\\e[0m\\n"
	printf "\\e[1m##      \__ \| |_) || (_| || |  | ||  __/| |   | || || | | |      ##\\e[0m\\n"
	printf "\\e[1m##      |___/| .__/  \__,_||_|  |_| \___||_|   |_||_||_| |_|      ##\\e[0m\\n"
	printf "\\e[1m##          | |                                                   ##\\e[0m\\n"
	printf "\\e[1m##          |_|                                                   ##\\e[0m\\n"
	printf "\\e[1m##                                                                ##\\e[0m\\n"
	printf "\\e[1m##                       %s on %-11s                    ##\\e[0m\\n" "$SCRIPT_VERSION" "$ROUTER_MODEL"
	printf "\\e[1m##                                                                ##\\e[0m\\n"
	printf "\\e[1m##              https://github.com/jackyaz/spdMerlin              ##\\e[0m\\n"
	printf "\\e[1m##                                                                ##\\e[0m\\n"
	printf "\\e[1m####################################################################\\e[0m\\n"
	printf "\\n"
}

MainMenu(){
	AUTOMATIC_ENABLED=""
	EXCLUDEFROMQOS_MENU=""
	if AutomaticMode check; then AUTOMATIC_ENABLED="${PASS}Enabled"; else AUTOMATIC_ENABLED="${ERR}Disabled"; fi
	TEST_SCHEDULE="$(TestSchedule check)"
	if [ "$(echo "$TEST_SCHEDULE" | cut -f2 -d'|' | grep -c "/")" -gt 0 ] && [ "$(echo "$TEST_SCHEDULE" | cut -f3 -d'|')" -eq 0 ]; then
		TEST_SCHEDULE_MENU="Every $(echo "$TEST_SCHEDULE" | cut -f2 -d'|' | cut -f2 -d'/') hours"
	elif [ "$(echo "$TEST_SCHEDULE" | cut -f3 -d'|' | grep -c "/")" -gt 0 ] && [ "$(echo "$TEST_SCHEDULE" | cut -f2 -d'|')" = "*" ]; then
		TEST_SCHEDULE_MENU="Every $(echo "$TEST_SCHEDULE" | cut -f3 -d'|' | cut -f2 -d'/') minutes"
	else
		TEST_SCHEDULE_MENU="Hours: $(echo "$TEST_SCHEDULE" | cut -f2 -d'|')    -    Minutes: $(echo "$TEST_SCHEDULE" | cut -f3 -d'|')"
	fi

	if [ "$(echo "$TEST_SCHEDULE" | cut -f1 -d'|')" = "*" ]; then
		TEST_SCHEDULE_MENU2="Days of week: All"
	else
		TEST_SCHEDULE_MENU2="Days of week: $(echo "$TEST_SCHEDULE" | cut -f1 -d'|')"
	fi
	STORERESULTURL_MENU=""
	if [ "$(StoreResultURL check)" = "true" ]; then
		STORERESULTURL_MENU="Enabled"
	else
		STORERESULTURL_MENU="Disabled"
	fi
	
	printf "WebUI for %s is available at:\\n${SETTING}%s\\e[0m\\n\\n" "$SCRIPT_NAME" "$(Get_WebUI_URL)"
	if [ "$(ExcludeFromQoS check)" = "true" ]; then EXCLUDEFROMQOS_MENU="excluded from"; else EXCLUDEFROMQOS_MENU="included in"; fi
	
	printf "1.    Run a speedtest now\\n\\n"
	printf "2.    Choose a preferred server for an interface\\n\\n"
	printf "3.    Toggle automatic speedtests\\n      Currently: \\e[1m${AUTOMATIC_ENABLED}%s\\e[0m\\n\\n"
	printf "4.    Configure schedule for automatic speedtests\\n      ${SETTING}%s\\n      %s\\e[0m\\n\\n" "$TEST_SCHEDULE_MENU" "$TEST_SCHEDULE_MENU2"
	printf "5.    Toggle data output mode\\n      Currently ${SETTING}%s\\e[0m values will be used for weekly and monthly charts\\n\\n" "$(OutputDataMode check)"
	printf "6.    Toggle time output mode\\n      Currently ${SETTING}%s\\e[0m time values will be used for CSV exports\\n\\n" "$(OutputTimeMode check)"
	printf "7.    Toggle storage of speedtest result URLs\\n      Currently: ${SETTING}%s\\e[0m\\n\\n" "$STORERESULTURL_MENU"
	printf "c.    Customise list of interfaces for automatic speedtests\\n"
	printf "r.    Reset list of interfaces for automatic speedtests to default\\n\\n"
	printf "s.    Toggle storage location for stats and config\\n      Current location is ${SETTING}%s\\e[0m \\n\\n" "$(ScriptStorageLocation check)"
	printf "q.    Toggle exclusion %s speedtests from QoS\\n      Currently %s speedtests are ${SETTING}%s\\e[0m QoS\\n\\n" "$SCRIPT_NAME" "$SCRIPT_NAME" "$EXCLUDEFROMQOS_MENU"
	printf "a.    AutoBW\\n\\n"
	printf "u.    Check for updates\\n"
	printf "uf.   Update %s with latest version (force update)\\n\\n" "$SCRIPT_NAME"
	printf "rt.    Reset %s database / delete all data\\n\\n" "$SCRIPT_NAME"
	printf "e.    Exit %s\\n\\n" "$SCRIPT_NAME"
	printf "z.    Uninstall %s\\n" "$SCRIPT_NAME"
	printf "\\n"
	printf "\\e[1m####################################################################\\e[0m\\n"
	printf "\\n"
	
	while true; do
		printf "Choose an option:  "
		read -r menu
		case "$menu" in
			1)
				printf "\\n"
				Menu_RunSpeedtest
				PressEnter
				break
			;;
			2)
				printf "\\n"
				Menu_ConfigurePreferred
				PressEnter
				break
			;;
			3)
				printf "\\n"
				if AutomaticMode check; then
					AutomaticMode disable
				else
					AutomaticMode enable
				fi
				break
			;;
			4)
				printf "\\n"
				Menu_EditSchedule
				PressEnter
				break
			;;
			5)
				printf "\\n"
				if [ "$(OutputDataMode check)" = "raw" ]; then
					OutputDataMode average
				elif [ "$(OutputDataMode check)" = "average" ]; then
					OutputDataMode raw
				fi
				break
			;;
			6)
				printf "\\n"
				if [ "$(OutputTimeMode check)" = "unix" ]; then
					OutputTimeMode non-unix
				elif [ "$(OutputTimeMode check)" = "non-unix" ]; then
					OutputTimeMode unix
				fi
				break
			;;
			7)
				printf "\\n"
				if [ "$(StoreResultURL check)" = "true" ]; then
					StoreResultURL disable
				elif [ "$(StoreResultURL check)" = "false" ]; then
					StoreResultURL enable
				fi
				break
			;;
			c)
				Generate_Interface_List
				printf "\\n"
				Create_Symlinks
				printf "\\n"
				PressEnter
				break
			;;
			r)
				Create_Symlinks force
				printf "\\n"
				PressEnter
				break
			;;
			s)
				printf "\\n"
				if [ "$(ScriptStorageLocation check)" = "jffs" ]; then
					ScriptStorageLocation usb
					Create_Symlinks
				elif [ "$(ScriptStorageLocation check)" = "usb" ]; then
					ScriptStorageLocation jffs
					Create_Symlinks
				fi
				break
			;;
			q)
				printf "\\n"
				if [ "$(ExcludeFromQoS check)" = "true" ]; then
					if [ "$(AutoBWEnable check)" = "true" ]; then
						Print_Output false "Cannot disable Exclude from QoS when AutoBW is enabled" "$WARN"
						PressEnter
					elif [ "$(AutoBWEnable check)" = "false" ]; then
						ExcludeFromQoS disable
					fi
				elif [ "$(ExcludeFromQoS check)" = "false" ]; then
					ExcludeFromQoS enable
				fi
				break
			;;
			a)
				printf "\\n"
				Menu_AutoBW
				break
			;;
			u)
				printf "\\n"
				if Check_Lock menu; then
					Update_Version
					Clear_Lock
				fi
				PressEnter
				break
			;;
			uf)
				printf "\\n"
				if Check_Lock menu; then
					Update_Version force
					Clear_Lock
				fi
				PressEnter
				break
			;;
			rt)
				printf "\\n"
				if Check_Lock menu; then
					Menu_ResetDB
					Clear_Lock
				fi
				PressEnter
				break
			;;
			e)
				ScriptHeader
				printf "\\n\\e[1mThanks for using %s!\\e[0m\\n\\n\\n" "$SCRIPT_NAME"
				exit 0
			;;
			z)
				while true; do
					printf "\\n\\e[1mAre you sure you want to uninstall %s? (y/n)\\e[0m  " "$SCRIPT_NAME"
					read -r confirm
					case "$confirm" in
						y|Y)
							Menu_Uninstall
							exit 0
						;;
						*)
							break
						;;
					esac
				done
			;;
			*)
				printf "\\nPlease choose a valid option\\n\\n"
			;;
		esac
	done
	
	ScriptHeader
	MainMenu
}

Check_Requirements(){
	CHECKSFAILED="false"
	
	if [ "$(nvram get jffs2_scripts)" -ne 1 ]; then
		nvram set jffs2_scripts=1
		nvram commit
		Print_Output true "Custom JFFS Scripts enabled" "$WARN"
	fi
	
	if ! Check_Swap; then
		Print_Output true "No Swap file detected!" "$ERR"
		CHECKSFAILED="true"
	fi
	
	if [ ! -f /opt/bin/opkg ]; then
		Print_Output true "Entware not detected!" "$ERR"
		CHECKSFAILED="true"
	fi
	
	if ! Firmware_Version_Check; then
		Print_Output true "Unsupported firmware version detected" "$ERR"
		Print_Output true "$SCRIPT_NAME requires Merlin 384.15/384.13_4 or Fork 43E5 (or later)" "$ERR"
		CHECKSFAILED="true"
	fi
	
	if [ "$CHECKSFAILED" = "false" ]; then
		Print_Output true "Installing required packages from Entware" "$PASS"
		opkg update
		opkg install sqlite3-cli
		opkg install jq
		opkg install p7zip
		return 0
	else
		return 1
	fi
}

Menu_Install(){
	Print_Output true "Welcome to $SCRIPT_NAME $SCRIPT_VERSION, a script by JackYaz"
	sleep 1
	
	Print_Output true "Checking your router meets the requirements for $SCRIPT_NAME"
	
	if ! Check_Requirements; then
		Print_Output true "Requirements for $SCRIPT_NAME not met, please see above for the reason(s)" "$CRIT"
		PressEnter
		Clear_Lock
		rm -f "/jffs/scripts/$SCRIPT_NAME_LOWER" 2>/dev/null
		exit 1
	fi
	
	Create_Dirs
	Conf_Exists
	Set_Version_Custom_Settings local "$SCRIPT_VERSION"
	Set_Version_Custom_Settings server "$SCRIPT_VERSION"
	ScriptStorageLocation load
	Create_Symlinks
	
	Download_File "$SCRIPT_REPO/$ARCH.tar.gz" "$OOKLA_DIR/$ARCH.tar.gz"
	tar -xzf "$OOKLA_DIR/$ARCH.tar.gz" -C "$OOKLA_DIR"
	rm -f "$OOKLA_DIR/$ARCH.tar.gz"
	chmod 0755 "$OOKLA_DIR/speedtest"
	
	Update_File spdstats_www.asp
	Update_File shared-jy.tar.gz
	
	Auto_Startup create 2>/dev/null
	Auto_Cron create 2>/dev/null
	Auto_ServiceEvent create 2>/dev/null
	Shortcut_Script create
	
	License_Acceptance accept
	
	Clear_Lock
}

Menu_Startup(){
	if [ -z "$1" ]; then
		Print_Output true "Missing argument for startup, not starting $SCRIPT_NAME" "$WARN"
		exit 1
	elif [ "$1" != "force" ]; then
		if [ ! -f "$1/entware/bin/opkg" ]; then
			Print_Output true "$1 does not contain Entware, not starting $SCRIPT_NAME" "$WARN"
			exit 1
		else
			Print_Output true "$1 contains Entware, starting $SCRIPT_NAME" "$WARN"
		fi
	fi
	
	NTP_Ready
	
	Check_Lock
	
	if [ "$1" != "force" ]; then
		sleep 8
	fi
	
	Create_Dirs
	Conf_Exists
	ScriptStorageLocation load
	Create_Symlinks
	Auto_Startup create 2>/dev/null
	if AutomaticMode check; then Auto_Cron create 2>/dev/null; else Auto_Cron delete 2>/dev/null; fi
	Auto_ServiceEvent create 2>/dev/null
	Shortcut_Script create
	License_Acceptance load
	Mount_WebUI
	
	Clear_Lock
}

Menu_RunSpeedtest(){
	exitmenu=""
	validselection=""
	useiface=""
	usepreferred=""
	ScriptHeader
	while true; do
		printf "Choose an interface to speedtest:\\n\\n"
		printf "1.    All\\n"
		COUNTER="2"
		while IFS='' read -r line || [ -n "$line" ]; do
			if [ "$(echo "$line" | grep -c "interface not up")" -eq 0 ]; then
				printf "%s.    %s\\n" "$COUNTER" "$(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
				COUNTER=$((COUNTER+1))
			fi
		done < "$SCRIPT_INTERFACES_USER"
		printf "\\nChoose an option:  "
		read -r iface_choice
		
		if [ "$iface_choice" = "e" ]; then
			exitmenu="exit"
			break
		elif ! Validate_Number "$iface_choice"; then
			printf "\\n\\e[31mPlease enter a valid number (1-%s)\\e[0m\\n" "$((COUNTER-1))"
			validselection="false"
		else
			if [ "$iface_choice" -lt 1 ] || [ "$iface_choice" -gt "$((COUNTER-1))" ]; then
				printf "\\n\\e[31mPlease enter a number between 1 and %s\\e[0m\\n" "$((COUNTER-1))"
				validselection="false"
			else
				if [ "$iface_choice" -gt "1" ]; then
					useiface="$(grep -v "interface not up" "$SCRIPT_INTERFACES_USER" | sed -n $((iface_choice-1))p | cut -f1 -d"#" | sed 's/ *$//')"
				else
					useiface="All"
				fi
				validselection="true"
			fi
		fi
		
		printf "\\n"
		
		if [ "$exitmenu" != "exit" ] && [ "$validselection" != "false" ]; then
			while true; do
				printf "What mode would you like to use?\\n\\n"
				printf "1.    Auto-select\\n"
				printf "2.    Preferred server\\n"
				printf "3.    Choose a server\\n"
				printf "\\nChoose an option:  "
				read -r usepref_choice
				
				if [ "$usepref_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif ! Validate_Number "$usepref_choice"; then
					printf "\\n\\e[31mPlease enter a valid number (1-%s)\\e[0m\\n" "$COUNTER"
					validselection="false"
				else
					if [ "$usepref_choice" -lt 0 ] || [ "$usepref_choice" -gt "3" ]; then
						printf "\\n\\e[31mPlease enter a number between 1 and %s\\e[0m\\n" "$COUNTER"
						validselection="false"
					else
						case "$usepref_choice" in
							1)
								usepreferred="auto"
							;;
							2)
								usepreferred="user"
							;;
							3)
								usepreferred="onetime"
							;;
						esac
						validselection="true"
						printf "\\n"
						break
					fi
				fi
			done
		fi
		if [ "$exitmenu" != "exit" ] && [ "$validselection" != "false" ]; then
			if Check_Lock menu; then
				Run_Speedtest "$usepreferred" "$useiface"
				Clear_Lock
			fi
		elif [ "$exitmenu" = "exit" ]; then
			break
		fi
		printf "\\n"
		PressEnter
		ScriptHeader
	done
	
	if [ "$exitmenu" != "exit" ]; then
		return 0
	else
		printf "\\n"
		return 1
	fi
}

Menu_ConfigurePreferred(){
	exitmenu=""
	prefiface=""
	ScriptHeader
	while true; do
		printf "Choose an interface to configure server preference for:\\n\\n"
		printf "1.    All (on/off only)\\n\\n"
		COUNTER="2"
		while IFS='' read -r line || [ -n "$line" ]; do
			if [ "$(echo "$line" | grep -c "interface not up")" -eq 0 ]; then
				pref_enabled=""
				if PreferredServer check "$(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"; then pref_enabled="On"; else pref_enabled="Off"; fi
				printf "%s.    %s\\n" "$COUNTER" "$(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
				printf "      Preferred: %s - Server: %s\\n\\n" "$pref_enabled" "$(PreferredServer list "$(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')" | cut -f2 -d"|")"
				COUNTER=$((COUNTER+1))
			fi
		done < "$SCRIPT_INTERFACES_USER"
		while true; do
			printf "\\nChoose an option:  "
			read -r iface_choice
			
			if [ "$iface_choice" = "e" ]; then
				exitmenu="exit"
				break
			elif ! Validate_Number "$iface_choice"; then
				printf "\\n\\e[31mPlease enter a valid number (1-%s)\\e[0m\\n" "$((COUNTER-1))"
			else
				if [ "$iface_choice" -lt 1 ] || [ "$iface_choice" -gt "$((COUNTER-1))" ]; then
					printf "\\n\\e[31mPlease enter a number between 1 and %s\\e[0m\\n" "$((COUNTER-1))"
				else
					if [ "$iface_choice" -gt "1" ]; then
						prefiface="$(grep -v "interface not up" "$SCRIPT_INTERFACES_USER" | sed -n $((iface_choice-1))p | cut -f1 -d"#" | sed 's/ *$//')"
						break
					else
						prefiface="All"
						break
					fi
				fi
			fi
		done
	
		printf "\\n"
		
		if [ "$exitmenu" != "exit" ]; then
			if [ "$prefiface" = "All" ]; then
				while true; do
					printf "What would you like to do?\\n\\n"
					printf "1.    Turn on preferred servers\\n"
					printf "2.    Turn off preferred servers\\n"
					printf "\\nChoose an option:  "
					read -r usepref_choice
					
					if [ "$usepref_choice" = "e" ]; then
						break
					elif ! Validate_Number "$usepref_choice"; then
						printf "\\n\\e[31mPlease enter a valid number (1-2)\\e[0m\\n"
					else
						if [ "$usepref_choice" -lt 1 ] || [ "$usepref_choice" -gt 2 ]; then
							printf "\\n\\e[31mPlease enter a number between 1 and 2\\e[0m\\n\\n"
						else
							prefenabledisable=""
							if [ "$usepref_choice" -eq 1 ]; then
								prefenabledisable="enable"
							else
								prefenabledisable="disable"
							fi
							while IFS='' read -r line || [ -n "$line" ]; do
								if [ "$(echo "$line" | grep -c "interface not up")" -eq 0 ]; then
									PreferredServer "$prefenabledisable" "$(echo "$line" | cut -f1 -d"#" | sed 's/ *$//')"
								fi
							done < "$SCRIPT_INTERFACES_USER"
							printf "\\n"
							break
						fi
					fi
				done
			else
				while true; do
					pref_enabled=""
					if PreferredServer check "$prefiface"; then pref_enabled="On"; else pref_enabled="Off"; fi
					printf "What would you like to do?\\n\\n"
					printf "1.    Toggle preferred server on/off - currently: %s\\n" "$pref_enabled"
					printf "2.    Set preferred server - currently: %s\\n" "$(PreferredServer list "$prefiface" | cut -f2 -d"|")"
					printf "\\nChoose an option:  "
					read -r ifpref_choice
					
					if [ "$ifpref_choice" = "e" ]; then
						break
					elif ! Validate_Number "$ifpref_choice"; then
						printf "\\n\\e[31mPlease enter a valid number (1-2)\\e[0m\\n"
					else
						if [ "$ifpref_choice" -lt 1 ] || [ "$ifpref_choice" -gt 2 ]; then
							printf "\\n\\e[31mPlease enter a number between 1 and 2\\e[0m\\n"
						else
							if [ "$ifpref_choice" -eq 1 ]; then
								printf "\\n"
								if PreferredServer check "$prefiface"; then
									PreferredServer disable "$prefiface"
								else
									PreferredServer enable "$prefiface"
								fi
								break
							elif [ "$ifpref_choice" -eq 2 ]; then
								printf "\\n"
								PreferredServer "update" "$prefiface"
								break
							fi
						fi
					fi
				done
			fi
		fi
		if [ "$exitmenu" = "exit" ]; then
			break
		fi
		printf "\\n"
		PressEnter
		ScriptHeader
	done
	
	if [ "$exitmenu" != "exit" ]; then
		return 0
	else
		printf "\\n"
		return 1
	fi
}

Menu_EditSchedule(){
	exitmenu=""
	formattype=""
	crudays=""
	crudaysvalidated=""
	cruhours=""
	crumins=""
	
	while true; do
		printf "\\n\\e[1mPlease choose which day(s) to run speedtest (0-6 - 0 = Sunday, * for every day, or comma separated days):\\e[0m  "
		read -r day_choice
		
		if [ "$day_choice" = "e" ]; then
			exitmenu="exit"
			break
		elif [ "$day_choice" = "*" ]; then
			crudays="$day_choice"
			printf "\\n"
			break
		elif [ -z "$day_choice" ]; then
			printf "\\n\\e[31mPlease enter a valid number (0-6) or comma separated values\\e[0m\\n"
		else
			crudaystmp="$(echo "$day_choice" | sed "s/,/ /g")"
			crudaysvalidated="true"
			for i in $crudaystmp; do
				if echo "$i" | grep -q "-"; then
					if [ "$i" = "-" ]; then
						printf "\\n\\e[31mPlease enter a valid number (0-6)\\e[0m\\n"
						crudaysvalidated="false"
						break
					fi
					crudaystmp2="$(echo "$i" | sed "s/-/ /")"
					for i2 in $crudaystmp2; do
						if ! Validate_Number "$i2"; then
							printf "\\n\\e[31mPlease enter a valid number (0-6)\\e[0m\\n"
							crudaysvalidated="false"
							break
						elif [ "$i2" -lt 0 ] || [ "$i2" -gt 6 ]; then
							printf "\\n\\e[31mPlease enter a number between 0 and 6\\e[0m\\n"
							crudaysvalidated="false"
							break
						fi
					done
				elif ! Validate_Number "$i"; then
					printf "\\n\\e[31mPlease enter a valid number (0-6) or comma separated values\\e[0m\\n"
					crudaysvalidated="false"
					break
				else
					if [ "$i" -lt 0 ] || [ "$i" -gt 6 ]; then
						printf "\\n\\e[31mPlease enter a number between 0 and 6 or comma separated values\\e[0m\\n"
						crudaysvalidated="false"
						break
					fi
				fi
			done
			if [ "$crudaysvalidated" = "true" ]; then
				crudays="$day_choice"
				printf "\\n"
				break
			fi
		fi
	done
	
	if [ "$exitmenu" != "exit" ]; then
		while true; do
			printf "\\n\\e[1mPlease choose the format to specify the hour/minute(s) to run speedtest:\\e[0m\\n"
			printf "    1. Every X hours/minutes\\n"
			printf "    2. Custom\\n\\n"
			printf "Choose an option:  "
			read -r formatmenu
			
			case "$formatmenu" in
				1)
					formattype="everyx"
					printf "\\n"
					break
				;;
				2)
					formattype="custom"
					printf "\\n"
					break
				;;
				e)
					exitmenu="exit"
					break
				;;
				*)
					printf "\\n\\e[31mPlease enter a valid choice (1-2)\\e[0m\\n"
				;;
			esac
		done
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "everyx" ]; then
			while true; do
				printf "\\n\\e[1mPlease choose whether to specify every X hours or every X minutes to run speedtest:\\e[0m\\n"
				printf "    1. Hours\\n"
				printf "    2. Minutes\\n\\n"
				printf "Choose an option:  "
				read -r formatmenu
				
				case "$formatmenu" in
					1)
						formattype="hours"
						printf "\\n"
						break
					;;
					2)
						formattype="mins"
						printf "\\n"
						break
					;;
					e)
						exitmenu="exit"
						break
					;;
					*)
						printf "\\n\\e[31mPlease enter a valid choice (1-2)\\e[0m\\n"
					;;
				esac
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "hours" ]; then
			while true; do
				printf "\\n\\e[1mPlease choose how often to run speedtest (every X hours, where X is 1-24):\\e[0m  "
				read -r hour_choice
				
				if [ "$hour_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif ! Validate_Number "$hour_choice"; then
						printf "\\n\\e[31mPlease enter a valid number (1-24)\\e[0m\\n"
				elif [ "$hour_choice" -lt 1 ] || [ "$hour_choice" -gt 24 ]; then
					printf "\\n\\e[31mPlease enter a number between 1 and 24\\e[0m\\n"
				elif [ "$hour_choice" -eq 24 ]; then
					cruhours=0
					crumins=0
					printf "\\n"
					break
				else
					cruhours="*/$hour_choice"
					crumins=0
					printf "\\n"
					break
				fi
			done
		elif [ "$formattype" = "mins" ]; then
			while true; do
				printf "\\n\\e[1mPlease choose how often to run speedtest (every X minutes, where X is 1-30):\\e[0m  "
				read -r min_choice
				
				if [ "$min_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif ! Validate_Number "$min_choice"; then
						printf "\\n\\e[31mPlease enter a valid number (1-30)\\e[0m\\n"
				elif [ "$min_choice" -lt 1 ] || [ "$min_choice" -gt 30 ]; then
					printf "\\n\\e[31mPlease enter a number between 1 and 30\\e[0m\\n"
				else
					crumins="*/$min_choice"
					cruhours="*"
					printf "\\n"
					break
				fi
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "custom" ]; then
			while true; do
				printf "\\n\\e[1mPlease choose which hour(s) to run speedtest (0-23, * for every hour, or comma separated hours):\\e[0m  "
				read -r hour_choice
				
				if [ "$hour_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif [ "$hour_choice" = "*" ]; then
					cruhours="$hour_choice"
					printf "\\n"
					break
				else
					cruhourstmp="$(echo "$hour_choice" | sed "s/,/ /g")"
					cruhoursvalidated="true"
					for i in $cruhourstmp; do
						if echo "$i" | grep -q "-"; then
							if [ "$i" = "-" ]; then
								printf "\\n\\e[31mPlease enter a valid number (0-23)\\e[0m\\n"
								cruhoursvalidated="false"
								break
							fi
							cruhourstmp2="$(echo "$i" | sed "s/-/ /")"
							for i2 in $cruhourstmp2; do
								if ! Validate_Number "$i2"; then
									printf "\\n\\e[31mPlease enter a valid number (0-23)\\e[0m\\n"
									cruhoursvalidated="false"
									break
								elif [ "$i2" -lt 0 ] || [ "$i2" -gt 23 ]; then
									printf "\\n\\e[31mPlease enter a number between 0 and 23\\e[0m\\n"
									cruhoursvalidated="false"
									break
								fi
							done
						elif echo "$i" | grep -q "/"; then
							cruhourstmp3="$(echo "$i" | sed "s/\*\///")"
							if ! Validate_Number "$cruhourstmp3"; then
								printf "\\n\\e[31mPlease enter a valid number (0-23)\\e[0m\\n"
								cruhoursvalidated="false"
								break
							elif [ "$cruhourstmp3" -lt 0 ] || [ "$cruhourstmp3" -gt 23 ]; then
								printf "\\n\\e[31mPlease enter a number between 0 and 23\\e[0m\\n"
								cruhoursvalidated="false"
								break
							fi
						elif ! Validate_Number "$i"; then
							printf "\\n\\e[31mPlease enter a valid number (0-23) or comma separated values\\e[0m\\n"
							cruhoursvalidated="false"
							break
						elif [ "$i" -lt 0 ] || [ "$i" -gt 23 ]; then
							printf "\\n\\e[31mPlease enter a number between 0 and 23 or comma separated values\\e[0m\\n"
							cruhoursvalidated="false"
							break
						fi
					done
					if [ "$cruhoursvalidated" = "true" ]; then
						if echo "$hour_choice" | grep -q "-"; then
							cruhours1="$(echo "$hour_choice" | cut -f1 -d'-')"
							cruhours2="$(echo "$hour_choice" | cut -f2 -d'-')"
							if [ "$cruhours1" -lt "$cruhours2" ]; then
								cruhours="$hour_choice"
							elif [ "$cruhours2" -lt "$cruhours1" ]; then
								cruhours="$cruhours1-23,0-$cruhours2"
							fi
						else
							cruhours="$hour_choice"
						fi
						printf "\\n"
						break
					fi
				fi
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "custom" ]; then
			while true; do
				printf "\\n\\e[1mPlease choose which minutes(s) to run speedtest (0-59, * for every minute, or comma separated minutes):\\e[0m  "
				read -r min_choice
				
				if [ "$min_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif [ "$min_choice" = "*" ]; then
					crumins="$min_choice"
					printf "\\n"
					break
				else
					cruminstmp="$(echo "$min_choice" | sed "s/,/ /g")"
					cruminsvalidated="true"
					for i in $cruminstmp; do
						if echo "$i" | grep -q "-"; then
							if [ "$i" = "-" ]; then
								printf "\\n\\e[31mPlease enter a valid number (0-23)\\e[0m\\n"
								cruminsvalidated="false"
								break
							fi
							cruminstmp2="$(echo "$i" | sed "s/-/ /")"
							for i2 in $cruminstmp2; do
								if ! Validate_Number "$i2"; then
									printf "\\n\\e[31mPlease enter a valid number (0-59)\\e[0m\\n"
									cruminsvalidated="false"
									break
								elif [ "$i2" -lt 0 ] || [ "$i2" -gt 59 ]; then
									printf "\\n\\e[31mPlease enter a number between 0 and 59\\e[0m\\n"
									cruminsvalidated="false"
									break
								fi
							done
						elif echo "$i" | grep -q "/"; then
							cruminstmp3="$(echo "$i" | sed "s/\*\///")"
							if ! Validate_Number "$cruminstmp3"; then
								printf "\\n\\e[31mPlease enter a valid number (0-30)\\e[0m\\n"
								cruminsvalidated="false"
								break
							elif [ "$cruminstmp3" -lt 0 ] || [ "$cruminstmp3" -gt 30 ]; then
								printf "\\n\\e[31mPlease enter a number between 0 and 30\\e[0m\\n"
								cruminsvalidated="false"
								break
							fi
						elif ! Validate_Number "$i"; then
							printf "\\n\\e[31mPlease enter a valid number (0-59) or comma separated values\\e[0m\\n"
							cruminsvalidated="false"
							break
						elif [ "$i" -lt 0 ] || [ "$i" -gt 59 ]; then
							printf "\\n\\e[31mPlease enter a number between 0 and 59 or comma separated values\\e[0m\\n"
							cruminsvalidated="false"
							break
						fi
					done
					
					if [ "$cruminsvalidated" = "true" ]; then
						if echo "$min_choice" | grep -q "-"; then
							crumins1="$(echo "$min_choice" | cut -f1 -d'-')"
							crumins2="$(echo "$min_choice" | cut -f2 -d'-')"
							if [ "$crumins1" -lt "$crumins2" ]; then
								crumins="$min_choice"
							elif [ "$crumins2" -lt "$crumins1" ]; then
								crumins="$crumins1-59,0-$crumins2"
							fi
						else
							crumins="$min_choice"
						fi
						printf "\\n"
						break
					fi
				fi
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		TestSchedule update "$crudays" "$cruhours" "$crumins"
		return 0
	else
		return 1
	fi
}

Menu_ResetDB(){
	printf "\\e[1m\\e[33mWARNING: This will reset the %s database by deleting all database records.\\n" "$SCRIPT_NAME"
	printf "A backup of the database will be created if you change your mind.\\e[0m\\n"
	printf "\\n\\e[1mDo you want to continue? (y/n)\\e[0m  "
	read -r confirm
	case "$confirm" in
		y|Y)
			printf "\\n"
			Reset_DB
		;;
		*)
			printf "\\n\\e[1m\\e[33mDatabase reset cancelled\\e[0m\\n\\n"
		;;
	esac
}

Menu_AutoBW(){
	while true; do
		ScriptHeader
		
		AUTOBW_MENU=""
		
		if [ "$(AutoBWEnable check)" = "true" ]; then
			AUTOBW_MENU="Enabled"
		elif [ "$(AutoBWEnable check)" = "false" ]; then
			AUTOBW_MENU="Disabled"
		fi
		
		printf "1.    Update QoS bandwidth values now\\n\\n"
		printf "2.    Configure number of speedtests used to calculate average bandwidth\\n      Currently bandwidth is calculated using the avergae of the last ${SETTING}%s\\e[0m speedtest(s)\\n\\n" "$(AutoBWConf check AVERAGE CALC)"
		printf "3.    Configure scale factor\\n      Download: ${SETTING}%s%%\\e[0m  -  Upload: ${SETTING}%s%%\\e[0m\\n\\n" "$(AutoBWConf check SF DOWN)" "$(AutoBWConf check SF UP)"
		printf "4.    Configure bandwidth limits\\n      Upper Limit    Download: ${SETTING}%s Mbps\\e[0m  -  Upload: ${SETTING}%s Mbps\\e[0m\\n      Lower Limit    Download: ${SETTING}%s Mbps\\e[0m  -  Upload: ${SETTING}%s Mbps\\e[0m\\n\\n" "$(AutoBWConf check ULIMIT DOWN)" "$(AutoBWConf check ULIMIT UP)" "$(AutoBWConf check LLIMIT DOWN)" "$(AutoBWConf check LLIMIT UP)"
		printf "5.    Configure threshold for updating QoS bandwidth values\\n      Download: ${SETTING}%s%%\\e[0m - Upload: ${SETTING}%s%%\\e[0m\\n\\n" "$(AutoBWConf check THRESHOLD DOWN)" "$(AutoBWConf check THRESHOLD UP)"
		printf "6.    Toggle AutoBW on/off\\n      Currently: ${SETTING}%s\\e[0m\\n\\n" "$AUTOBW_MENU"
		printf "e.    Go back\\n\\n"
		printf "\\e[1m####################################################################\\e[0m\\n"
		printf "\\n"
		
		printf "Choose an option:  "
		read -r autobwmenu
		case "$autobwmenu" in
			1)
				printf "\\n"
				Menu_AutoBW_Update
				PressEnter
			;;
			2)
				while true; do
					ScriptHeader
					exitmenu=""
					avgnum=""
					while true; do
						printf "\\n"
						printf "Enter number of speedtests to use to calculate avg bandwidth (1-30):  "
						read -r avgnumvalue
							if [ "$avgnumvalue" = "e" ]; then
								exitmenu="exit"
								break
							elif ! Validate_Number "$avgnumvalue"; then
								printf "\\n\\e[31mPlease enter a valid number (1-30)\\e[0m\\n"
							else
								if [ "$avgnumvalue" -lt 1 ] || [ "$avgnumvalue" -gt 30 ]; then
									printf "\\n\\e[31mPlease enter a number between 1 and 30\\e[0m\\n"
								else
									avgnum="$avgnumvalue"
									break
								fi
							fi
					done
					if [ "$exitmenu" != "exit" ]; then
						AutoBWConf update AVERAGE CALC "$avgnum"
						break
					fi
					if [ "$exitmenu" = "exit" ]; then
						break
					fi
				done
				printf "\\n"
				PressEnter
			;;
			3)
				while true; do
					ScriptHeader
					exitmenu=""
					updown=""
					sfvalue=""
					printf "\\n"
					printf "Select a scale factor to set\\n"
					printf "1.    Download\\n"
					printf "2.    Upload\\n\\n"
					while true; do
						printf "Choose an option:  "
						read -r autobwsfchoice
						if [ "$autobwsfchoice" = "e" ]; then
							exitmenu="exit"
							break
						elif ! Validate_Number "$autobwsfchoice"; then
							printf "\\n\\e[31mPlease enter a valid number (1-2)\\e[0m\\n\\n"
						else
							if [ "$autobwsfchoice" -lt 1 ] || [ "$autobwsfchoice" -gt 2 ]; then
								printf "\\n\\e[31mPlease enter a number between 1 and 2\\e[0m\\n\\n"
							else
								if [ "$autobwsfchoice" -eq 1 ]; then
									updown="DOWN"
									break
								elif [ "$autobwsfchoice" -eq 2 ]; then
									updown="UP"
									break
								fi
							fi
						fi
					done
					if [ "$exitmenu" != "exit" ]; then
						while true; do
							printf "\\n"
							printf "Enter percentage to scale bandwidth by (1-100):  "
							read -r autobwsfvalue
								if [ "$autobwsfvalue" = "e" ]; then
									exitmenu="exit"
									break
								elif ! Validate_Number "$autobwsfvalue"; then
									printf "\\n\\e[31mPlease enter a valid number (1-100)\\e[0m\\n"
								else
									if [ "$autobwsfvalue" -lt 1 ] || [ "$autobwsfvalue" -gt 100 ]; then
										printf "\\n\\e[31mPlease enter a number between 1 and 100\\e[0m\\n"
									else
										sfvalue="$autobwsfvalue"
										break
									fi
								fi
						done
					fi
					if [ "$exitmenu" != "exit" ]; then
						AutoBWConf update SF "$updown" "$sfvalue"
						break
					fi
					
					if [ "$exitmenu" = "exit" ]; then
						break
					fi
				done
				
				printf "\\n"
				PressEnter
			;;
			4)
				while true; do
					ScriptHeader
					exitmenu=""
					updown=""
					limithighlow=""
					limitvalue=""
					printf "\\n"
					printf "Select a bandwidth to set limit for\\n"
					printf "1.    Download\\n"
					printf "2.    Upload\\n\\n"
					while true; do
						printf "Choose an option:  "
						read -r autobwchoice
						if [ "$autobwchoice" = "e" ]; then
							exitmenu="exit"
							break
						elif ! Validate_Number "$autobwchoice"; then
							printf "\\n\\e[31mPlease enter a valid number (1-2)\\e[0m\\n\\n"
						else
							if [ "$autobwchoice" -lt 1 ] || [ "$autobwchoice" -gt 2 ]; then
								printf "\\n\\e[31mPlease enter a number between 1 and 2\\e[0m\\n\\n"
							else
								if [ "$autobwchoice" -eq 1 ]; then
									updown="DOWN"
									break
								elif [ "$autobwchoice" -eq 2 ]; then
									updown="UP"
									break
								fi
							fi
						fi
					done
					if [ "$exitmenu" != "exit" ]; then
						while true; do
							printf "\\n"
							printf "Select a limit to set\\n"
							printf "1.    Upper\\n"
							printf "2.    Lower\\n\\n"
							printf "Choose an option:  "
							read -r autobwlimit
								if [ "$autobwlimit" = "e" ]; then
									exitmenu="exit"
									break
								elif ! Validate_Number "$autobwlimit"; then
									printf "\\n\\e[31mPlease enter a valid number (1-100)\\e[0m\\n"
								else
									if [ "$autobwlimit" -lt 1 ] || [ "$autobwlimit" -gt 100 ]; then
										printf "\\n\\e[31mPlease enter a number between 1 and 100\\e[0m\\n"
									else
										if [ "$autobwlimit" -eq 1 ]; then
											limithighlow="ULIMIT"
										elif [ "$autobwlimit" -eq 2 ]; then
											limithighlow="LLIMIT"
										fi
									fi
								fi
								
								if [ "$exitmenu" != "exit" ]; then
									while true; do
										printf "\\n"
										printf "Enter value to set limit to (0 = unlimited for upper):  "
										read -r autobwlimvalue
										if [ "$autobwlimvalue" = "e" ]; then
											exitmenu="exit"
											break
										elif ! Validate_Number "$autobwlimvalue"; then
											printf "\\n\\e[31mPlease enter a valid number (1-100)\\e[0m\\n"
										else
											limitvalue="$autobwlimvalue"
											break
										fi
									done
									if [ "$exitmenu" != "exit" ]; then
										AutoBWConf update "$limithighlow" "$updown" "$limitvalue"
										exitmenu="exit"
										break
									fi
								fi
						done
						if [ "$exitmenu" = "exit" ]; then
							break
						fi
					fi
				done
				
				printf "\\n"
				PressEnter
			;;
			5)
				while true; do
					ScriptHeader
					exitmenu=""
					updown=""
					thvalue=""
					printf "\\n"
					printf "Select a threshold to set\\n"
					printf "1.    Download\\n"
					printf "2.    Upload\\n\\n"
					while true; do
						printf "Choose an option:  "
						read -r autobwthchoice
						if [ "$autobwthchoice" = "e" ]; then
							exitmenu="exit"
							break
						elif ! Validate_Number "$autobwthchoice"; then
							printf "\\n\\e[31mPlease enter a valid number (1-2)\\e[0m\\n\\n"
						else
							if [ "$autobwthchoice" -lt 1 ] || [ "$autobwthchoice" -gt 2 ]; then
								printf "\\n\\e[31mPlease enter a number between 1 and 2\\e[0m\\n\\n"
							else
								if [ "$autobwthchoice" -eq 1 ]; then
									updown="DOWN"
									break
								elif [ "$autobwthchoice" -eq 2 ]; then
									updown="UP"
									break
								fi
							fi
						fi
					done
					
					if [ "$exitmenu" != "exit" ]; then
						while true; do
							printf "\\n"
							printf "Enter percentage to use for result threshold:  "
							read -r autobwthvalue
							if [ "$autobwthvalue" = "e" ]; then
								exitmenu="exit"
								break
							elif ! Validate_Number "$autobwthvalue"; then
								printf "\\n\\e[31mPlease enter a valid number (0-100)\\e[0m\\n"
							else
								if [ "$autobwthvalue" -lt 0 ] || [ "$autobwthvalue" -gt 100 ]; then
									printf "\\n\\e[31mPlease enter a number between 0 and 100\\e[0m\\n"
								else
									thvalue="$autobwthvalue"
									break
								fi
							fi
						done
					fi
					
					if [ "$exitmenu" != "exit" ]; then
						AutoBWConf update THRESHOLD "$updown" "$thvalue"
						break
					fi
					
					if [ "$exitmenu" = "exit" ]; then
						break
					fi
				done
				
				printf "\\n"
				PressEnter
			;;
			6)
				printf "\\n"
				if [ "$(AutoBWEnable check)" = "true" ]; then
					AutoBWEnable disable
				elif [ "$(AutoBWEnable check)" = "false" ]; then
					AutoBWEnable enable
					if [ "$(ExcludeFromQoS check)" = "false" ]; then
						Print_Output false "Enabling Exclude from QoS (required for AutoBW)"
						ExcludeFromQoS enable
						PressEnter
					fi
				fi
			;;
			e)
				break
			;;
		esac
	done
}

Menu_AutoBW_Update(){
	if [ "$(nvram get qos_enable)" -eq 0 ]; then
		Print_Output true "QoS is not enabled, please enable this in the Asus WebUI." "$ERR"
		return 1
	fi
	
	dsf="$(AutoBWConf check SF DOWN | awk '{printf ($1/100)}')"
	usf="$(AutoBWConf check SF UP | awk '{printf ($1/100)}')"
	
	dlimitlow="$(($(AutoBWConf check LLIMIT DOWN)*1024))"
	dlimithigh="$(($(AutoBWConf check ULIMIT DOWN)*1024))"
	ulimitlow="$(($(AutoBWConf check LLIMIT UP)*1024))"
	ulimithigh="$(($(AutoBWConf check ULIMIT UP)*1024))"
	avgcalc="$(AutoBWConf check AVERAGE CALC)"
	
	metriclist="Download Upload"
	
	for metric in $metriclist; do
	{
		{
			echo ".mode list"
			echo ".headers off"
			echo ".output /tmp/spdbw$metric"
			echo "SELECT avg($metric) FROM (SELECT $metric FROM spdstats_WAN ORDER BY [Timestamp] DESC LIMIT $avgcalc);"
		} > /tmp/spd-autobw.sql
		"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-autobw.sql
		rm -f /tmp/spd-autobw.sql
	}
	done
	
	dspdkbps="$(echo "$(awk '{printf (1024*$1)}' /tmp/spdbwDownload)" "$dsf" | awk '{printf int($1*$2)}')"
	uspdkbps="$(echo "$(awk '{printf (1024*$1)}' /tmp/spdbwUpload)" "$usf" | awk '{printf int($1*$2)}')"
	
	rm -f /tmp/spdbwDownload
	rm -f /tmp/spdbwUpload
	
	if [ "$dspdkbps" -lt "$dlimitlow" ]; then
		Print_Output true "Download speed ($dspdkbps Kbps) < lower limit ($dlimitlow Kbps)" "$WARN"
		dspdkbps="$dlimitlow"
	elif [ "$dspdkbps" -gt "$dlimithigh" ] && [ "$dlimithigh" -gt 0 ]; then
		Print_Output true "Download speed ($dspdkbps Kbps) > upper limit ($dlimithigh Kbps)" "$WARN"
		dspdkbps="$dlimithigh"
	fi
	
	if [ "$uspdkbps" -lt "$ulimitlow" ]; then
		Print_Output true "Upload speed ($uspdkbps Kbps) < lower limit ($ulimitlow Kbps)" "$WARN"
		uspdkbps="$ulimitlow"
	elif [ "$uspdkbps" -gt "$ulimithigh" ] && [ "$ulimithigh" -gt 0 ]; then
		Print_Output true "Upload speed ($uspdkbps Kbps) > upper limit ($ulimithigh Kbps)" "$WARN"
		uspdkbps="$ulimithigh"
	fi
	
	old_uspdkbps="$(nvram get qos_obw)"
	old_dspdkbps="$(nvram get qos_ibw)"
	
	bw_changed="false"
	
	dbw_threshold="$(AutoBWConf check THRESHOLD DOWN | awk '{printf ($1/100)}')"
	
	if [ "$dspdkbps" -gt "$(echo "$old_dspdkbps" "$dbw_threshold" | awk '{printf int($1+$1*$2)}')" ] || [ "$dspdkbps" -lt "$(echo "$old_dspdkbps" "$dbw_threshold" | awk '{printf int($1-$1*$2)}')" ]; then
		bw_changed="true"
		nvram set qos_ibw="$(echo $dspdkbps | cut -d'.' -f1)"
		Print_Output true "Setting QoS Download Speed to $dspdkbps Kbps (was $old_dspdkbps Kbps)" "$PASS"
	else
		Print_Output true "Calculated Download speed ($dspdkbps) Kbps does not exceed $(AutoBWConf check THRESHOLD DOWN)% threshold of existing value ($old_dspdkbps Kbps)" "$WARN"
	fi
	
	ubw_threshold="$(AutoBWConf check THRESHOLD UP | awk '{printf ($1/100)}')"
	
	if [ "$uspdkbps" -gt "$(echo "$old_uspdkbps" "$ubw_threshold" | awk '{printf int($1+$1*$2)}')" ] || [ "$uspdkbps" -lt "$(echo "$old_uspdkbps" "$ubw_threshold" | awk '{printf int($1-$1*$2)}')" ]; then
		bw_changed="true"
		nvram set qos_obw="$(echo $uspdkbps | cut -d'.' -f1)"
		Print_Output true "Setting QoS Upload Speed to $uspdkbps Kbps (was $old_uspdkbps Kbps)" "$PASS"
	else
		Print_Output true "Calculated Upload speed ($uspdkbps) Kbps does not exceed $(AutoBWConf check THRESHOLD UP)% threshold of existing value ($old_uspdkbps Kbps)" "$WARN"
	fi
	
	if [ "$bw_changed" = "true" ]; then
		nvram commit
		service "restart_qos;restart_firewall" >/dev/null 2>&1
	fi
	
	Clear_Lock
}

Menu_Uninstall(){
	Print_Output true "Removing $SCRIPT_NAME..." "$PASS"
	Auto_Startup delete 2>/dev/null
	Auto_Cron delete 2>/dev/null
	Auto_ServiceEvent delete 2>/dev/null
	
	Get_WebUI_Page "$SCRIPT_DIR/spdstats_www.asp"
	if [ -n "$MyPage" ] && [ "$MyPage" != "none" ] && [ -f "/tmp/menuTree.js" ]; then
		sed -i "\\~$MyPage~d" /tmp/menuTree.js
		umount /www/require/modules/menuTree.js
		mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
		rm -f "$SCRIPT_WEBPAGE_DIR/$MyPage"
	fi
	
	rm -f "$SCRIPT_DIR/spdstats_www.asp" 2>/dev/null
	
	printf "\\n\\e[1mDo you want to delete %s stats and config? (y/n)\\e[0m  " "$SCRIPT_NAME"
	read -r confirm
	case "$confirm" in
		y|Y)
			rm -rf "$SCRIPT_DIR" 2>/dev/null
			rm -rf "$SCRIPT_STORAGE_DIR" 2>/dev/null
		;;
		*)
			:
		;;
	esac
	Shortcut_Script delete
	
	rm -rf "$SCRIPT_WEB_DIR" 2>/dev/null
	rm -rf "$OOKLA_DIR" 2>/dev/null
	rm -rf "$OOKLA_LICENSE_DIR" 2>/dev/null
	rm -f "/jffs/scripts/$SCRIPT_NAME_LOWER" 2>/dev/null
	Clear_Lock
	Print_Output true "Uninstall completed" "$PASS"
}

NTP_Ready(){
	if [ "$(nvram get ntp_ready)" -eq 0 ]; then
		ntpwaitcount=0
		Check_Lock
		while [ "$(nvram get ntp_ready)" -eq 0 ] && [ "$ntpwaitcount" -lt 600 ]; do
			ntpwaitcount="$((ntpwaitcount + 30))"
			Print_Output true "Waiting for NTP to sync..." "$WARN"
			sleep 30
		done
		if [ "$ntpwaitcount" -ge 600 ]; then
			Print_Output true "NTP failed to sync after 10 minutes. Please resolve!" "$CRIT"
			Clear_Lock
			exit 1
		else
			Print_Output true "NTP synced, $SCRIPT_NAME will now continue" "$PASS"
			Clear_Lock
		fi
	fi
}

### function based on @Adamm00's Skynet USB wait function ###
Entware_Ready(){
	if [ ! -f "/opt/bin/opkg" ]; then
		Check_Lock
		sleepcount=1
		while [ ! -f "/opt/bin/opkg" ] && [ "$sleepcount" -le 10 ]; do
			Print_Output true "Entware not found, sleeping for 10s (attempt $sleepcount of 10)" "$ERR"
			sleepcount="$((sleepcount + 1))"
			sleep 10
		done
		if [ ! -f /opt/bin/opkg ]; then
			Print_Output true "Entware not found and is required for $SCRIPT_NAME to run, please resolve" "$CRIT"
			Clear_Lock
			exit 1
		else
			Print_Output true "Entware found, $SCRIPT_NAME will now continue" "$PASS"
			Clear_Lock
		fi
	fi
}
### ###

### function based on @dave14305's FlexQoS about function ###
Show_About(){
	cat <<EOF
About
  $SCRIPT_NAME is an internet speedtest and monitoring tool for
  AsusWRT Merlin with charts for daily, weekly and monthly summaries.
  It tracks download/upload bandwidth as well as latency, jitter and
  packet loss.
License
  $SCRIPT_NAME is free to use under the GNU General Public License
  version 3 (GPL-3.0) https://opensource.org/licenses/GPL-3.0
Help & Support
  https://www.snbforums.com/forums/asuswrt-merlin-addons.60/?prefix_id=19
Source code
  https://github.com/jackyaz/$SCRIPT_NAME
EOF
	printf "\\n"
}
### ###

### function based on @dave14305's FlexQoS show_help function ###
Show_Help(){
	cat <<EOF
Available commands:
  $SCRIPT_NAME_LOWER about              explains functionality
  $SCRIPT_NAME_LOWER update             checks for updates
  $SCRIPT_NAME_LOWER forceupdate        updates to latest version (force update)
  $SCRIPT_NAME_LOWER startup force      runs startup actions such as mount WebUI tab
  $SCRIPT_NAME_LOWER install            installs script
  $SCRIPT_NAME_LOWER uninstall          uninstalls script
  $SCRIPT_NAME_LOWER generate           run speedtest and save to database. also runs outputcsv
  $SCRIPT_NAME_LOWER outputcsv          create CSVs from database, used by WebUI and export
  $SCRIPT_NAME_LOWER enable             enable automatic speedtests
  $SCRIPT_NAME_LOWER disable            disable automatic speedtests
  $SCRIPT_NAME_LOWER develop            switch to development branch
  $SCRIPT_NAME_LOWER stable             switch to stable branch
EOF
	printf "\\n"
}
### ###

if [ -f "/opt/share/$SCRIPT_NAME_LOWER.d/config" ]; then
	SCRIPT_CONF="/opt/share/$SCRIPT_NAME_LOWER.d/config"
	SCRIPT_STORAGE_DIR="/opt/share/$SCRIPT_NAME_LOWER.d"
else
	SCRIPT_CONF="/jffs/addons/$SCRIPT_NAME_LOWER.d/config"
	SCRIPT_STORAGE_DIR="/jffs/addons/$SCRIPT_NAME_LOWER.d"
fi

SCRIPT_INTERFACES="$SCRIPT_STORAGE_DIR/.interfaces"
SCRIPT_INTERFACES_USER="$SCRIPT_STORAGE_DIR/.interfaces_user"
CSV_OUTPUT_DIR="$SCRIPT_STORAGE_DIR/csv"

if [ -z "$1" ]; then
	NTP_Ready
	Entware_Ready
	if [ ! -f /opt/bin/sqlite3 ]; then
		Print_Output true "Installing required version of sqlite3 from Entware" "$PASS"
		opkg update
		opkg install sqlite3-cli
	fi
	
	Create_Dirs
	Conf_Exists
	ScriptStorageLocation load
	Create_Symlinks
	
	Process_Upgrade
	
	Auto_Startup create 2>/dev/null
	if AutomaticMode check; then Auto_Cron create 2>/dev/null; else Auto_Cron delete 2>/dev/null; fi
	Auto_ServiceEvent create 2>/dev/null
	Shortcut_Script create
	License_Acceptance load
	ScriptHeader
	MainMenu
	exit 0
fi

case "$1" in
	install)
		Check_Lock
		Menu_Install
		exit 0
	;;
	startup)
		Menu_Startup "$2"
		exit 0
	;;
	generate)
		NTP_Ready
		Entware_Ready
		Check_Lock
		Run_Speedtest schedule
		Clear_Lock
		exit 0
	;;
	service_event)
		if [ "$2" = "start" ] && echo "$3" | grep -q "${SCRIPT_NAME_LOWER}spdtest"; then
			rm -f /tmp/detect_spdtest.js
			Check_Lock webui
			Run_Speedtest_WebUI "$3"
			Clear_Lock
			exit 0
		elif [ "$2" = "start" ] && echo "$3" | grep -q "${SCRIPT_NAME_LOWER}serverlistmanual"; then
			spdifacename="$(echo "$3" | sed "s/${SCRIPT_NAME_LOWER}serverlistmanual_//" | cut -f1 -d'_' | tr "a-z" "A-Z")";
			GenerateServerList_WebUI "$spdifacename" "spdmerlin_manual_serverlist"
		elif [ "$2" = "start" ] && echo "$3" | grep -q "${SCRIPT_NAME_LOWER}serverlist"; then
			spdifacename="$(echo "$3" | sed "s/${SCRIPT_NAME_LOWER}serverlist_//" | cut -f1 -d'_' | tr "a-z" "A-Z")";
			GenerateServerList_WebUI "$spdifacename" "spdmerlin_serverlist_$spdifacename"
		elif [ "$2" = "start" ] && [ "$3" = "${SCRIPT_NAME_LOWER}config" ]; then
			Interfaces_FromSettings
			Conf_FromSettings
			exit 0
		elif [ "$2" = "start" ] && [ "$3" = "${SCRIPT_NAME_LOWER}checkupdate" ]; then
			Update_Check
			exit 0
		elif [ "$2" = "start" ] && [ "$3" = "${SCRIPT_NAME_LOWER}doupdate" ]; then
			Update_Version force unattended
			exit 0
		fi
		exit 0
	;;
	outputcsv)
		NTP_Ready
		Entware_Ready
		Check_Lock
		Generate_CSVs
		Clear_Lock
		exit 0
	;;
	enable)
		Entware_Ready
		AutomaticMode enable
		exit 0
	;;
	disable)
		Entware_Ready
		AutomaticMode disable
		exit 0
	;;
	update)
		Update_Version
		exit 0
	;;
	forceupdate)
		Update_Version force
		exit 0
	;;
	postupdate)
		Create_Dirs
		Conf_Exists
		ScriptStorageLocation load
		Create_Symlinks
		Process_Upgrade
		Auto_Startup create 2>/dev/null
		if AutomaticMode check; then Auto_Cron create 2>/dev/null; else Auto_Cron delete 2>/dev/null; fi
		Auto_ServiceEvent create 2>/dev/null
		Shortcut_Script create
		License_Acceptance load
		Set_Version_Custom_Settings local "$SCRIPT_VERSION"
		Set_Version_Custom_Settings server "$SCRIPT_VERSION"
	;;
	setversion)
		Create_Dirs
		Conf_Exists
		ScriptStorageLocation load
		Create_Symlinks
		Process_Upgrade
		Auto_Startup create 2>/dev/null
		if AutomaticMode check; then Auto_Cron create 2>/dev/null; else Auto_Cron delete 2>/dev/null; fi
		Auto_ServiceEvent create 2>/dev/null
		Shortcut_Script create
		License_Acceptance load
		Set_Version_Custom_Settings local "$SCRIPT_VERSION"
		Set_Version_Custom_Settings server "$SCRIPT_VERSION"
	;;
	checkupdate)
		Update_Check
		exit 0
	;;
	uninstall)
		Check_Lock
		Menu_Uninstall
		exit 0
	;;
	develop)
		SCRIPT_BRANCH="develop"
		SCRIPT_REPO="https://raw.githubusercontent.com/jackyaz/$SCRIPT_NAME/$SCRIPT_BRANCH"
		Update_Version force
		exit 0
	;;
	stable)
		SCRIPT_BRANCH="master"
		SCRIPT_REPO="https://raw.githubusercontent.com/jackyaz/$SCRIPT_NAME/$SCRIPT_BRANCH"
		Update_Version force
		exit 0
	;;
	about)
		ScriptHeader
		Show_About
		exit 0
	;;
	help)
		ScriptHeader
		Show_Help
		exit 0
	;;
	*)
		ScriptHeader
		Print_Output false "Command not recognised." "$ERR"
		Print_Output false "For a list of available commands run: $SCRIPT_NAME_LOWER help"
		exit 1
	;;
esac
