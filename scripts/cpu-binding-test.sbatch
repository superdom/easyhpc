#!/bin/bash
#SBATCH -J cpu-bind-test
#SBATCH -o cpu-bind-test.%j.out
#SBATCH -N 2
#SBATCH -n 4
#SBATCH --ntasks-per-node=2
#SBATCH -c 1
#SBATCH -t 00:02:00

set -euo pipefail

echo "== Host summary"
printf "%-30s %-6s %-14s %-10s\n" "HOST" "CPUS" "ONLINE" "NUMA_NODES"
nodes=${SLURM_JOB_NUM_NODES:-1}
srun --nodes="$nodes" --ntasks="$nodes" --ntasks-per-node=1 bash -c '
  host=$(hostname)
  lscpu | awk -F: -v host="$host" "
    /^CPU\(s\)/ {gsub(/^[ \t]+/, \"\", \$2); cpu=\$2}
    /^On-line CPU\(s\) list/ {gsub(/^[ \t]+/, \"\", \$2); online=\$2}
    /^NUMA node\(s\)/ {gsub(/^[ \t]+/, \"\", \$2); numa=\$2}
    END {printf \"%s\t%s\t%s\t%s\n\", host, cpu, online, numa}
  "
' | sort | awk -F"\t" '{printf "%-30s %-6s %-14s %-10s\n", $1, $2, $3, $4}'

echo
echo "== Binding (per-rank)"
printf "%-30s %-6s %-10s %-10s\n" "HOST" "RANK" "CPUS" "MEMS"
srun --cpus-per-task=1 --cpu-bind=cores bash -c '
  host=$(hostname)
  rank=${SLURM_PROCID}
  cpus=$(awk "/Cpus_allowed_list/ {print \$2}" /proc/$$/status)
  mems=$(awk "/Mems_allowed_list/ {print \$2}" /proc/$$/status)
  printf "%s\t%s\t%s\t%s\n" "$host" "$rank" "$cpus" "$mems"
' | sort -k2,2n -k1,1 | awk -F"\t" '{printf "%-30s %-6s %-10s %-10s\n", $1, $2, $3, $4}'

echo
echo "== Explicit mask test (rank0->CPU0, rank1->CPU1)"
alloc_masks=$(srun --cpus-per-task=1 --cpu-bind=cores bash -c '
  mask=$(awk "/Cpus_allowed_list/ {print \$2}" /proc/$$/status)
  echo "rank=${SLURM_PROCID} host=$(hostname) mask=${mask}"
' | sort -k1,1V)
printf "%-30s %-6s %-10s\n" "HOST" "RANK" "ALLOWED_CPUS"
echo "$alloc_masks" | awk -F'[ =]+' '{printf "%s\t%s\t%s\n", $4, $2, $6}' | awk -F"\t" '{printf "%-30s %-6s %-10s\n", $1, $2, $3}'
echo "Using allocated CPU ids per host for explicit mask test"

printf "%-30s %-6s %-12s %-10s %-10s\n" "HOST" "RANK" "LOCAL_RANK" "CPUS" "MEMS"
srun --cpus-per-task=1 --cpu-bind=none bash -c '
  host=$(hostname)
  rank=${SLURM_PROCID}
  allowed=$(awk "/Cpus_allowed_list/ {print \$2}" /proc/$$/status)

  pick_nth() {
    local list="$1"
    local idx="$2"
    local count=0
    IFS="," read -ra parts <<<"$list"
    for part in "${parts[@]}"; do
      if [[ "$part" == *-* ]]; then
        IFS='-' read -r start end <<<"$part"
        for ((i=start; i<=end; i++)); do
          if [[ $count -eq $idx ]]; then
            echo "$i"
            return 0
          fi
          count=$((count + 1))
        done
      else
        if [[ $count -eq $idx ]]; then
          echo "$part"
          return 0
        fi
        count=$((count + 1))
      fi
    done
    echo ""
  }

  local_rank=${SLURM_LOCALID}
  target=$(pick_nth "$allowed" "$local_rank")
  if [[ -z "$target" ]]; then
    printf "%s\t%s\t%s\t%s\t%s\n" "$host" "$rank" "${SLURM_LOCALID}" "NA" "NA"
    exit 0
  fi

  taskset -pc "$target" $$ >/dev/null
  cpus_now=$(awk "/Cpus_allowed_list/ {print \$2}" /proc/$$/status)
  mems_now=$(awk "/Mems_allowed_list/ {print \$2}" /proc/$$/status)
  printf "%s\t%s\t%s\t%s\t%s\n" "$host" "$rank" "$local_rank" "$cpus_now" "$mems_now"
' | sort -k2,2n -k1,1 | awk -F"\t" '{printf "%-30s %-6s %-12s %-10s %-10s\n", $1, $2, $3, $4, $5}'

echo
echo "== NUMA binding test (local to node)"
printf "%-30s %-6s %-10s %-10s\n" "HOST" "RANK" "CPUS" "MEMS"
srun --cpus-per-task=1 --mem-bind=local --cpu-bind=cores bash -c '
  host=$(hostname)
  rank=${SLURM_PROCID}
  cpus=$(awk "/Cpus_allowed_list/ {print \$2}" /proc/$$/status)
  mems=$(awk "/Mems_allowed_list/ {print \$2}" /proc/$$/status)
  printf "%s\t%s\t%s\t%s\n" "$host" "$rank" "$cpus" "$mems"
' | sort -k2,2n -k1,1 | awk -F"\t" '{printf "%-30s %-6s %-10s %-10s\n", $1, $2, $3, $4}'
