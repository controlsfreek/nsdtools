#!/usr/bin/env bash
# Simulated mixed fleet: Core SDUs, DAC/PCS (M10), BMS (filtered from M10 HMI).

load_demo() {
  local now="$1"
  local fleet=(
    "flnc1014/A_SDU|flnc1014|A_SDU||sdu|0.00"
    "flnc1014/A_C001_SDU|flnc1014|A_C001_SDU||sdu|0.00"
    "flnc1014/A_C001_N001_SDU|flnc1014|A_C001_N001_SDU||sdu|0.00"
    "flnc1014/A_C001_N001_DAC01|flnc1014|A_C001_N001_DAC01|PCS-A|m10|0.00"
    "flnc1014/A_C002_N001_DAC01|flnc1014|A_C002_N001_DAC01|PCS-B|m10|0.03"
    "Fluence/EDGE-02/PCS-C|Fluence|EDGE-02|PCS-C|m10|-0.02"
    "Fluence/BMS-1|Fluence|BMS-1||bms|0.00"
  )
  local entry key group node device kind bias
  local phase sweep
  for entry in "${fleet[@]}"; do
    IFS='|' read -r key group node device kind bias <<< "$entry"
    record_edge_node "$group" "$node" "$device" "$now"
    ensure_device "$key" "$group" "$node" "$device"
    DEV_ONLINE[$key]=1
    DEV_BORN[$key]=1
    DEV_LAST[$key]="$now"
    DEV_SEQ[$key]=$(( now % 256 ))
    if [[ "$kind" == "sdu" ]]; then
      upsert_metric "$key" "CoreSDU/Status" "OK" "$now"
      upsert_metric "$key" "Core_hb" "$(( now % 10000 ))" "$now"
      classify_device "$key"
      continue
    fi
    if [[ "$kind" == "bms" ]]; then
      upsert_metric "$key" "BankBMS/SOC" "81.0" "$now"
      upsert_metric "$key" "BankBMS/Voltage" "1320.0" "$now"
      classify_device "$key"
      continue
    fi
    phase=$(awk -v n="$now" -v b="$bias" 'BEGIN{printf "%.6f", ((n + b*8) % 8.0) / 8.0}')
    sweep=$(awk -v p="$phase" 'BEGIN{printf "%.6f", 0.04 * (p - 0.5)}')
    upsert_metric "$key" "Properties/Model" "EPC M10" "$now"
    upsert_metric "$key" "inverter01/AC/ActivePower" "$(awk -v s="$sweep" -v b="$bias" 'BEGIN{printf "%.3f", 412.5*(1+s+b)}')" "$now"
    upsert_metric "$key" "inverter01/AC/VoltageAB" "$(awk -v b="$bias" 'BEGIN{printf "%.1f", 480.2+b}')" "$now"
    upsert_metric "$key" "inverter01/AC/VoltageBC" "479.6" "$now"
    upsert_metric "$key" "inverter01/AC/VoltageCA" "480.8" "$now"
    upsert_metric "$key" "inverter01/AC/CurrentA" "$(awk -v s="$sweep" 'BEGIN{printf "%.3f", 498.1*(1+s)}')" "$now"
    upsert_metric "$key" "inverter01/AC/Frequency" "60.012" "$now"
    upsert_metric "$key" "inverter01/DC/Voltage1" "$(awk -v b="$bias" 'BEGIN{printf "%.1f", 1184.0+b*10}')" "$now"
    upsert_metric "$key" "inverter01/DC/Voltage2" "1179.5" "$now"
    upsert_metric "$key" "inverter01/DC/Current1" "$(awk -v s="$sweep" 'BEGIN{printf "%.3f", 178.4*(1+s)}')" "$now"
    upsert_metric "$key" "inverter01/DC/Power" "$(awk -v s="$sweep" -v b="$bias" 'BEGIN{printf "%.3f", 418.0*(1+s+b)}')" "$now"
    upsert_metric "$key" "inverter01/BESS/SOC" "$(awk -v b="$bias" 'BEGIN{printf "%.1f", 67.4+b*20}')" "$now"
    upsert_metric "$key" "inverter01/Thermal/Heatsink" "$(awk -v b="$bias" 'BEGIN{ab=(b<0)?-b:b; printf "%.1f", 41.2+ab*8}')" "$now"
    upsert_metric "$key" "inverter01/Thermal/Cabinet" "32.8" "$now"
    upsert_metric "$key" "inverter01/Status/State" "GRID_FOLLOWING" "$now"
    upsert_metric "$key" "inverter01/Status/Fault" "false" "$now"
    classify_device "$key"
  done
}
