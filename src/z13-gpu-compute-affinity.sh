#!/bin/bash
# Confine ROCm/HIP compute processes to CPUs 16-31, keeping 0-15 for UI/input.
#
# /dev/kfd (Kernel Fusion Driver) is opened exclusively by ROCm/HIP compute
# workloads: ollama, InvokeAI, PyTorch, JAX, etc.  Display and UI processes
# use /dev/dri/renderD* for Vulkan but never touch /dev/kfd.  Using /dev/kfd
# as the discriminator means we only touch real compute processes and never
# need to maintain an exclusion list of UI apps.
#
# Called by z13-gpu-compute-affinity.timer every few seconds.

COMPUTE_CPUS="16-31"

kmsg() { echo "z13-gpu-affinity: $*" | tee /dev/kmsg 2>/dev/null || true; }

for pid in $(fuser /dev/kfd 2>/dev/null | tr ' ' '\n' | sort -u); do
    comm=$(ps -p "$pid" -o comm= 2>/dev/null) || continue

    # Skip if all threads are already on 16-31
    if ! ps -eLo psr,pid 2>/dev/null | awk -v p="$pid" '
            $2==p && $1+0 < 16 { found=1; exit }
            END { exit !found }'; then
        continue
    fi

    confined=0
    for tid in $(ls /proc/"$pid"/task/ 2>/dev/null); do
        taskset -cp "$COMPUTE_CPUS" "$tid" >/dev/null 2>&1 && ((confined++))
    done
    [ "$confined" -gt 0 ] && kmsg "confined PID $pid ($comm) $confined threads to CPUs $COMPUTE_CPUS"
done
