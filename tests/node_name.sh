#!/usr/bin/env bash
# Parse Sparkplug node names: C=Core N=Node SDU DAC=PCS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok  $*" ; }

expect() {
  local name="$1" array="$2" core="$3" node="$4" kind="$5" unit="$6"
  parse_node_name "$name"
  [[ "$NN_ARRAY" == "$array" ]] || fail "$name ARRAY got '$NN_ARRAY' want '$array'"
  [[ "$NN_CORE" == "$core" ]] || fail "$name CORE got '$NN_CORE' want '$core'"
  [[ "$NN_NODE" == "$node" ]] || fail "$name NODE got '$NN_NODE' want '$node'"
  [[ "$NN_KIND" == "$kind" ]] || fail "$name KIND got '$NN_KIND' want '$kind'"
  [[ "$NN_UNIT" == "$unit" ]] || fail "$name UNIT got '$NN_UNIT' want '$unit'"
}

expect "A_C001_N001_SDU" A 1 1 nodesdu SDU
expect "A_C001_N001_DAC01" A 1 1 dac DAC1
expect "A_C024_N002_SDU" A 24 2 nodesdu SDU
expect "A_C001_SDU" A 1 "" coresdu SDU
expect "A_SDU" A "" "" arraysdu SDU
expect "A_MDU" A "" "" mdu MDU
expect "A_OCTE001" A "" "" octe OCTE1
expect "A" A "" "" array A
expect "flnc1014" "" "" "" other ""
pass "structure tokens parse"

[[ "$(role_label dac)" == "DAC/PCS" ]] || fail "DAC label"
[[ "$(role_label coresdu)" == "CORE SDU" ]] || fail "CORE SDU label"
[[ "$(role_label nodesdu)" == "NODE SDU" ]] || fail "NODE SDU label"
[[ "$(role_label sdu)" == "SDU" ]] || fail "SDU label"
pass "role labels"

EDGE_SEEN["flnc1014/A_C002_N001_DAC01"]=1
EDGE_SEEN["flnc1014/A_C001_SDU"]=1
EDGE_SEEN["flnc1014/A_SDU"]=1
EDGE_SEEN["flnc1014/A_C001_N001_SDU"]=1
EDGE_MSGS["flnc1014/A_C002_N001_DAC01"]=1
EDGE_MSGS["flnc1014/A_C001_SDU"]=1
EDGE_MSGS["flnc1014/A_SDU"]=1
EDGE_MSGS["flnc1014/A_C001_N001_SDU"]=1
list_edge_nodes
[[ "${EDGE_NODES[0]}" == "flnc1014/A_SDU" ]] || fail "sort array SDU first got ${EDGE_NODES[0]}"
[[ "${EDGE_NODES[1]}" == "flnc1014/A_C001_SDU" ]] || fail "sort core SDU got ${EDGE_NODES[1]}"
[[ "${EDGE_NODES[2]}" == "flnc1014/A_C001_N001_SDU" ]] || fail "sort node SDU got ${EDGE_NODES[2]}"
[[ "${EDGE_NODES[3]}" == "flnc1014/A_C002_N001_DAC01" ]] || fail "sort core2 DAC got ${EDGE_NODES[3]}"
pass "edge nodes sort by array/core/node"

echo "ALL PASS"
