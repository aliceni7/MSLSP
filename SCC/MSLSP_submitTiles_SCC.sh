module load jq

parameters="/projectnb/modislc/users/aliceni/MSLSP/MSLSP_Parameters.json"
tileList="/projectnb/modislc/users/aliceni/MSLSP/SCC/tileLists/arizona.txt"

numCores=$( jq .SCC.numCores $parameters )
workDir=$( jq --raw-output .SCC.workDir $parameters )
dataDir=$( jq --raw-output .SCC.dataDir $parameters )

jobTime="$(date +%Y_%m_%d_%H_%M_%S)"

logDir=$( jq --raw-output .SCC.logDir $parameters ) 
mkdir -p $logDir

if $(jq .SCC.runS10 $parameters )
then
    baseDir="${dataDir}S10/"
    nodeArgs="-l h_rt=36:00:00 -l mem_per_core=16G -pe omp ${numCores}"
else
    baseDir="${dataDir}HLS30/"
    nodeArgs="-l h_rt=36:00:00 -pe omp ${numCores} -l mem_per_core=16G"
fi


#Set up initial folders and copy parameter file 
while read -r tile
    do
        tileDir="${workDir}${tile}/"
        imgDir="${baseDir}${tile}/images/"
        mkdir -p $tileDir
        mkdir -p $imgDir
        
        paramName="${tileDir}parameters_${jobTime}.json"
        jq --arg imgDir "$imgDir" '.dirs.imgDir = $imgDir' ${parameters}>${paramName}
    done < $tileList
    
if $(jq .SCC.runS10 $parameters )
then
  while read -r tile
  do
    tileJsonDir="${baseDir}${tile}/tile/"
    mkdir -p $tileJsonDir
  done < $tileList
fi



#If download is set to true, the code will check for new HLS images and only download those
if [ $(jq .setup.downloadImagery $parameters ) == true ] && [ $(jq .SCC.runS10 $parameters ) == false ]
then
    while read -r tile
    do
        nameArg="-N DL_${tile}"
        logArg_download="-o ${logDir}Download_${tile}_${jobTime}.txt"
        downloadArg="-l download"
        imgStartYr=$(( $( jq .setup.imgStartYr $parameters ) - 1 ))
        imgEndYr=$(( $( jq .setup.imgEndYr $parameters ) + 1 ))
        qsub $nameArg $logArg_download $downloadArg /projectnb/modislc/users/aliceni/MSLSP/SCC/runDownloadHLS.sh $tile $baseDir $imgStartYr $imgEndYr
    done < $tileList

    while read -r tile
    do
        tileDir="${workDir}${tile}/"
        paramName="${tileDir}parameters_${jobTime}.json"
        nameArg="-N R_${tile}"
        logArg="-o ${logDir}Run_${tile}_${jobTime}.txt"
        holdArg="-hold_jid DL_${tile}"
        qsub $nameArg $logArg $nodeArgs $holdArg /projectnb/modislc/users/aliceni/MSLSP/SCC/MSLSP_runTile_SCC.sh $tile $paramName $jobTime
    done < $tileList
elif [ $(jq .setup.downloadImagery $parameters ) == true ] && [ $(jq .SCC.runS10 $parameters ) == true ]
then
    while read -r tile
    do
        nameArg="-N DL_S10_${tile}"
        logArg_download="-o ${logDir}Download_${tile}_${jobTime}.txt"
        downloadArg="-l download"
        imgStartYr=$(( $( jq .setup.imgStartYr $parameters ) - 1 ))
        imgEndYr=$(( $( jq .setup.imgEndYr $parameters ) + 1 ))
        qsub $nameArg $logArg_download $downloadArg /projectnb/modislc/users/aliceni/MSLSP/S10_scripts/runDownloadS10.sh $tile $baseDir $imgStartYr $imgEndYr $tileJsonDir
    done < $tileList
    
    while read -r tile
    do
      tileDir="${workDir}${tile}/"
      paramName="${tileDir}parameters_${jobTime}.json"
      nameArg="-N R_${tile}"
      logArg="-o ${logDir}Run_${tile}_${jobTime}.txt"
      holdArg="-hold_jid DL_S10_${tile}"
      qsub $nameArg $logArg $nodeArgs $holdArg /projectnb/modislc/users/aliceni/MSLSP/SCC/MSLSP_runTile_SCC.sh $tile $paramName $jobTime
    done < $tileList
else
    while read -r tile
    do
        tileDir="${workDir}${tile}/"
        paramName="${tileDir}parameters_${jobTime}.json"
        nameArg="-N R_${tile}"
        logArg="-o ${logDir}Run_${tile}_${jobTime}.txt"
        qsub $nameArg $logArg $nodeArgs /projectnb/modislc/users/aliceni/MSLSP/SCC/MSLSP_runTile_SCC.sh $tile $paramName $jobTime
    done < $tileList
fi

