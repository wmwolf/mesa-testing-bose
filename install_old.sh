#!/bin/bash

# --- SLURM SETTINGS --- #

# -- Job Specifice --#
#SBATCH --job-name="Install MESA r22.05.1"
#SBATCH --output=out-%j.txt
#SBATCH --error=err-%j.txt
#SBATCH --partition=week
#SBATCH --time=1:00:00

# -- Resource Requirements -- #
#SBATCH --mem=8G
#SBATCH --ntasks-per-node=8
#SBATCH --nodes=1

# -- Email Support -- #
#SBATCH --mail-type=END,FAIL

# ---- YOUR SCRIPT ---- #
module load mesa
export MESASDK_ROOT="$HOME/mesasdk"
source $MESASDK_ROOT/bin/mesasdk_init.sh

export OMP_NUM_THREADS=8
export MESA_DIR="$HOME/mesa-r22.05.1"
cd $MESA_DIR && ./install
