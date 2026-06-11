#!/usr/bin/env bash
# Hold the CPU PM QoS latency limit at 0 (forbids deep C-states) for as long
# as this process lives. The kernel drops the request automatically when the
# fd closes, i.e. when this unit is stopped or dies — no cleanup needed.
#
# Why: see hibernate-hook.sh. After an S4 image restore, reschedule IPIs to
# some CPUs are lost (pstore dumps 2026-06-11); CPUs in deep ACPI io_idle
# sleep through stop_machine and the restore deadlocks. CPUs limited to
# C1/mwait wake via the monitored need-resched flag without an IPI.
exec 3<> /dev/cpu_dma_latency
printf '0' >&3
exec sleep infinity
