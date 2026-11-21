#!/bin/sh
# Publish this node's terminal snapshot for peer nodes and cache theirs.
# Peers exchange the full get_all_users payload; the LuCI controller merges them.

CONF="fwx_sync"
TOKEN=$(uci -q get $CONF.sync.token)
PORT=$(uci -q get $CONF.sync.port)
INTERVAL=$(uci -q get $CONF.sync.interval)
ENABLE=$(uci -q get $CONF.sync.enable)

[ "$ENABLE" = "1" ] || exit 0
[ -n "$TOKEN" ] || exit 0
[ -n "$PORT" ] || PORT=8787
[ -n "$INTERVAL" ] || INTERVAL=5

DOCROOT="/tmp/fwx_sync"
PEERDIR="/tmp/fwx_peer"
PUBDIR="$DOCROOT/$TOKEN"
BIND_FILE="/etc/fwx_ap_bind.json"
BIND_ENFORCER="/usr/bin/fwx_ap_bind.lua"

mkdir -p "$PUBDIR" "$PEERDIR"

own_ip() {
	local ip
	ip=$(uci -q get network.lan.ipaddr)
	case "$ip" in
		""|*[!0-9.]*) ip=$(ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}') ;;
	esac
	echo "$ip"
}

SELF_IP=$(own_ip)

write_snapshot() {
	ubus call fwx common '{"api":"get_all_users","data":{"flag":3}}' > "$PUBDIR/snapshot.json.tmp" 2>/dev/null || return 1
	[ -s "$PUBDIR/snapshot.json.tmp" ] || return 1
	mv -f "$PUBDIR/snapshot.json.tmp" "$PUBDIR/snapshot.json"
}

fetch_peer() {
	local peer="$1"
	[ -n "$peer" ] || return 0
	[ "$peer" = "$SELF_IP" ] && return 0
	curl -fsS --max-time 3 "http://$peer:$PORT/$TOKEN/snapshot.json" -o "$PEERDIR/$peer.json.tmp" 2>/dev/null || return 1
	[ -s "$PEERDIR/$peer.json.tmp" ] || return 1
	mv -f "$PEERDIR/$peer.json.tmp" "$PEERDIR/$peer.json"
}

write_bindings() {
	[ -f "$BIND_FILE" ] || return 0
	cp -f "$BIND_FILE" "$PUBDIR/bindings.json.tmp" 2>/dev/null || return 1
	mv -f "$PUBDIR/bindings.json.tmp" "$PUBDIR/bindings.json"
}

fetch_peer_bindings() {
	local peer="$1"
	[ -n "$peer" ] || return 0
	[ "$peer" = "$SELF_IP" ] && return 0
	curl -fsS --max-time 3 "http://$peer:$PORT/$TOKEN/bindings.json" -o "$PEERDIR/$peer.bindings.json.tmp" 2>/dev/null || return 1
	[ -s "$PEERDIR/$peer.bindings.json.tmp" ] || return 1
	mv -f "$PEERDIR/$peer.bindings.json.tmp" "$PEERDIR/$peer.bindings.json"
}

enforce_bindings() {
	[ -f "$BIND_ENFORCER" ] || return 0
	lua "$BIND_ENFORCER" >/dev/null 2>&1
}

while true; do
	write_snapshot
	write_bindings
	for peer in $(uci -q get $CONF.sync.peers); do
		fetch_peer "$peer"
		fetch_peer_bindings "$peer"
	done
	enforce_bindings
	sleep "$INTERVAL"
done
