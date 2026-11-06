#!/usr/bin/env bash
# Status line for dwlb: prints one line per second on stdout.
# CPU/RAM come from /proc, disk from stat(1), no X11 needed.
set -uo pipefail

ic_cpu=''
ic_ram=''
ic_disk=''
ic_net='󰩟'
ic_key=''
ic_time=''

# --- cpu: busy delta over total delta across one interval -------------------
read -r _ cu cn cs ci cw cirq csirq _rest < /proc/stat || true
prev_idle=$((ci + cw))
prev_total=$((cu + cn + cs + ci + cw + cirq + csirq))
last_cpu=0

cpu_perc() {
	local u n s i w irq sirq rest idle total dt di
	read -r _ u n s i w irq sirq rest < /proc/stat || true
	idle=$((i + w))
	total=$((u + n + s + i + w + irq + sirq))
	dt=$((total - prev_total))
	di=$((idle - prev_idle))
	prev_total=$total
	prev_idle=$idle
	if [ "$dt" -gt 0 ]; then
		last_cpu=$((100 * (dt - di) / dt))
	fi
	printf '%s' "$last_cpu"
}

# --- ram: 100*(total-free-buffers-cached-sreclaimable+shmem)/total ------------
ram_perc() {
	awk '
		/^MemTotal:/     { t = $2 }
		/^MemFree:/      { f = $2 }
		/^Buffers:/      { b = $2 }
		/^Cached:/       { c = $2 }
		/^Shmem:/        { s = $2 }
		/^SReclaimable:/ { r = $2 }
		END { if (t > 0) printf "%d", 100 * (t - f - b - c - r + s) / t; else printf "0" }
	' /proc/meminfo
}

# --- disk: 100*(1 - bavail/blocks) for / ------------------------------------
disk_perc() {
	local avail blocks
	read -r avail blocks < <(stat -f -c '%a %b' / 2>/dev/null) || true
	if [ "${blocks:-0}" -gt 0 ]; then
		printf '%s' $((100 * (blocks - avail) / blocks))
	else
		printf '0'
	fi
}

# --- ipv4: interface taken from the default route, never hardcoded ----------
ipv4() {
	local iface ip
	iface=$(ip -4 route show default 2>/dev/null \
		| awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
	[ -n "$iface" ] || return 0
	ip=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
		| awk '{ sub(/\/.*/, "", $4); print $4; exit }')
	printf '%s' "$ip"
}

# --- keymap: XWayland first, then localectl (no X server required) -----------
keymap() {
	local k
	k=$(setxkbmap -query 2>/dev/null | awk '/^layout:/{ print $2; exit }')
	[ -n "$k" ] || k=$(localectl status 2>/dev/null | awk '/X11 Layout:/{ print $3; exit }')
	printf '%s' "${k:-none}"
}

i=0
kmap=$(keymap)
while :; do
	if [ $((i % 10)) -eq 0 ]; then kmap=$(keymap); fi

	ip=$(ipv4)
	[ -n "$ip" ] || ip=-
	dt=$(date '+%F %T')

	printf '%s\n' \
		"[ ${ic_cpu} $(cpu_perc)% ] [ ${ic_ram} $(ram_perc)% ] [ ${ic_disk} $(disk_perc)% ][ ${ic_net} ${ip} ] [ ${ic_key} ${kmap} ] [ ${ic_time} ${dt} ]"

	i=$((i + 1))
	sleep "${INTERVAL:-1}"
done
