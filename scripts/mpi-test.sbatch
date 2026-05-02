#!/bin/bash
#SBATCH -J mpi-hello
#SBATCH -o mpi-hello.%j.out
#SBATCH -e mpi-hello.%j.err
#SBATCH -N 2
#SBATCH -n 4
#SBATCH -t 00:05:00
#SBATCH -p compute

set -euo pipefail

module purge
module load NVHPC/25.3-CUDA-12.8.0

cat > mpi_hello.c <<'EOF'
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  MPI_Init(&argc, &argv);

  int rank = 0;
  int size = 0;
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &size);

  printf("hello from rank %d of %d on %s\n", rank, size, getenv("HOSTNAME"));

  MPI_Finalize();
  return 0;
}
EOF

mpicc mpi_hello.c -o mpi_hello
srun --mpi=pmix -n "${SLURM_NTASKS}" ./mpi_hello
