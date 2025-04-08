#######################################################################################
# This script assembles the chunked images from the "chunkDir" directory 
# into a single raster object.
# It uses the "MSLSP_Functions_dev.R" script for helper functions.
# Author: Dennis Milechin, RCS, Boston University
# Created: 4/8/2025
######################################################################################

library(terra)
source("MSLSP_Functions_dev.R")


chunkDir <- "output/S10/12SVA/imageChunks"  # Directory where the chunked images are stored
basename <- "S2_S10_T12SVA_2015206"         # Base name of the chunked image

# Bath of baseImage used to get numPix and dimensions for tiles
baseImage_path <- "input/S10/12SVA/images/S2A_MSIL2A_20150725T181446_N0500_R041_T12SVA_20231028T230145/T12SVA_20150725T181446_B02_10m.tif"


# Taken from MSLSP_Functions_dev.R, but modified to work with "imageChuinked" directory
readLyrChunks <- function(numPix, chunkDir, basename, chunkStart, chunkEnd) {
  mat <- matrix(NA,numPix,1)
  numChunks <- length(chunk_dir_list)

  for (n in 1:numChunks) {
    fileName <- paste0(chunkDir,'/c',n,'/',basename,'.Rds')
    matSub <- readRDS(fileName)
    mat[chunkStart[n]:chunkEnd[n]] <- matSub
  }
  return(mat)
}

# get a list of directory chunks.  Remove the top one, which is the base directory
chunk_dir_list <- list.dirs(chunkDir)[c(-1)]

# Number of chunks is determined based on the number of directories in the chunkDir
numChunks <- length(chunk_dir_list)

# Load the base image and get the number of pixels
baseImage <- rast(baseImage_path)
numPix  <-  ncol(baseImage)*nrow(baseImage)   #Get total number of pixels

# Get the chunkStart and chunkEnd values
boundaries <- chunkBoundaries(numPix,numChunks) #Chunk image for processing
chunkStart <- boundaries[[1]]   #Get pixel boundaries for each chunk
chunkEnd <- boundaries[[2]]

# Read the chunked data
data <- readLyrChunks(numPix, chunkDir, basename, chunkStart, chunkEnd)

# Reshape the data to match the dimensions of the base image
data <- matrix(data, dim(baseImage)[1], dim(baseImage)[2]) 

# Convert the matrix to a raster object
rast_data <- rast(data)

# Plot the data
plot(rast_data)
