#!/bin/bash
# please copy this file to the results directory
# 1.1 generate csv from AWS json
find ./$1* -maxdepth 0 -type d -exec ./csv_gen.sh {} \;

# 1.2 generate cobined fortio json
find ./$1* -maxdepth 0 -type d -exec ./fortio_prc.sh {} \;


# 2.1 plot fortio data
fg="python ../thesis-infra/data/processing/foldergraph.py --overwrite"
find ./$1*/csv -maxdepth 0 -type d -exec $fg {} \; -exec $fg --metric cpuUtilization {} \; \
  -exec $fg --metric groupInServiceCapacity {} \; -exec $fg --metric requestCount --threads {} \; \
  -exec $fg --metric backendConnectionErrors {} \;

# 2.2 plot csv data
find ./$1*/csv/*.csv -exec python ../thesis-infra/data/processing/simplegraph.py --overwrite {} \;

# 3.0 re-generate results explorer
cd ../thesis-infra/data/processing;ls
ipython -c "%run resultsExplorer.ipynb"