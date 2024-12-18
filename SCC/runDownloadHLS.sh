#!/bin/bash -l
#$ -j y

# Get the base directory path based on the location of this launching script.
MSLSP_BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )"/.. &> /dev/null && pwd )"
echo "Base directory: $BASE_DIR"


tile=$1
baseDir=$2
imgStartYr=$3
imgEndYr=$4

imgDir="${baseDir}${tile}/images/"


#Get Images from web
##########
for y in `seq $imgStartYr $imgEndYr`;
do
   #downloadHLS.sh -t $tile -y $y $imgDir 
   
   imgSD="${y}-01-01"
   imgED="${y}-12-31"
   $MSLSP_BASE_DIR/SCC/getHLS.sh $tile $imgSD $imgED $imgDir
   
done


