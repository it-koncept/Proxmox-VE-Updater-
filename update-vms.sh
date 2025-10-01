#!/bin/bash

VM_LIST=$(pvesh get /cluster/resources --type vm --output-format json | jq -c '.[] | select(.node=="'$(hostname)'")')

for VM in $VM_LIST; do
    VMID=$(echo $VM | jq -r '.vmid')
    TYPE=$(echo $VM | jq -r '.type')
    STATUS=$(echo $VM | jq -r '.status')
    TAGS=$(echo $VM | jq -r '.tags')

    if [[ "$STATUS" != "running" ]]; then
        echo "⚪ Skipping $VMID ($TYPE) - status $STATUS"
        continue
    fi

    if [[ "$TAGS" == *"windows"* ]]; then
        echo "🟦 Skipping $VMID ($TYPE) - tag: windows"
        continue
    fi

    echo "▶ Processing $VMID ($TYPE) with tags: $TAGS"

    if [[ "$TYPE" == "lxc" ]]; then
        if [[ "$TAGS" == *"yum"* ]]; then
            echo "   → pct yum update"
            pct exec $VMID -- bash -c "yum -y update" 2>&1
        elif [[ "$TAGS" == *"apt"* ]]; then
            echo "   → pct apt update/upgrade"
            pct exec $VMID -- bash -c "apt -qq -y update" 2>&1
            pct exec $VMID -- bash -c "apt -qq -y upgrade" 2>&1
        else
            echo "   ⚠ No recognized tag (yum/apt), skipping"
        fi
    fi

    if [[ "$TYPE" == "qemu" ]]; then
        if [[ "$TAGS" == *"yum"* ]]; then
            echo "   → qm yum update"
            qm guest exec $VMID -- bash -c "yum -y update" 2>&1
        elif [[ "$TAGS" == *"apt"* ]]; then
            echo "   → qm apt update/upgrade"
            qm guest exec $VMID -- bash -c "apt -qq -y update" 2>&1
            qm guest exec $VMID -- bash -c "apt -qq -y upgrade" 2>&1
        else
            echo "   ⚠ No recognized tag (yum/apt), skipping"
        fi
    fi
done
