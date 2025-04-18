
#Douglas Bolton, and Minkyu Moon, Boston University
#Main script for running HLS Land Surface Phenology
#######################################################################################


start_time <- Sys.time()



#Load required libraries
##################################
print('----------------------------------------------------------------------------------------------')
print('Loading packages')
print('')
print('')

library(sf)
library(terra)
library(imager)   #needed for efficient distance to snow calculate
library(ncdf4)

library(iterators)
library(foreach)
library(doMC)

library(matrixStats)   
library(WGCNA)
library(zoo)

library(RcppRoll)
library(Rcpp)

library(rjson)
library(XML)


print('----------------------------------------------------------------------------------------------')
print('Start processing')
print('')
print('')



#Read in arguments
args <- commandArgs(trailingOnly=T)
tile <- args[1]
jsonFile <- args[2]
runLog <- args[3]
errorLog <- args[4]


# tile <- '13RFN'
# jsonFile <- '/projectnb/modislc/users/sjstone/MSLSP/output/13RFN/parameters_2024_03_06_11_17_05.json'
# # jsonFile <- '/projectnb/modislc/users/sjstone/MSLSP/output/13RFN/parameters_2024_03_06_11_17_05.json'
# # runLog <- '/projectnb/modislc/users/sjstone/MSLSP/runLogs/18TYN_instanceInfo_2024_04_30_14_11_56.txt'
# errorLog <- '/projectnb/modislc/users/sjstone/MSLSP/runLogs/13RFN_errorLog_2024_03_05_14_16_38.txt'


#Get default parameters
params <- fromJSON(file=jsonFile)

#Pull paths for AWS or SCC?
if (params$setup$AWS_or_SCC == 'SCC') {
  params$setup$rFunctions <- params$SCC$rFunctions
  params$setup$productTable <- params$SCC$productTable
  params$setup$numCores <- params$SCC$numCores
  params$setup$numChunks <- params$SCC$numChunks
} else {
  params$setup$rFunctions <- params$AWS$rFunctions
  params$setup$productTable <- params$AWS$productTable
  params$setup$numCores <- params$AWS$numCores
  params$setup$numChunks <- params$AWS$numChunks}

#Load functions
source(file=params$setup$rFunctions)

#Register the parallel backend, reducing the number when running with S10
if (params$setup$AWS_or_SCC == "SCC" & params$SCC$runS10){
  registerDoMC(cores=params$setup$numCores / 2)
} else {
  registerDoMC(cores=params$setup$numCores)
}

time_step1 <- 0
time_step2 <- 0

#Set up data
#####################################################

#Pull a few variables
imgStartYr <- params$setup$imgStartYr
imgEndYr <- params$setup$imgEndYr
phenStartYr <- params$setup$phenStartYr
phenEndYr <- params$setup$phenEndYr
numChunks <- params$setup$numChunks

#
params$phenology_parameters$dormStart <- as.Date(params$phenology_parameters$dormStart)
params$phenology_parameters$dormEnd <- as.Date(params$phenology_parameters$dormEnd)

#Sort product table
############################
productTable <- read.csv(params$setup$productTable,header=T,stringsAsFactors = F)

params$phenology_parameters$numLyrs <- sum(!is.na(productTable$calc_lyr))
params$phenology_parameters$numLyrsCycle2 <- length(grep('_2',productTable$short_name[!is.na(productTable$calc_lyr)]))

#Location of specific layers for which we will product outputs for ALL pixels (regardless of having phenology)
params$phenology_parameters$loc_numCycles <- productTable$calc_lyr[productTable$short_name == 'NumCycles']
params$phenology_parameters$loc_max <- productTable$calc_lyr[productTable$short_name == 'EVImax']
params$phenology_parameters$loc_amp <- productTable$calc_lyr[productTable$short_name == 'EVIamp']
params$phenology_parameters$loc_numObs <- productTable$calc_lyr[productTable$short_name == 'numObs']
params$phenology_parameters$loc_numObs_count_snow <- productTable$calc_lyr[productTable$short_name == 'numObsCountSnow']
params$phenology_parameters$loc_maxGap <- productTable$calc_lyr[productTable$short_name == 'maxGap']
params$phenology_parameters$loc_maxGap_count_snow <- productTable$calc_lyr[productTable$short_name == 'maxGapCountSnow']

#If we are running S10, set resolution to 10m. Otherwise, doing things at 30m
if (params$setup$AWS_or_SCC == "SCC" & params$SCC$runS10) {params$setup$image_res <- 10} else {params$setup$image_res <- 30}



#Make chunk folders and temporary output folders
####################
for (i in 1:numChunks) {dirName <- paste0(params$dirs$chunkDir,"c",i,'/')
if (!dir.exists(dirName)) {dir.create(dirName,recursive=T)}}

for (y in seq(phenStartYr,phenEndYr)) {for (i in seq(1,params$phenology_parameters$numLyrs)) {dirName <- paste0(params$dirs$tempDir,'outputs/y',y,'/lyr',i,'/')
if (!dir.exists(dirName)) {dir.create(dirName,recursive=T)}}}





#Sort years
######################
imgYrs <- imgStartYr:imgEndYr        #What years will we consider for time-series filling?
phenYrs <- phenStartYr:phenEndYr     #What years will we calculate phenology for?


#Get full image list
###########
# imgList <- list.files(path=params$dirs$imgDir, pattern=glob2rx("HLS*Fmask.tif"), full.names=T, recursive=T)
# imgList <- list.dirs(path=params$dirs$imgDir, full.names=T)[-1]
if(params$setup$AWS_or_SCC == "SCC" & params$SCC$runS10) {

  imgList <- list.files(path=params$dirs$imgDir, full.names=T, recursive=T, pattern=glob2rx('*SCL*20m*') )
  for(img in imgList){
    # re-sampling the Sentinel-2 mask to 10m
    newMask <- gsub('20m', '10m', img)
    if(file.exists(newMask) == FALSE){
      run <- try(
        {
          system2("gdalwarp", paste("-overwrite -r near -ts 10980 10980 -of GTiff", img, newMask),
          stdout=T,
          stderr=T)
        },
        silent=FALSE)
    }
    
  }
  imgList <- list.files(path=params$dirs$imgDir, pattern=glob2rx('*SCL*10m*'), full.names=T, recursive=T)
} else {
  imgList <- list.files(path=params$dirs$imgDir, pattern=glob2rx("HLS*Fmask.tif"), full.names=T, recursive=T)
}

#Get the year and doy of each image. Restrict to time period of interest
##########################
sensor         <- matrix(NA,length(imgList),1)
yrdoy          <- as.numeric(matrix(NA,length(imgList),1))
# imgName_strip  <- matrix(NA,length(imgList),1)
if(params$setup$AWS_or_SCC == "SCC" & params$SCC$runS10){
  for(i in 1:length(imgList)){
    imgName_strip <- tail(unlist(strsplit(imgList[i], '/')), n = 1)
    sensor[i] <- 'S10'
    yrdoy[i] <- substr(unlist(strsplit(imgName_strip,'_',fixed = T))[2], 1, 8)
  }
  doys <- as.numeric(format(as.Date(strptime(yrdoy, format="%Y%m%d")), "%j"))
  years <- as.numeric(format(as.Date(strptime(yrdoy, format="%Y%m%d")), "%Y"))
} else{
  for (i in 1:length(imgList)) {
    imgName_strip[i] <- tail(unlist(strsplit(imgList[i],'/')),n = 1)
    sensor[i] <- unlist(strsplit(imgName_strip[i],'.',fixed = T))[2]
    yrdoy[i]<- substr(unlist(strsplit(imgName_strip[i],'.',fixed = T))[4],1,7)}
  doys <- as.numeric(format(as.Date(strptime(yrdoy, format="%Y%j")),'%j'))
  years <- as.numeric(format(as.Date(strptime(yrdoy, format="%Y%j")),'%Y'))
}
# for (i in 1:length(imgList)) {
#   imgName_strip[i] = tail(unlist(strsplit(imgList[i],'/')),n = 1)
#   sensor[i] <- unlist(strsplit(imgName_strip[i],'.',fixed = T))[2]
#   yrdoy[i]= substr(unlist(strsplit(imgName_strip[i],'.',fixed = T))[4],1,7)}
# doys <- as.numeric(format(as.Date(strptime(yrdoy, format="%Y%j")),'%j'))
# years <- as.numeric(format(as.Date(strptime(yrdoy, format="%Y%j")),'%Y'))

keep <- (years >= (imgStartYr - 1)) & (years <= (imgEndYr + 1))  #Only keep imagery +/- 1 (need 6 month buffer)

#Determine which data to keep
if (!params$setup$includeLandsat) {drop <- sensor == 'L30'; keep[drop] <- FALSE}
if (!params$setup$includeSentinel) {drop <- sensor == 'S30'; keep[drop] <- FALSE}  

imgList <- imgList[!is.na(keep)]
yrdoy <- yrdoy[!is.na(keep)]
doys <- doys[!is.na(keep)]
years <- years[!is.na(keep)]
sensor <- sensor[!is.na(keep)]


uniqueYrs <- sort(unique(years))  #What years do we actually have imagery for? (imgYears +/- 1 for buffer years)


#Record number of images for each sensor per year
for (y in uniqueYrs) {
  if (params$setup$AWS_or_SCC == "SCC" & params$SCC$runS10){
    nS10 <- sum(years == y & sensor == 'S10')
    cat(paste0('S10_',y,':',nS10,'\n'), file=runLog, append=T)
  } else {
    nL30 <- sum(years == y & sensor == 'L30')
    nS30 <- sum(years == y & sensor == 'S30')
    cat(paste0('L30_',y,':',nL30,'\n'), file=runLog, append=T)
    cat(paste0('S30_',y,':',nS30,'\n'), file=runLog, append=T)
  }
}



#Get raster information from first image
##########################
# baseImage  <-  rast(paste0(imgList[1],'/',imgName_strip[1],'.Fmask.tif')) #Set up base image that we'll use for outputs
baseImage <- rast(imgList[1])
numPix  <-  ncol(baseImage)*nrow(baseImage)   #Get total number of pixels

#Sort out chunk boundaries
#################
boundaries <- chunkBoundaries(numPix,numChunks) #Chunk image for processing
chunkStart <- boundaries[[1]]   #Get pixel boundaries for each chunk
chunkEnd <- boundaries[[2]]
numPixPerChunk <- chunkEnd - chunkStart + 1  #Number of pixels in each chunk


#Read in water mask
water <- as.integer(values(rast(paste0(params$dirs$imgDir,'water_',tile,'.tif'))))
waterMask <- water == 2 | water == 0    #Mask water and zero (zero = ocean far from shore)
remove(water)


#STEP 1 - Preprocess images
#####################################################
#####################################################
if (params$setup$preprocessImagery) {  
  
  #Apply mask and write out chunked images. 
  imgLog <- foreach(j=1:length(imgList),.combine=c) %dopar% {
    log <- try({ApplyMask_QA(imgList[j], tile, waterMask, chunkStart, chunkEnd, params)},silent=T)
    if (inherits(log, 'try-error')) {cat(paste('ApplyMask_QA: Error for', imgList[j],'\n'), file=errorLog, append=T)}  #If there's an error, keep going, but write to error log
    #log <- ApplyMask_QA(imgList[j], tile, waterMask, chunkStart, chunkEnd, params)
    #cat(paste(log, file=errorLog, append=T))
  }

  #Topographic Correction of images
  #TopoMethod is either set to VI or None. If set to None, this step is skipped.
  ###########################
  if (params$topocorrection_parameters$topoCorrect) {
    
    #reducing the number of cores to be used in topo correction
    if (params$setup$AWS_or_SCC == "SCC" & params$SCC$runS10){
      registerDoMC(cores=params$setup$numCores / 4)
    }
    
    #In this approach, pixels will be clustered (kmeans) according to specified vegetation indices
    #Once clusters are determined, each cluster/band combo will be topographically corrected separately.
    
    topo_pars <- params$topocorrection_parameters
    
    #Read in slope and aspect rasters
    #IMPORTANT: Code expects units of slope and aspect to be radians * 10000
    slope <- rast(paste0(params$dirs$imgDir,'slope_',tile,'.tif')) #Keeping this slope raster as a template for other temporary outputs
    # slopeVals <- readGDAL(paste0(params$dirs$imgDir,'slope_',tile,'.tif'),silent=T)$band1
    slopeVals <- as.integer(values(rast(paste0(params$dirs$imgDir,'slope_',tile,'.tif'))))
    slopeVals[slopeVals == 65534] = NA
    slopeVals = slopeVals / 10000
    
    # aspectVals = readGDAL(paste0(params$dirs$imgDir,'aspect_',tile,'.tif'),silent=T)$band1
    aspectVals = as.integer(values(rast(paste0(params$dirs$imgDir,'aspect_',tile,'.tif'))))
    aspectVals[aspectVals == 65534] = NA
    aspectVals = aspectVals / 10000
    
    for (yr in uniqueYrs) {
      subList <- imgList[years==yr]
      subDOY  <- doys[years==yr]
      print(c("subList: ", subList))
      print(c("subDOY: ", subDOY))
      
      if (length(subList) > 0) {
        #Check if the first year has enough data (images back to DOY 60 or whatever specified). If it doesn't, then use the next year's VIs for kmeans
        #Check if the final year has enough data (images past DOY 300 or whatever specified). If it doesn't, then use the previous year's VIs for kmeans
        if (yr == uniqueYrs[1] & min(subDOY) > topo_pars$requiredDoyStart) {yrPull <- yr+1
        } else if (yr == uniqueYrs[length(uniqueYrs)] & max(subDOY) < topo_pars$requiredDoyEnd) {yrPull <- yr-1
        } else {yrPull <- yr}
        
        #Calculate the VIs by reading in image chunks, and calcuating percentiles
        indexImg <- foreach(j=1:numChunks,.combine=rbind) %dopar% {
          getIndexQuantile(j, numPixPerChunk[j], yrPull, errorLog, params)}
        
        #Convert VIs to z-scores prior to kmeans
        for (i in 1:dim(indexImg)[2]) {
          col <- indexImg[,i]
          indexImg[,i] <- (col - mean(col,na.rm=T)) / sd(col,na.rm=T)
        }
        
        #Perform kmeans. Must first remove NA values (otherwise kmeans fails). Topo correction will be performed for each class
        goodPix <- !is.na(rowMeans(indexImg))
        # kClust <- kmeans(indexImg[goodPix,], topo_pars$kmeansClasses, iter.max = topo_pars$kmeansIterations)
        kClust <- kmeans(indexImg[goodPix,], topo_pars$kmeansClasses, iter.max = 700)
        groups <- matrix(0,numPix)
        groups[goodPix] <-  kClust$cluster
        groups[is.na(groups) | is.na(slopeVals) | is.na(aspectVals)]  <- 0    #Assign zero value to groups if slope, aspect, or group is NA
        
        #Now that we have kmeans classes, run the topographic correction function. 
        imgLog <- foreach(j=1:length(subList),.combine=c) %dopar% {
          log <- try({runTopoCorrection(subList[j], groups, slopeVals, aspectVals, chunkStart,chunkEnd, errorLog, params)}, silent=T)
          if (inherits(log, 'try-error')) {cat(paste('RunTopoCorrection: Error for', subList[j],'\n'), file=errorLog, append=T)}
        }
        
        # # testing out without the try statement and without running in parallel to see why certain images are failing
        # imgLog <- foreach(j=1:length(subList),.combine=c) %do% {
        #   log <- runTopoCorrection(subList[j], groups, slopeVals, aspectVals, chunkStart,chunkEnd, errorLog, params)
        #   # log <- try({runTopoCorrection(subList[j], groups, slopeVals, aspectVals, chunkStart,chunkEnd, errorLog, params)}, silent=T)
        #   # if (inherits(log, 'try-error')) {cat(paste('RunTopoCorrection: Error for', subList[j],'\n'), file=errorLog, append=T)} 
        # }
        
      }
    }
  }
  
  time_step1 <- as.numeric(difftime(Sys.time(),start_time,units="mins"))
  print('----------------------------------------------------------------------------------------------')
  print(paste('Finished preprocessing images in',round(time_step1,1),'minutes'))
  print('')
  print('')
  cat(paste0('Step1_Minutes:',round(time_step1,1),'\n'), file=runLog, append=T)
  
}


#Reset to full cores
registerDoMC(cores=params$setup$numCores)

#STEP 2 - Run Phenology
#####################################################
#####################################################
if (params$setup$runPhenology) {   
  #Run phenology code for each image chunk
  imgLog <- foreach(j=1:numChunks) %dopar% {
    log <- try({runPhenoChunk(j, numPixPerChunk[j], imgYrs, phenYrs, errorLog, params)},silent=T)
    if (inherits(log, 'try-error')) {cat(paste('RunPhenoChunk: Error for chunk', j,'\n'), file=errorLog, append=T)}
  }
  
  
  #Loop through the years processed and output netcdf files
  yrs <- phenStartYr:phenEndYr  
  log <- foreach(yr = yrs) %dopar% { 
    productFile  <- paste0(params$dirs$phenDir,'MSLSP_',tile,'_',yr,'.nc') 
    qaFile  <- paste0(params$dirs$phenDir,'MSLSP_',tile,'_',yr,'_Extended_QA.nc') 
    
    CreateExtendedQA(yr,qaFile, productTable, baseImage, params)
    CreateProduct(yr,productFile, qaFile, productTable, baseImage, waterMask, params)
  }
  
  
  
  total_time <- as.numeric(difftime(Sys.time(),start_time,units="mins"))
  time_step2 <- total_time - time_step1
  print('----------------------------------------------------------------------------------------------')
  print(paste('Finished detecting phenology in',round(time_step2,1),'minutes'))
  print('')
  print('')
  cat(paste0('Step2_Minutes:',round(time_step2,1),'\n'), file=runLog, append=T)
  
}


#Write to log
######################
total_time <- as.numeric(difftime(Sys.time(),start_time,units="mins"))
line <- paste(tile, time_step1, time_step2, total_time, sep=',')
line <- paste0(line,'\n')
cat(paste0('Total_Minutes:',round(total_time,1),'\n'), file=runLog, append=T)







