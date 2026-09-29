#!/usr/bin/env bash
#
# swhw: collect a SERVERware host's hardware details and upload them to
# DT Collector as a hardware-only report.
#
# Only the SERVERware admin API token and a DT Collector upload key are
# needed. The report contains descriptive hardware details and versions
# only: no keys, IP addresses, host names, serial numbers or UUIDs.
#
# Run it without downloading anything to disk:
#   bash <(curl -fsSL https://raw.githubusercontent.com/galijas/swhw/main/swhw.sh)
#
# Everything is wrapped in main(), called on the last line, so a partial
# download never runs and "curl ... | bash" works too.

set -uo pipefail

SWHW_VERSION="1.0.0"
SOURCE_NAME="hw-collect" # the report source name DT Collector expects
DT_URL_DEFAULT="https://dtcollector.dtbicom.xyz"

JQ_VERSION="1.7.1"
JQ_SHA256_AMD64="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
JQ_SHA256_ARM64="4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5"

OBS_WAIT_S=180 # how long to wait for the SRW exporter after enabling observability
POLL_S=5

WORK=""          # temporary directory, removed on exit
OBS_CHANGED=0    # 1 when this script turned observability on
SECRET_PROMPT=0  # 1 while terminal echo is off
HTTP_CODE=""
TTY=/dev/tty

# --- output ---------------------------------------------------------------

if [[ -t 2 ]]; then
	C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RESET=$'\e[0m'
else
	C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_RESET=""
fi

# Status messages go to stderr so that --dry-run prints only the report
# on stdout.
step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok() { printf '    %sOK%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%sWarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() {
	err "$*"
	exit 1
}

usage() {
	cat <<EOF
swhw ${SWHW_VERSION}: upload a SERVERware host's hardware details to DT Collector

Usage: swhw.sh [options]

Options:
  --controller ADDR  SERVERware controller: IP address, DNS name or URL
                     (http:// or https://; https is used when omitted)
  --host NAME        report only this host (by default: the host of a
                     Standalone or Mirror, or every host of a Cluster)
  --dt-url URL       DT Collector address (default: ${DT_URL_DEFAULT})
  --dry-run          print the report instead of uploading it
                     (no DT Collector key needed)
  -h, --help         show this help
  -V, --version      show the version

Environment (each is prompted for when not set):
  SW_CONTROLLER      same as --controller
  SW_TOKEN           SERVERware admin API token
  DT_KEY             DT Collector upload key (dtk_...)

If Observability is disabled in SERVERware, it is enabled while the
hardware details are collected and disabled again before the script exits.
EOF
}

# --- cleanup --------------------------------------------------------------

cleanup() {
	local rc=$?
	trap - EXIT INT TERM
	if ((SECRET_PROMPT)); then
		stty echo <"$TTY" 2>/dev/null
		printf '\n' >&2
	fi
	restore_observability
	if [[ -n $WORK && -d $WORK ]]; then
		rm -rf -- "$WORK"
	fi
	exit "$rc"
}

# --- prompts --------------------------------------------------------------

have_tty() { { : <"$TTY"; } 2>/dev/null; }

# prompt VAR "Question" [secret]
prompt() {
	local __var=$1 __question=$2 __secret=${3:-} __answer=""
	have_tty || die "no terminal to ask for input; run in a terminal or set SW_CONTROLLER, SW_TOKEN and DT_KEY (see --help)"
	if [[ -n $__secret ]]; then
		SECRET_PROMPT=1
		IFS= read -r -s -p "$__question: " __answer <"$TTY"
		SECRET_PROMPT=0
		printf '\n' >&2
	else
		IFS= read -r -p "$__question: " __answer <"$TTY"
	fi
	# Trim surrounding whitespace (pasted keys often carry a newline or space).
	__answer="${__answer#"${__answer%%[![:space:]]*}"}"
	__answer="${__answer%"${__answer##*[![:space:]]}"}"
	printf -v "$__var" '%s' "$__answer"
}

# --- dependencies ---------------------------------------------------------

jq_works() {
	command -v jq >/dev/null 2>&1 &&
		[[ $(jq -rn '"Ab1" | test("^[A-Z]") and ("x" | ascii_upcase) == "X"' 2>/dev/null) == true ]]
}

# Downloads a static jq build into the temporary directory when the
# machine has no usable jq. It's deleted with the rest on exit.
fetch_jq() {
	local arch sum
	case $(uname -m) in
	x86_64 | amd64) arch=amd64 sum=$JQ_SHA256_AMD64 ;;
	aarch64 | arm64) arch=arm64 sum=$JQ_SHA256_ARM64 ;;
	*) die "jq is required and no prebuilt jq is available for $(uname -m); install jq and run again" ;;
	esac
	info "jq not found, downloading jq ${JQ_VERSION} (removed on exit)"
	mkdir -p "$WORK/bin"
	if ! curl -fsSL --connect-timeout 15 --max-time 120 -o "$WORK/bin/jq" \
		"https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${arch}"; then
		die "could not download jq; install jq and run again"
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		[[ $(sha256sum "$WORK/bin/jq" | cut -d' ' -f1) == "$sum" ]] ||
			die "the downloaded jq failed its checksum; install jq and run again"
	else
		warn "sha256sum not found, the downloaded jq was not verified"
	fi
	chmod 700 "$WORK/bin/jq"
	PATH="$WORK/bin:$PATH"
	jq_works || die "the downloaded jq does not run on this machine; install jq and run again"
}

check_deps() {
	local t
	for t in curl mktemp; do
		command -v "$t" >/dev/null 2>&1 || die "'$t' is required but not installed"
	done
	jq_works || fetch_jq
}

# --- HTTP -----------------------------------------------------------------

# Keys are passed to curl in config files (mode 600) rather than on the
# command line, where other users could see them in the process list.
write_curl_config() {
	local file=$1 header=$2
	header=${header//\\/\\\\}
	header=${header//\"/\\\"}
	(umask 077 && printf 'header = "%s"\n' "$header" >"$file")
}

# sw_call METHOD PATH [JSON-BODY]: sets HTTP_CODE ("000" when the
# controller could not be reached), body in $WORK/resp. The controller's
# certificate is usually self-signed, so it's not verified.
sw_call() {
	local method=$1 path=$2 body=${3:-}
	local args=(-sS -k -X "$method" -o "$WORK/resp" -w '%{http_code}'
		--connect-timeout 10 --max-time 60)
	[[ -f $WORK/sw.cfg ]] && args+=(-K "$WORK/sw.cfg")
	if [[ -n $body ]]; then
		printf '%s' "$body" >"$WORK/req"
		args+=(-H 'Content-Type: application/json;charset=utf-8' --data-binary "@$WORK/req")
	fi
	HTTP_CODE=$(curl "${args[@]}" "$SW_BASE$path" 2>"$WORK/curl.err") || HTTP_CODE=000
	[[ -f $WORK/resp ]] || : >"$WORK/resp"
}

# sw_error: the error message from the last SERVERware response.
sw_error() {
	local msg
	msg=$(jq -r '.Error // .error // empty' "$WORK/resp" 2>/dev/null)
	printf '%s' "${msg:-HTTP $HTTP_CODE}"
}

# prom NAME QUERY: runs an instant PromQL query and stores data.result in
# $WORK/p_NAME.json ([] when the query fails).
prom() {
	local name=$1 query=$2
	HTTP_CODE=$(curl -sS -k -G -K "$WORK/sw.cfg" -o "$WORK/resp" -w '%{http_code}' \
		--connect-timeout 10 --max-time 60 --data-urlencode "query=$query" \
		"$SW_BASE/prometheus/api/v1/query" 2>"$WORK/curl.err") || HTTP_CODE=000
	if [[ $HTTP_CODE == 200 ]] && jq -e '.status == "success"' "$WORK/resp" >/dev/null 2>&1; then
		jq '.data.result // []' "$WORK/resp" >"$WORK/p_$name.json"
	else
		echo '[]' >"$WORK/p_$name.json"
		return 1
	fi
}

prom_targets() {
	sw_call GET /prometheus/api/v1/targets
	[[ $HTTP_CODE == 200 ]] && cp "$WORK/resp" "$WORK/targets.json"
}

# srw_exporter_up: the SRW exporter (port 9101) is being scraped.
srw_exporter_up() {
	prom_targets || return 1
	jq -e '[.data.activeTargets[]? | select(.health == "up" and ((.scrapeUrl // "") | test("^[^/]+//[^/]*:9101(/|$)")))] | length > 0' \
		"$WORK/targets.json" >/dev/null 2>&1
}

# --- steps ----------------------------------------------------------------

# normalize_controller ADDR: prints the controller's base URL.
normalize_controller() {
	local s=$1 scheme=https lower
	lower=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
	case $lower in
	http://*) scheme=http s=${s:7} ;;
	https://*) s=${s:8} ;;
	*://*) return 1 ;;
	esac
	s=${s%%/*}
	[[ $s =~ ^[][A-Za-z0-9._:-]+$ ]] || return 1
	printf '%s://%s' "$scheme" "$s"
}

# Asks for the controller address until it answers over HTTP(S). No token
# is sent yet; any HTTP response means the address is right.
connect_controller() {
	local addr=${SW_CONTROLLER:-} attempt
	for attempt in 1 2 3; do
		[[ -n $addr ]] || prompt addr "SERVERware controller (IP, DNS name or URL)"
		if ! SW_BASE=$(normalize_controller "$addr"); then
			err "'$addr' is not a valid IP address, DNS name or URL"
			addr=""
			continue
		fi
		sw_call GET /api/networks/1/hosts
		# http:// given, but the controller redirects to HTTPS or only
		# answers HTTPS: use https instead.
		if [[ $HTTP_CODE =~ ^(000|30[1278])$ && $SW_BASE == http://* ]]; then
			SW_BASE="https://${SW_BASE#http://}"
			sw_call GET /api/networks/1/hosts
		fi
		if [[ $HTTP_CODE != 000 ]]; then
			ok "controller $SW_BASE is reachable"
			return 0
		fi
		err "cannot reach $SW_BASE: $(tail -n1 "$WORK/curl.err")"
		addr=""
	done
	die "the SERVERware controller could not be reached"
}

# Asks for the SERVERware API token until the hosts list can be read.
check_sw_token() {
	local token=${SW_TOKEN:-} attempt
	for attempt in 1 2 3; do
		[[ -n $token ]] || prompt token "SERVERware API key" secret
		if [[ -z $token ]]; then
			continue
		fi
		write_curl_config "$WORK/sw.cfg" "SW-API-Token: $token"
		sw_call GET /api/networks/1/hosts
		case $HTTP_CODE in
		200)
			if jq -e '.data | type == "array"' "$WORK/resp" >/dev/null 2>&1; then
				cp "$WORK/resp" "$WORK/hosts.json"
				ok "SERVERware API key is valid"
				return 0
			fi
			die "unexpected answer from the controller for the hosts list"
			;;
		401 | 403) err "the SERVERware API key was rejected (it must be an admin API token)" ;;
		000) die "lost the connection to the controller: $(tail -n1 "$WORK/curl.err")" ;;
		*) die "reading the SERVERware hosts failed: $(sw_error)" ;;
		esac
		token=""
	done
	die "no valid SERVERware API key"
}

# Asks for the DT Collector upload key until /api/v1/ping accepts it.
check_dt_key() {
	local key=${DT_KEY:-} attempt
	for attempt in 1 2 3; do
		[[ -n $key ]] || prompt key "DT Collector upload key" secret
		if [[ -z $key ]]; then
			continue
		fi
		write_curl_config "$WORK/dt.cfg" "Authorization: Bearer $key"
		HTTP_CODE=$(curl -sS -K "$WORK/dt.cfg" -o "$WORK/resp" -w '%{http_code}' \
			--connect-timeout 15 --max-time 60 "$DT_URL/api/v1/ping" 2>"$WORK/curl.err") || HTTP_CODE=000
		case $HTTP_CODE in
		200)
			ok "DT Collector upload key is valid"
			return 0
			;;
		401 | 403) err "DT Collector rejected the upload key (invalid or revoked)" ;;
		000) die "cannot reach DT Collector at $DT_URL: $(tail -n1 "$WORK/curl.err")" ;;
		*) die "DT Collector key check failed (HTTP $HTTP_CODE)" ;;
		esac
		key=""
	done
	die "no valid DT Collector upload key"
}

# Picks the hosts to report, one report each:
#   standalone  the only host
#   mirror      the only host; its active (primary) node is picked in find_node
#   cluster     every host, the primary (STORAGE) host first
# --host limits it to that one host.
select_hosts() {
	local count name
	count=$(jq '.data | length' "$WORK/hosts.json")
	((count > 0)) || die "SERVERware reports no hosts"
	EDITION=$(jq -r '.data | if length > 1 then "cluster"
		elif length == 1 and ((.[0].mirror_id // 0) > 0) then "mirror"
		else "standalone" end' "$WORK/hosts.json")

	HOSTS=()
	if [[ -n $HOST_ONLY ]]; then
		jq -e --arg n "$HOST_ONLY" 'any(.data[]; .name == $n)' "$WORK/hosts.json" >/dev/null ||
			die "no host named '$HOST_ONLY' (hosts: $(jq -r '[.data[].name] | join(", ")' "$WORK/hosts.json"))"
		HOSTS=("$HOST_ONLY")
	else
		while IFS= read -r name; do
			[[ -n $name ]] && HOSTS+=("$name")
		done < <(jq -r '.data | sort_by(if .purpose == "STORAGE" then 0 else 1 end, .id // 0)[] | .name // ""' "$WORK/hosts.json")
	fi
	((${#HOSTS[@]} > 0)) || die "SERVERware reports no host names"

	if ((${#HOSTS[@]} == 1)); then
		ok "SERVERware ${EDITION}: reporting host ${HOSTS[0]}"
	else
		ok "SERVERware ${EDITION}: reporting ${#HOSTS[@]} hosts, one report each:"
		jq -r '.data | sort_by(if .purpose == "STORAGE" then 0 else 1 end, .id // 0)[]
			| "       \(.name)  (\((.purpose // "unknown") | ascii_downcase))"' "$WORK/hosts.json" >&2
	fi
}

# Turns observability on when it's off (it runs the SRW exporter, the only
# source of the SERVERware version) and remembers to turn it off again.
enable_observability() {
	local enabled waited=0
	sw_call GET /api/system-settings/observability
	[[ $HTTP_CODE == 200 ]] || die "reading the Observability setting failed: $(sw_error)"
	enabled=$(jq -r '.data.observability.enabled // false' "$WORK/resp")
	if [[ $enabled == true ]]; then
		ok "Observability is already enabled"
		return 0
	fi

	info "Observability is disabled. Enabling it while collecting (it is disabled again afterwards)."
	sw_call POST /api/system-settings '{"observability":{"enabled":true}}'
	[[ $HTTP_CODE == 200 ]] || die "enabling Observability failed: $(sw_error)"
	OBS_CHANGED=1
	ok "Observability enabled"

	info "waiting for the SRW exporter to start (up to $((OBS_WAIT_S / 60)) minutes)"
	until srw_exporter_up; do
		if ((waited >= OBS_WAIT_S)); then
			warn "the SRW exporter did not start in time, the SERVERware version is reported as unknown"
			return 0
		fi
		sleep "$POLL_S"
		((waited += POLL_S))
	done
	ok "SRW exporter is up"
}

restore_observability() {
	((OBS_CHANGED)) || return 0
	OBS_CHANGED=0
	step "Restoring Observability"
	sw_call POST /api/system-settings '{"observability":{"enabled":false}}'
	if [[ $HTTP_CODE == 200 ]]; then
		ok "Observability disabled again"
	else
		warn "could not disable Observability ($(sw_error)). Disable it manually in SERVERware: System Settings > Observability."
	fi
}

# Finds the node exporter instance of host HOST_NAME. A Mirror pair "Echo"
# has instances "Echo-1" and "Echo-2"; only the active node's replication
# exporter (port 9163) is up. Instances belonging to another host with a
# longer name (a cluster with "Echo" and "Echo-2") are left out.
find_node() {
	local result
	prom_targets || {
		err "reading the Prometheus targets failed: $(sw_error)"
		return 1
	}
	result=$(jq -r --arg h "$HOST_NAME" --slurpfile hosts "$WORK/hosts.json" '
		def mine($n): . == $n or startswith($n + "-");
		[$hosts[0].data[].name // "" | select(length > ($h | length) and mine($h))] as $longer
		| [.data.activeTargets[]?
		 | {i: (.labels.instance // ""), h: (.health // ""),
		    p: ((.scrapeUrl // "") | (capture("^[^/]+//[^/]*:(?<p>[0-9]+)") // {p: ""}).p)}
		 | select((.i | mine($h)) and (.i as $i | any($longer[]; . as $o | $i | mine($o)) | not))] as $t
		| ([$t[] | select(.p == "9100" and .h == "up") | .i] | unique) as $nodes
		| [$t[] | select(.p == "9163" and .h == "up") | .i] as $repl
		| if ($nodes | length) == 1 then "OK \($nodes[0])"
		  elif ($nodes | length) > 1 then
		    ([$nodes[] | select(. as $n | any($repl[]; . == $n))] | .[0]) as $a
		    | if $a then "OK \($a)" else "MULTI \($nodes | join(", "))" end
		  else "NONE" end' "$WORK/targets.json")
	case $result in
	OK\ *) NODE=${result#OK } ;;
	MULTI\ *)
		err "host ${HOST_NAME} has several nodes (${result#MULTI }) and none can be identified as the active one"
		return 1
		;;
	*)
		err "Prometheus has no node exporter for host ${HOST_NAME}"
		return 1
		;;
	esac
}

collect_hardware() {
	local sel n
	n=${NODE//\\/\\\\}
	n=${n//\"/\\\"}
	sel="{instance=\"$n\"}"

	prom threads "count(node_cpu_seconds_total{mode=\"idle\",instance=\"$n\"})" || {
		err "querying Prometheus failed: $(sw_error)"
		return 1
	}
	prom sockets "count(count by (package) (node_cpu_core_throttles_total$sel))"
	prom cores "count(count by (package, core) (node_cpu_core_throttles_total$sel))"
	prom maxhz "max(node_cpu_frequency_max_hertz$sel)"
	prom mem "node_memory_MemTotal_bytes$sel"
	prom dmi "node_dmi_info$sel"
	prom bonds "node_bonding_slaves$sel"
	prom nvme "node_nvme_info$sel"
	prom disks "node_disk_info$sel"
	prom net "node_network_speed_bytes$sel"
	prom srw "srw_info"
	return 0
}

# new_uuid: a random UUID v4, the report_id.
new_uuid() {
	local h
	if [[ -r /proc/sys/kernel/random/uuid ]]; then
		tr -d '\n' </proc/sys/kernel/random/uuid
		return
	fi
	h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	printf '%s-%s-4%s-%x%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" \
		$(((16#${h:16:1} & 3) | 8)) "${h:17:3}" "${h:20:12}"
}

# Builds the report (DT Collector's hardware-only format, schema 1) from
# the collected data. Only the labels named below are read; serial numbers,
# asset tags and UUIDs in node_dmi_info are ignored.
build_report() {
	local report_id=$1 out=$2 created
	created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -n \
		--arg id "$report_id" --arg created "$created" --arg edition "$EDITION" \
		--arg src_name "$SOURCE_NAME" --arg src_version "$SWHW_VERSION" \
		--slurpfile host "$WORK/host.json" \
		--slurpfile threads "$WORK/p_threads.json" --slurpfile sockets "$WORK/p_sockets.json" \
		--slurpfile cores "$WORK/p_cores.json" --slurpfile maxhz "$WORK/p_maxhz.json" \
		--slurpfile mem "$WORK/p_mem.json" --slurpfile dmi "$WORK/p_dmi.json" \
		--slurpfile bonds "$WORK/p_bonds.json" --slurpfile nvme "$WORK/p_nvme.json" \
		--slurpfile disks "$WORK/p_disks.json" --slurpfile net "$WORK/p_net.json" \
		--slurpfile srw "$WORK/p_srw.json" '
	def val: (.value[1] // "0") | (tonumber? // 0) | if isnan then 0 else . end;
	def num: if length > 0 then (.[0] | val) else 0 end;
	def trimws: sub("^\\s+"; "") | sub("\\s+$"; "");
	def clean: (. // "") | if ascii_downcase | contains("to be filled") then "" else trimws end;
	def idx(f): [range(0; length) as $k | select(.[$k] | f) | $k][0];
	def nonempty: with_entries(select(.value != ""));

	$host[0] as $h
	| ($h.platform_details // {}) as $pd
	| ($threads[0] | num | floor) as $cpu_threads
	| ($cores[0] | num | floor) as $cpu_cores
	| ($dmi[0][0].metric // {}) as $d
	| [$nvme[0][] | .metric.device // ""] as $nvme_devs
	| (reduce ($net[0][] | select(val > 0)) as $x ({}; .[$x.metric.device // ""] = ($x | val * 8 / 1e6 | floor))) as $speed

	| ($srw[0][0].metric.version // "") as $v
	| (if $v == "" then "unknown" elif ($v | test("^[^+-]+[+-]")) then ($v | sub("[+-].*$"; "")) else $v end) as $sw_version

	| {
		cpu_model: ($pd.cpu_model // "" | trimws),
		cpu_sockets: ($sockets[0] | num | floor),
		cpu_cores: (if $cpu_cores > 0 then $cpu_cores else $cpu_threads end),
		cpu_threads: $cpu_threads,
		cpu_max_mhz: ($maxhz[0] | num / 1e6 | floor),
		memory_bytes: ($mem[0] | num | floor)
	  }
	+ ({system_vendor: ($d.system_vendor | clean), system_model: ($d.product_name | clean)} | nonempty)
	+ {
		disks: [$disks[0] | sort_by(.metric.device // "")[]
			| (.metric.device // "") as $dev
			| (.metric.model // "" | gsub("_"; " ")) as $model
			| select($model != "" and $model != "Linux"
				and ($dev | startswith("zd") or startswith("dm-") or startswith("loop") | not))
			| ($model | ascii_upcase) as $up
			| {model: $model, size_bytes: 0,
			   type: (if ($dev | startswith("nvme")) or any($nvme_devs[]; . == $dev) then "nvme"
				  elif ($up | contains("SSD")) or ($up | startswith("SAMSUNG MZ")) then "ssd"
				  else "unknown" end)}],
		network: [$net[0] | sort_by(.metric.device // "")[]
			| (.metric.device // "") as $dev
			| select(($dev | startswith("en") or startswith("eth")) and val > 0)
			| {speed_mbps: (val * 8 / 1e6 | floor)}],
		storage_controllers: (reduce ($pd.storage_ctrls // [])[] as $c ([];
			($c.vendor // "" | trimws) as $vendor | ($c.product // "" | trimws) as $product
			| if $product == "" or ($vendor == "" and $product == "Linux") then .
			  else idx(.vendor == $vendor and .product == $product) as $i
			  | if $i == null then . + [{vendor: $vendor, product: $product, count: 1}]
			    else .[$i].count += 1 end
			  end)),
		nics: (reduce ($pd.network_cards // [])[] as $c ([];
			($c.vendor // "" | trimws) as $vendor | ($c.product // "" | trimws) as $product
			| ($c.driver // "") as $driver | ($speed[$c.name // ""] // 0) as $mbps
			| if $product == "" then .
			  else idx(.vendor == $vendor and .product == $product and .driver == $driver) as $i
			  | if $i == null then . + [{vendor: $vendor, product: $product, driver: $driver, count: 1, speed_mbps: $mbps}]
			    else .[$i].count += 1 | .[$i].speed_mbps = ([.[$i].speed_mbps, $mbps] | max) end
			  end)),
		bonds: [$bonds[0][] | select(val > 0) | {ports: (val | floor)}]
	  }
	+ ({vendor: ($d.board_vendor | clean), model: ($d.board_name | clean), version: ($d.board_version | clean),
	    bios_vendor: ($d.bios_vendor | clean), bios_version: ($d.bios_version | clean), bios_date: ($d.bios_date | clean)}
	   | if .vendor != "" or .model != "" then {motherboard: ({vendor, model} + (del(.vendor, .model) | nonempty))} else {} end)
	| . as $hw
	| {
		schema_version: 1,
		report_id: $id,
		created_at: $created,
		source: {name: $src_name, version: $src_version},
		profile: {name: "hardware", version: 1},
		environment: {
			serverware: {version: $sw_version, edition: $edition},
			host: $hw,
			vps: {},
			pbxware: []
		},
		tests: []
	  }' >"$out"
}

print_summary() {
	jq -r '.environment as $e | $e.host as $h
		| "    SERVERware:  \($e.serverware.version) (\($e.serverware.edition))",
		  "    CPU:         \($h.cpu_model)",
		  "                 \($h.cpu_sockets) socket(s), \($h.cpu_cores) cores, \($h.cpu_threads) threads, \($h.cpu_max_mhz) MHz max",
		  "    Memory:      \(($h.memory_bytes / 1073741824 * 10 | round) / 10) GiB",
		  (if $h.system_vendor or $h.system_model then "    System:      \([$h.system_vendor, $h.system_model] | map(select(.)) | join(" "))" else empty end),
		  (if $h.motherboard then "    Motherboard: \($h.motherboard.vendor) \($h.motherboard.model)" else empty end),
		  "    Disks:       \($h.disks | length)",
		  "    Storage:     \($h.storage_controllers | map("\(.count) x \(.vendor) \(.product)") | join("; ") | if . == "" then "none reported" else . end)",
		  "    NICs:        \($h.nics | map("\(.count) x \(.vendor) \(.product) (\(.speed_mbps) Mbit/s)") | join("; ") | if . == "" then "none reported" else . end)"' \
		"$1" >&2
}

# upload_report FILE HOST: uploads one report, retrying network errors and 5xx
# answers. Retries reuse the same report_id, which DT Collector
# deduplicates. Returns 1 when this report failed; a rejected key stops
# the script.
upload_report() {
	local file=$1 attempt delay=2
	local args=(-sS -K "$WORK/dt.cfg" -X POST -H 'Content-Type: application/json'
		-o "$WORK/resp" -w '%{http_code}' --connect-timeout 15 --max-time 120)
	if command -v gzip >/dev/null 2>&1; then
		gzip -c "$1" >"$1.gz"
		file="$1.gz"
		args+=(-H 'Content-Encoding: gzip')
	fi
	for attempt in 1 2 3 4; do
		HTTP_CODE=$(curl "${args[@]}" --data-binary "@$file" "$DT_URL/api/v1/reports" 2>"$WORK/curl.err") || HTTP_CODE=000
		case $HTTP_CODE in
		201)
			ok "$2: report uploaded"
			return 0
			;;
		200)
			ok "$2: report was already stored"
			return 0
			;;
		400)
			err "$2: DT Collector rejected the report: $(jq -r '.error // empty' "$WORK/resp" 2>/dev/null)"
			return 1
			;;
		401 | 403) die "DT Collector rejected the upload key" ;;
		413)
			err "$2: the report is too large for DT Collector"
			return 1
			;;
		esac
		if ((attempt < 4)); then
			if [[ $HTTP_CODE == 000 ]]; then
				warn "upload failed ($(tail -n1 "$WORK/curl.err")), retrying in ${delay}s"
			else
				warn "upload failed (HTTP $HTTP_CODE), retrying in ${delay}s"
			fi
			sleep "$delay"
			((delay *= 2))
		fi
	done
	err "$2: uploading the report failed (HTTP $HTTP_CODE)"
	return 1
}

# collect_host NAME OUT: collects one host's hardware into report file OUT.
# Returns 1 (after printing why) when the host can't be reported.
collect_host() {
	HOST_NAME=$1
	jq --arg n "$HOST_NAME" 'first(.data[] | select(.name == $n))' "$WORK/hosts.json" >"$WORK/host.json"
	find_node || return 1
	collect_hardware || return 1
	build_report "$(new_uuid)" "$2" || {
		err "building the report for host ${HOST_NAME} failed"
		return 1
	}
	if [[ -z $(jq -r '.environment.host.cpu_model' "$2") ]]; then
		err "SERVERware reports no CPU model for host ${HOST_NAME}; it is not reported"
		return 1
	fi
	if [[ $(jq -r '.environment.host.cpu_threads' "$2") == 0 ]]; then
		err "Prometheus has no CPU metrics for host ${HOST_NAME}; it is not reported"
		return 1
	fi
	ok "hardware details collected"
	print_summary "$2"
}

# --- main -----------------------------------------------------------------

main() {
	local dry_run=0 i n file id
	local reports=() report_hosts=() failed=() uploaded=()
	HOST_ONLY=""
	HOST_NAME=""
	HOSTS=()
	DT_URL=${DT_URL:-$DT_URL_DEFAULT}
	SW_BASE=""
	EDITION=""
	NODE=""

	while (($#)); do
		case $1 in
		--controller)
			[[ $# -ge 2 ]] || die "--controller needs a value"
			SW_CONTROLLER=$2
			shift
			;;
		--controller=*) SW_CONTROLLER=${1#*=} ;;
		--host)
			[[ $# -ge 2 ]] || die "--host needs a value"
			HOST_ONLY=$2
			shift
			;;
		--host=*) HOST_ONLY=${1#*=} ;;
		--dt-url)
			[[ $# -ge 2 ]] || die "--dt-url needs a value"
			DT_URL=$2
			shift
			;;
		--dt-url=*) DT_URL=${1#*=} ;;
		--dry-run) dry_run=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			echo "swhw ${SWHW_VERSION}"
			exit 0
			;;
		*) die "unknown option '$1' (see --help)" ;;
		esac
		shift
	done
	DT_URL=${DT_URL%/}
	[[ $DT_URL == https://* ]] || die "the DT Collector address must start with https://"

	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/swhw.XXXXXX") || die "cannot create a temporary directory"
	chmod 700 "$WORK"

	printf '%sswhw %s%s: SERVERware hardware report for DT Collector\n\n' "$C_BOLD" "$SWHW_VERSION" "$C_RESET" >&2
	check_deps

	step "SERVERware controller"
	connect_controller
	check_sw_token

	if ((dry_run)); then
		info "dry run: the report is printed, not uploaded"
	else
		step "DT Collector"
		check_dt_key
	fi

	step "Hosts"
	select_hosts

	step "Observability"
	enable_observability

	n=${#HOSTS[@]}
	for ((i = 0; i < n; i++)); do
		if ((n > 1)); then
			step "Collecting hardware details: ${HOSTS[i]} ($((i + 1))/${n})"
		else
			step "Collecting hardware details"
		fi
		file="$WORK/report-$((i + 1)).json"
		if collect_host "${HOSTS[i]}" "$file"; then
			reports+=("$file")
			report_hosts+=("${HOSTS[i]}")
		else
			failed+=("${HOSTS[i]}")
		fi
	done

	# Collection is done: put Observability back before uploading.
	restore_observability

	((${#reports[@]} > 0)) || die "no host could be reported, nothing was uploaded"

	if ((dry_run)); then
		for file in "${reports[@]}"; do
			cat "$file"
		done
		step "Dry run finished, nothing was uploaded"
		if ((${#failed[@]} > 0)); then
			warn "not reported: ${failed[*]}"
			return 1
		fi
		return 0
	fi

	step "Uploading to DT Collector"
	for ((i = 0; i < ${#reports[@]}; i++)); do
		id=$(jq -r '.report_id' "${reports[i]}")
		if upload_report "${reports[i]}" "${report_hosts[i]}"; then
			uploaded+=("${report_hosts[i]}: $id")
		else
			failed+=("${report_hosts[i]}")
		fi
	done

	printf '\n' >&2
	if ((${#uploaded[@]} > 0)); then
		printf '%sSuccess:%s %d hardware report(s) uploaded to %s\n' "$C_GREEN" "$C_RESET" "${#uploaded[@]}" "$DT_URL" >&2
		printf '    %s\n' "${uploaded[@]}" >&2
	fi
	if ((${#failed[@]} > 0)); then
		warn "not reported: ${failed[*]}"
		return 1
	fi
	return 0
}

main "$@"
