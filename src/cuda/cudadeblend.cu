/*
 * cudadeblend.cu
 *
 *  Created on: 9 Jan, 2013
 *      Author: zhao
 */
#include <stdio.h>
#include <cuda.h>
#include <limits.h>
#include <iostream>
#include <curand.h>
#include <curand_kernel.h>

#include "../util5/cudpp.h"
#include "../util5/helper_cuda.h"

#include "cudatypes.h"
#include "cudaanalyse.h"
#include "cudainit.h"


float	*d_multiThreshArray;
//for the whole image label of lower threshold
int		*d_rootLabelArray;

unsigned int	**d_debPixelCountArray;
float			**d_debFdfluxArray;
float			**d_debDthresh;
unsigned int	**d_debOk;
unsigned int	**d_debParentLabel;

unsigned int	**d_finalDebLabelArray;
unsigned int	**d_finalDebPixelIndexArray;
unsigned int	**d_finalDebObjIndexArray;

size_t			*h_finalValidObj;
size_t			*h_finalValidPix;

///////////////////////////
int compact_and_sort1(int numpix, int level,
		int ext_minarea, int nthresh);

int pre_analyse1(int npixAbovethresh,
		int		numValidPix,
		int 	level,
		int 	nthresh);

__global__ void segmentmask_prune_kernel(
		unsigned int* d_segmentMaskin,
		unsigned int* d_segmentMaskout,
		unsigned int* d_pixelCountSegment,
		size_t numElements,
		int ext_minarea);

int cut_branch(int n_thresh, double DEBLEND_MINCONT);

void sortbyRootlabel(
		unsigned int *d_cuttedObjLevelArray,
		unsigned int *d_cuttedObjLabelArray,
		unsigned int *d_cuttedObjIndexArray,
		unsigned int *d_cuttedPixCountArray,
		unsigned int *d_cuttedRootlabelArray,
		float *d_cuttedDthreshArray,
		int totalobj);

void sortPixelByObj(
		unsigned int *d_finalPixelIndexArray,
		int *d_allocateMap,
		unsigned int *d_objIndexArray,
		unsigned int *d_pixelCountArray,
		int numpix,
		int numobj);

//prenalysis before gather up, for level 0 to n.
// level 0 takes almost half the whole time
//thresh is a constant here
__global__ void preanalyse_full_kernel(
		unsigned int *d_cuttedObjLevelArray,
		unsigned int *d_cuttedObjIndexArray,
		unsigned int *d_cuttedPixCountArray,
		unsigned int *d_cuttedObjFlagArray,
		float		 *d_cuttedDthreshArray,
		float		 *d_cdPixArray,
		float		 *d_pixelArray,
		int			 *d_labelArray,
		unsigned int **d_pixelIndexArray,
		/* output starts */
		unsigned int *d_xmin,
		unsigned int *d_xmax,
		unsigned int *d_ymin,
		unsigned int *d_ymax,
		unsigned int *d_dnpix,
		double *d_mx,
		double *d_my,
		double *d_mx2,
		double *d_my2,
		double *d_mxy,
		float *d_cxx,
		float *d_cxy,
		float *d_cyy,
		float *d_a,
		float *d_b,
		float *d_theta,
		float *d_abcor,
		float *d_fdpeak,
		float *d_dpeak,
		float *d_fdflux,
		float *d_dflux,
		char  *d_singuflag,
		float *d_amp,
		/* output ends */
		int width,
		int height,
		float thresh,
		int plistexist_dthresh,
		int analyse_type,
		unsigned int numobj);

__global__ void preanalyse_robust_kernel(
		unsigned int *d_cuttedObjLevelArray,
		unsigned int *d_cuttedObjIndexArray,
		unsigned int *d_cuttedPixCountArray,
		unsigned int *d_cuttedObjFlagArray,
		float		 *d_cuttedDthreshArray,
		unsigned int *d_finalPixelIndexArray,
		float		 *d_cdPixArray,
		float		 *d_pixelArray,
		/* output starts */
		unsigned int *d_xmin,
		unsigned int *d_xmax,
		unsigned int *d_ymin,
		unsigned int *d_ymax,
		unsigned int *d_dnpix,
		double *d_mx,
		double *d_my,
		double *d_mx2,
		double *d_my2,
		double *d_mxy,
		float *d_cxx,
		float *d_cxy,
		float *d_cyy,
		float *d_a,
		float *d_b,
		float *d_theta,
		float *d_abcor,
		float *d_fdpeak,
		float *d_dpeak,
		float *d_fdflux,
		float *d_dflux,
		char  *d_singuflag,
		/* output ends */
		int width,
		int height,
		float thresh,
		int plistexist_dthresh,
		int analyse_type,
		unsigned int numobj);

__global__ void segmentMaskInitKernel(unsigned int* d_compactedLabelArray,
		unsigned int* d_segmentMask,
		unsigned int* d_pixelCountMask,
		unsigned int numElements);

__global__ void getPixelFromIndexKernel(unsigned int* d_indexArray,
		float* d_inpixelArray, float* d_outpixelArray, size_t numElements);

__global__ void segmentmask_prune_kernel(
		unsigned int* d_compactedLabelArray,
		unsigned int* d_segmentEndMask,
		unsigned int* d_pixelCountSegment,
		size_t numElements,
		size_t ext_minarea);

__global__ void okInit_kernel(unsigned int *d_ok, unsigned int h_numValidObj);

__global__ void getLabelFromIndexKernel(unsigned int* d_indexArray,
		int* d_labelArrayIn,
		unsigned int* d_labelArrayOut,
		size_t numElements);

void checkcudppSuccess(CUDPPResult res, char* msg);

//////////////////////////////////////////////////////////
__global__ void rootLabelInitKernel(int* d_rootLabelArray,
		unsigned int* d_finalCompactedLabelArray,
		unsigned int* d_finalCompactedIndexArray,
		unsigned int  numValidPix) {

	const int tid_x = blockDim.x * blockIdx.x + threadIdx.x;
	const int tid_y = blockDim.y * blockIdx.y + threadIdx.y;
	const int tid = tid_y * (gridDim.x * blockDim.x) + tid_x;

	if(tid < numValidPix) {
		d_rootLabelArray[d_finalCompactedIndexArray[tid]]
		                    = d_finalCompactedLabelArray[tid];
	}
}

__global__ void computeMultiThreshKernel(float* _d_multiThreshArray,
		float*	_d_fdpeakArray,
		float _base_thresh,
		int _deblend_nthresh,
		unsigned int  numValidObj) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= numValidObj)
		return;

	double dthresh0 = _base_thresh;
	double dthresh = _d_fdpeakArray[tid];

	for(int i=1; i<_deblend_nthresh; i++) {
		_d_multiThreshArray[numValidObj * (i-1) + tid] =
				 dthresh0 * pow(dthresh/dthresh0,(double)i/_deblend_nthresh);
	}
}

//n=31
//deblend_nthresh 32
//kernel shape: 4096 blocks, 32x32 threads per block
//0.105s
__global__ void deblendInit_kernel(float *d_cdPixArray,
		int *d_labelArray,
		int *d_equivArray,
		unsigned int *d_compactMask,
		unsigned int *d_compactedIndexArray,
		int *d_rootLabelArray,
		float* 	d_multiThreshArray,
		int numValidObj,
		int numValidPix,
		int n) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < numValidPix) {

		int id = d_compactedIndexArray[tid];
		int rootlabel = d_rootLabelArray[id];

		//parent label: 1,2,....
		//float thresh = d_multiThreshArray[(deblend_nthresh-1)*(rootlabel-1)+(n-1)];
		float thresh = d_multiThreshArray[(n-1)*numValidObj+ rootlabel-1];

		if(d_cdPixArray[id] >= thresh)
		{
			d_labelArray[id] = id;
			d_equivArray[id] = id;
			d_compactMask[tid]= 1;
		}
		/*
		else
		{
			d_labelArray[id] = -1;
			d_equivArray[id] = -1;
			d_compactMask[tid]= 0;
		}*/
	}
}

__global__ void debcompactMaskInitKernel(int* d_labelArray,
		unsigned int* d_compactMask,
		int numValidPix) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < numValidPix) {

		if (d_labelArray[tid] == -1)
			d_compactMask[tid] = 0;
		else
			d_compactMask[tid] = 1;
	}
}

__global__ void scanKernel1(int* d_labelArray,
		int* d_equivArray,
		unsigned int* d_compactedIndexArray,
		int numValidPix,
		int width,
		int height,
		int* update) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= numValidPix)
		return;

	int id = d_compactedIndexArray[tid];

	int neighbors[8];
	int label1 = d_labelArray[id];
	int label2 = INT_MAX;
	if (label1 == -1)
		return;

	int id_x = id % width;
	int id_y = id / width;

	//the edge labels are  considered
	if (id_y > 0) {
		if (id_x > 0)
			neighbors[0] = d_labelArray[(id_y - 1) * width + (id_x - 1)];
		else
			neighbors[0] = -1;

		neighbors[1] = d_labelArray[(id_y - 1) * width + (id_x)];

		if (id_x < width - 1)
			neighbors[2] = d_labelArray[(id_y - 1) * width + (id_x + 1)];
		else
			neighbors[2] = -1;

	} else {
		neighbors[0] = -1;
		neighbors[1] = -1;
		neighbors[2] = -1;
	}

	if (id_x > 0)
		neighbors[3] = d_labelArray[(id_y) * width + (id_x - 1)];
	else
		neighbors[3] = -1;

	if (id_x < width - 1)
		neighbors[4] = d_labelArray[(id_y) * width + (id_x + 1)];
	else
		neighbors[4] = -1;

	if (id_y < (height - 1)) {
		if (id_x > 0)
			neighbors[5] = d_labelArray[(id_y + 1) * width + (id_x - 1)];
		else
			neighbors[5] = -1;

		neighbors[6] = d_labelArray[(id_y + 1) * width + (id_x)];

		if (id_x < width - 1)
			neighbors[7] = d_labelArray[(id_y + 1) * width + (id_x + 1)];
		else
			neighbors[7] = -1;
	} else {
		neighbors[5] = -1;
		neighbors[6] = -1;
		neighbors[7] = -1;
	}

	for (int i = 0; i < 8; i++) {
		if ((neighbors[i] != -1) && (neighbors[i] < label2)) {
			label2 = neighbors[i];
		}
	}
	if (label2 < label1) {
		atomicMin(d_equivArray + label1, label2);
		//d_equivArray[tid] = label2;
		*update = 1;
	}
	return;
}

__global__ void analysisKernel1(int* d_labelArray,
		int* d_equivArray,
		unsigned int* d_compactedIndexArray,
		int numValidPix) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < numValidPix) {

		int id = d_compactedIndexArray[tid];

		int ref = d_equivArray[id];
		while (ref != -1 && ref != d_equivArray[ref]) {
			ref = d_equivArray[ref];
		}
		d_equivArray[id] = ref;
		d_labelArray[id] = ref;
	}

}

__global__ void labellingKernek1(int* d_labelArray,
		int* d_equivArray,
		unsigned int* d_compactedIndexArray,
		int numValidPix) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < numValidPix) {
		int id = d_compactedIndexArray[tid];
		//d_labelArray[id] = d_equivArray[d_labelArray[id]];
		d_labelArray[id] = d_equivArray[id];
	}
}

//needed to be improved later on.
/**
 * initialize the dthresh value
 */
__global__ void debDthreshInit_kernel(float *d_debDthresh,
		unsigned int 	*d_finalDebObjIndexArray,
		unsigned int 	*d_finalDebPixelIndexArray,
		int 			*d_rootLabelArray,
		float 			*d_multiThreshArray,
		int 			level,
		unsigned int 	h_numValidObj,
		int				h_rootnumValidObj) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < h_numValidObj)
	{
		unsigned int first_index = d_finalDebPixelIndexArray[d_finalDebObjIndexArray[tid]];
		int rootlabel = d_rootLabelArray[first_index];
		d_debDthresh[tid] = d_multiThreshArray[(level-1)*h_rootnumValidObj + rootlabel-1];
	}
}

//compute obj.fdflux - obj.dthresh*obj.fdnpix(in original order produced by analysis)
//value0 = objlist[0].obj[0].fdflux*prefs.deblend_mincont;
//need to be improved later on
__global__ void decidePrune1_kernel(
		unsigned int 	*d_flag,
		unsigned int 	*d_nson,
		float 			*d_fdflux,
		float			*d_dthresh,
		unsigned int 	*d_fdnpix,
		unsigned int	*d_finalDebPixelIndexArray,
		unsigned int	*d_finalDebObjIndexArray,
		unsigned int	*d_ok,
		unsigned int	*d_parentOk,
		unsigned int	*d_parentLabel,
		int				*d_rootLabelArray,
		float			*d_rootfdflux,
		unsigned int 	h_numValidObj,
		double 			deblend_mincont) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < h_numValidObj) {

		//if(d_nson[tid] > 1)
		//	d_ok[tid] = 0;

		int parentlabel = d_parentLabel[tid];
		atomicAnd(d_parentOk + (parentlabel-1), d_ok[tid]);

		unsigned int first_index = d_finalDebPixelIndexArray[d_finalDebObjIndexArray[tid]];
		int rootlabel = d_rootLabelArray[first_index];
		double value0 = d_rootfdflux[rootlabel-1] * deblend_mincont;

		if(d_fdflux[tid] - d_dthresh[tid]*d_fdnpix[tid] > value0)
		{
			d_flag[tid] = 1;
			atomicAdd(d_nson+(parentlabel-1), 1);
		}
		else
			d_flag[tid] = 0;
	}
}

__global__ void decidePrune2_kernel(unsigned int *d_flag,
		unsigned int *d_nson,
		unsigned int *d_ok,
		unsigned int *d_parentOk,
		unsigned int *d_parentLabel,
		unsigned int h_numValidObj) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < h_numValidObj) {

		int nson = d_nson[d_parentLabel[tid]-1];

		if(nson > 1)
			d_parentOk[d_parentLabel[tid]-1] = 0;

		if(nson > 1 && d_ok[tid] == 1 && d_flag[tid] == 1)
			d_ok[tid] = 1;
		else
			d_ok[tid] = 0;
	}
}

__global__ void memInit_kernel(
		int *d_labelArray,
		int	*d_equivArray,
		unsigned int *d_compactMask,
		unsigned int numValidPix)
{
	const int tid_x = blockDim.x * blockIdx.x + threadIdx.x;
	const int tid_y = blockDim.y * blockIdx.y + threadIdx.y;
	const int tid = tid_y * (gridDim.x * blockDim.x) + tid_x;

	if(tid < numValidPix) {

		d_labelArray[tid] = -1;
		d_equivArray[tid] = -1;
		d_compactMask[tid] = 0;
	}
}

//////////////////////////////////////////////////////////////////////////
/**
 * allocated global vars:d_multiThreshArray
 * 						 d_rootLabelArray
 */
extern "C" void init_deblend(float basethresh,
		int _deblend_nthresh,
		size_t numValidObj,
		size_t numValidPix) {

	float time;
	cudaEventRecord(start, 0);

	int grid_obj = (((int)numValidObj-1)/(MAX_THREADS_PER_BLK)+1);
	int block_obj = (MAX_THREADS_PER_BLK);

	int grid_pix = (((int)numValidPix-1)/(MAX_THREADS_PER_BLK)+1);
	int block_pix = (MAX_THREADS_PER_BLK);


	checkCudaErrors(cudaMalloc((void**)(&d_multiThreshArray),
			(int)(numValidObj*(_deblend_nthresh-1))*sizeof(float)));
	checkCudaErrors(cudaMalloc((void**)(&d_rootLabelArray), width*height * sizeof(int)));
	checkCudaErrors(cudaMemset(d_rootLabelArray, -1, width * height * sizeof(int)));

	computeMultiThreshKernel<<<grid_obj, block_obj>>>(d_multiThreshArray,
			d_fdpeakArray,
			basethresh,
			_deblend_nthresh,
			numValidObj);

	rootLabelInitKernel<<<grid_pix, block_pix>>>(d_rootLabelArray,
			d_finalLabelArray,
			d_finalPixelIndexArray,
			numValidPix);

	d_debPixelCountArray = (unsigned int**)malloc(_deblend_nthresh*sizeof(unsigned int*));

	d_debFdfluxArray = (float**)malloc(_deblend_nthresh*sizeof(float*));
	d_debDthresh = (float**)malloc(_deblend_nthresh*sizeof(float*));

	d_debOk = (unsigned int**)malloc(_deblend_nthresh*sizeof(unsigned int*));
	d_debParentLabel = (unsigned int**)malloc(_deblend_nthresh*sizeof(unsigned int*));

	d_finalDebPixelIndexArray = (unsigned int**)malloc(_deblend_nthresh*sizeof(unsigned int*));
	d_finalDebObjIndexArray = (unsigned int**)malloc(_deblend_nthresh*sizeof(unsigned int*));
	d_finalDebLabelArray = (unsigned int**)malloc(_deblend_nthresh*sizeof(unsigned int*));

	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&time, start, stop);

#ifdef DEBUG_CUDA
	printf("time consumed by cuda deblend init is %f\n", time);
#endif

}

void init_level0() {

	d_debPixelCountArray[0] = d_pixelCountArray;
	d_debFdfluxArray[0]		= d_fdfluxArray;
	d_debDthresh[0]			= d_dthreshArray;
	d_debOk[0]				= d_ok;

	d_debParentLabel[0]		= NULL;

	d_finalDebLabelArray[0] = d_finalLabelArray;
	d_finalDebPixelIndexArray[0] = d_finalPixelIndexArray;
	d_finalDebObjIndexArray[0] = d_finalObjIndexArray;

}
//d_labelArray has been changed here
/**
 * allocated global vars: d_compactedDebIndexArray
 */
extern "C" int parcel_out(float basethresh,
		int n_thresh,
		int deb_minarea,
		size_t numValidObj,
		size_t numValidPix,
		double deblend_mincont) {

	float time;
	////////////////////////////////////////

	int 		*d_update;
	int 		*h_update;
	size_t	 	h_numPixAboveThresh;

	dim3 grid((width - 1) / SQUARE_BLK_WIDTH + 1,
			 (height - 1) / SQUARE_BLK_HEIGHT + 1);
	dim3 block(SQUARE_BLK_WIDTH, SQUARE_BLK_HEIGHT);

	checkCudaErrors(cudaMalloc((void**)(&d_update), sizeof(int)));

	h_update = (int*) malloc(sizeof(int));
	h_finalValidObj = (size_t*) malloc(n_thresh*sizeof(size_t));
	h_finalValidPix = (size_t*) malloc(n_thresh*sizeof(size_t));

	h_finalValidObj[0] = numValidObj;
	h_finalValidPix[0] = numValidPix;

	init_level0();
	////////////////////////////////

	for(int i=1; i<n_thresh; i++) {

		cudaEventRecord(start, 0);

		//can also be initialized by kernel with size h_finalValidPix[0]
		checkCudaErrors(cudaMemset(d_labelArray, -1, width * height * sizeof(int)));
		checkCudaErrors(cudaMemset(d_equivArray, -1, width * height * sizeof(int)));
		//width * height was replaced with (int)h_finalValidPix[i-1]
		checkCudaErrors(cudaMemset(d_compactMask, 0, (int)h_finalValidPix[i-1] * sizeof(unsigned int)));

		int grid_pix = (((int)h_finalValidPix[i-1]-1)/(MAX_THREADS_PER_BLK)+1);
		int block_pix = (MAX_THREADS_PER_BLK);

		deblendInit_kernel<<<grid_pix, block_pix>>>(d_cdPixArray,
				d_labelArray,
				d_equivArray,
				d_compactMask,
				d_finalDebPixelIndexArray[i-1],
				d_rootLabelArray,
				d_multiThreshArray,
				h_finalValidObj[0],
				h_finalValidPix[i-1],
				i);

		CUDPPResult res;

		////////////////////////////////////
		//compact the index array(also label array before detection)

		//create the configuration for compact
		//CUDPPConfiguration compactconfig;
		config.datatype = CUDPP_INT;
		config.algorithm = CUDPP_COMPACT;

		//create the cudpp compact plan
		//CUDPPHandle compact;
		res = cudppPlan(theCudpp, &compactplan, config, (int)h_finalValidPix[i-1], 1, 0);
		if (CUDPP_SUCCESS != res)
		{
			printf("Error creating CUDPP compact Plan in %s at line %d\n", __FILE__, __LINE__);
			exit(-1);
		}

		// Run the compact for index array
		res = cudppCompact(compactplan, d_compactedIndexArray, d_numPixAboveThresh,
				d_finalDebPixelIndexArray[i-1],
				d_compactMask,
				(int)h_finalValidPix[i-1]);
		if (CUDPP_SUCCESS != res)
		{
			printf("Error running CUDPP compact in %s at line %d\n", __FILE__, __LINE__);
			exit(-1);
		}

		//Run the compact for parent label array
		res = cudppCompact(compactplan, d_compactedParentLabel, d_numPixAboveThresh,
				d_finalDebLabelArray[i-1],
				d_compactMask,
				(int)h_finalValidPix[i-1]);
		if (CUDPP_SUCCESS != res)
		{
			printf("Error running CUDPP compact in %s at line %d\n", __FILE__, __LINE__);
			exit(-1);
		}

		// Destroy the int compact plan
		res = cudppDestroyPlan(compactplan);
		checkcudppSuccess(res, "Error destroying CUDPP compact Plan");

		cudaMemcpy(&h_numPixAboveThresh, d_numPixAboveThresh, sizeof(size_t), cudaMemcpyDeviceToHost);
		/////////////////////////////////////////////
		//end of compact

		int count = 0;
		int detection_grid = ((int)h_numPixAboveThresh-1)/(MAX_THREADS_PER_BLK)+1;
		int detection_block = (MAX_THREADS_PER_BLK);

		while(1) {
			*h_update = 0;
			cudaMemcpy(d_update, h_update, sizeof(int), cudaMemcpyHostToDevice);
			scanKernel1<<<detection_grid, detection_block>>>(d_labelArray,
					d_equivArray,
					d_compactedIndexArray,
					h_numPixAboveThresh,
					width,
					height,
					d_update);

			analysisKernel1<<<detection_grid, detection_block>>>(d_labelArray,
					d_equivArray,
					d_compactedIndexArray,
					h_numPixAboveThresh);

			/*labellingKernek1<<<detection_grid, detection_block>>>(d_labelArray,
					d_equivArray,
					d_compactedIndexArray,
					h_numPixAboveThresh);*/

//			cudaMemcpy(d_labelArray, d_equivArray, width*height*sizeof(int), cudaMemcpyDeviceToDevice);
			cudaMemcpy(h_update, d_update, sizeof(int), cudaMemcpyDeviceToHost);
			count++;

			if(!(*h_update))
				break;
		}

		h_finalValidPix[i] = compact_and_sort1((int)h_numPixAboveThresh, i, deb_minarea, n_thresh);
		h_finalValidObj[i] = pre_analyse1((int)h_numPixAboveThresh, (int)h_finalValidPix[i], i, n_thresh);

		cudaEventRecord(stop, 0);
		cudaEventSynchronize(stop);
		cudaEventElapsedTime(&time, start, stop);

//#ifdef DEBUG_CUDA
		printf("deblend level\t%d\t%d\t%d\t%f\n", i, h_finalValidPix[i], h_finalValidObj[i], time);
//#endif

		//printf("level\t%d\t%d\t%d\n", i, (int)h_finalValidPix[i], (int)h_finalValidObj[i]);
	}

	int numdetected = cut_branch(n_thresh, deblend_mincont);

	/////////////////////////////////////////////////////////////
	checkCudaErrors(cudaFree(d_update));

	free(h_update);
	free(h_finalValidObj);
	free(h_finalValidPix);
	//////////////

	return numdetected;
}

/**
 * allocated global vars: d_compactedDebLabelArray[level],
 * 						  d_compactedDebPixelArray[level],
 * 						  d_compactedDebCdPixelArray[level]
 * 						  d_segmentDebMask[level]
 */
int compact_and_sort1(int numpix, int level, int ext_minarea, int nthresh)
{
	static size_t	*d_numValidPix;
	size_t  	h_numValidPix;

	if(level==1)
	checkCudaErrors(cudaMalloc((void**) &d_numValidPix, sizeof(size_t)));

	CUDPPResult res;
	static unsigned int *d_compactedLabelArray_t;

	int grid = (numpix-1)/(MAX_THREADS_PER_BLK)+1;
	int block = (MAX_THREADS_PER_BLK);

	if(level == 0)
		checkCudaErrors(cudaMalloc( (void**) &d_compactedLabelArray, numpix * sizeof(unsigned int)));

	getLabelFromIndexKernel<<<grid, block>>>(d_compactedIndexArray,
			d_labelArray,
			d_compactedLabelArray,
			numpix);

	////////////////////////////////////////////
	// Create the configuration for sort
	config.datatype = CUDPP_INT;
	config.algorithm = CUDPP_SORT_RADIX;
	config.options = CUDPP_OPTION_KEY_VALUE_PAIRS;

	//create the cudpp sort plan
	res = cudppPlan(theCudpp, &sortplan, config, numpix, 1, 0);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error creating CUDPP sort Plan in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	if(level > 0)
	{
		if(level == 1)
			checkCudaErrors(cudaMalloc( (void**) &d_compactedLabelArray_t, numpix * sizeof(unsigned int)));

		checkCudaErrors(cudaMemcpy(d_compactedLabelArray_t, d_compactedLabelArray,
				numpix*sizeof(unsigned int), cudaMemcpyDeviceToDevice));

		res = cudppRadixSort(sortplan, d_compactedLabelArray_t, d_compactedParentLabel, numpix);
		if (CUDPP_SUCCESS != res)
		{
			printf("Error in cudppSort() for sorting compacted labels in %s at line %d\n", __FILE__, __LINE__);
			exit(-1);
		}

		if(level == nthresh-1) //?????
			checkCudaErrors(cudaFree(d_compactedLabelArray_t));
	}

	// Run the sort
	res = cudppRadixSort(sortplan, d_compactedLabelArray, d_compactedIndexArray, numpix);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error in cudppSort() for sorting compacted labels in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	// Destroy the sort plan
	res = cudppDestroyPlan(sortplan);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error destroying CUDPP sort Plan in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	//initialize the segment mask array according to the compacted label array.
	//(1 for the start pos of a segment, 0 otherwise)
	segmentMaskInitKernel<<<grid, block>>>(d_compactedLabelArray,
			d_segmentMask,
			d_pixelCountMask,
			numpix);

	//create prefix scan configuration
	config.op = CUDPP_ADD;
	config.datatype = CUDPP_UINT;
	config.algorithm = CUDPP_SEGMENTED_SCAN;
	config.options = CUDPP_OPTION_BACKWARD | CUDPP_OPTION_INCLUSIVE;

	//create segment prefix scan plan
	res = cudppPlan(theCudpp, &scanplan, config, numpix, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP segment mask array scan Plan");

	res = cudppSegmentedScan(scanplan,
			d_pixelCountSegment,
			d_pixelCountMask,
			d_segmentMask,
			numpix);
	checkcudppSuccess(res, "Error in running the segment pixel count scan");

	// Destroy the segment prefix scan plan
	res = cudppDestroyPlan(scanplan);
	checkcudppSuccess(res, "Error destroying CUDPP segment pixel count scan Plan");

	segmentmask_prune_kernel<<<grid, block>>>(
			d_segmentMask,
			d_prunedSegmentMask,
			d_pixelCountSegment,
			numpix,
			ext_minarea);

	//create forward segment scan configuration(to compact the label and index array)
	config.op = CUDPP_ADD;
	config.datatype = CUDPP_UINT;
	config.algorithm = CUDPP_SEGMENTED_SCAN;
	config.options = CUDPP_OPTION_FORWARD | CUDPP_OPTION_INCLUSIVE;

	//create prefix scan plan
	res = cudppPlan(theCudpp, &segscanplan, config, numpix, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP backward segment scan Plan(for segment end mask scan)");

	//perform a forward segment sum scan of the segment mask array (for label and index array compact)
	res = cudppSegmentedScan(segscanplan, d_compactMask, d_prunedSegmentMask,
			d_segmentMask, numpix);
	checkcudppSuccess(res, "Error in running the segment sum scan(for segment end mask array)");

	// Destroy the segment scan plan
	res = cudppDestroyPlan(segscanplan);
	checkcudppSuccess(res, "Error destroying CUDPP prefix scan Plan(for segment end mask array)");

	//create sum reduce configuration(for computing the num. valid pixels).
	config.op = CUDPP_ADD;
	config.datatype = CUDPP_UINT;
	config.algorithm = CUDPP_REDUCE;

	res = cudppPlan(theCudpp, &reduceplan, config, numpix, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP reduce Plan(to get the num. of valid pixels)");

	res = cudppReduce(reduceplan, d_numValidPix, d_compactMask, numpix);
	checkcudppSuccess(res, "Error in running the  CUDPP reduce(to get the num. of valid pixels)");

	// Destroy the reduce plan
	res = cudppDestroyPlan(reduceplan);
	checkcudppSuccess(res, "Error destroying CUDPP reduce Plan(to get the num. of valid pixels)");

	checkCudaErrors(cudaMemcpy(&h_numValidPix, d_numValidPix, sizeof(size_t), cudaMemcpyDeviceToHost));

	//checkCudaErrors(cudaMalloc((void**) &d_finalPixelIndexArray, (int)(h_numValidPix*sizeof(unsigned int))));
	//checkCudaErrors(cudaMalloc((void**) &d_finalLabelArray, (int)(h_numValidPix*sizeof(unsigned int))));

	checkCudaErrors(cudaMalloc((void**) &d_finalDebPixelIndexArray[level], (int)h_numValidPix*sizeof(unsigned int)));
	checkCudaErrors(cudaMalloc((void**) &d_finalDebLabelArray[level], (int)h_numValidPix*sizeof(unsigned int)));

	//create compact scan configuration(for the final compact of label and index array).
	config.datatype = CUDPP_UINT;
	config.algorithm = CUDPP_COMPACT;

	res = cudppPlan(theCudpp, &compactplan, config, numpix, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP compact Plan(for the final compact of label and index array)");

	//the content of segment mask has been changed here
	res = cudppCompact(compactplan,
			d_segmentMask,
			d_numValidPix,
			d_prunedSegmentMask,
			d_compactMask,
			numpix);
	checkcudppSuccess(res, "Error running final label compact");

	res = cudppCompact(compactplan,
			d_finalDebPixelIndexArray[level],
			d_numValidPix,
			d_compactedIndexArray,
			d_compactMask,
			numpix);

	// Destroy the compact plan
	res = cudppDestroyPlan(compactplan);
	checkcudppSuccess(res, "Error running final index compact");

	//create prefix sum scan configuration(to make the final labels consecutive).
	config.op = CUDPP_ADD;
	config.datatype = CUDPP_INT;
	config.algorithm = CUDPP_SCAN;
	config.options = CUDPP_OPTION_FORWARD | CUDPP_OPTION_INCLUSIVE;

	//create prefix scan plan
	res = cudppPlan(theCudpp, &scanplan, config, (int)h_numValidPix, 1, 0);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error creating CUDPP segment mask array scan Plan\n");
		exit(-1);
	}

	//perform a prefix sum scan of the segment mask array and output the result to the compacted label array
	//as consecutive labels
	res = cudppScan(scanplan, d_finalDebLabelArray[level], d_segmentMask, (int)h_numValidPix);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error in running the segment mask scan\n");
		exit(-1);
	}

	// Destroy the prefix scan plan
	res = cudppDestroyPlan(scanplan);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error destroying CUDPP prefix scan Plan\n");
		exit(-1);
	}

	if(level==nthresh-1)
		cudaFree(d_numValidPix);

	return (int)h_numValidPix;
}


/**
 *  allocated but not freed global array in this method:
 *	d_debPixelCountArray (d_deb***Array totally 10)
 *	d_finalDebPixelIndexArray
 *	d_finalDebObjIndexArray
 *	d_finalDebLabelArray
 *	d_debParentLabel
 *
 *	deleted global vars:
 *
 *	d_compactedDebIndexArray
	d_compactedDebLabelArray
	d_compactedDebPixelArray
	d_compactedDebCdPixelArray
	d_segmentDebMask
	d_compactedDebParentLabel
 */
int pre_analyse1(int npixAbovethresh,
		int		numValidPix,
		int level,
		int nthresh) {

	//reserved space to place the final result for pre-analysis
	//one elements for each objects
	static unsigned int	*d_numValidObj;
	unsigned int	h_numValidObj;

	static size_t		*d_numCompactedObj;

	if(level == 1)
	{
		//checkCudaErrors(cudaMalloc((void**) &d_prunedSegmentMask, compactedArraysize*sizeof(unsigned int)));
		checkCudaErrors(cudaMalloc((void**) &d_numValidObj, sizeof(unsigned int)));
	}

	int grid = (numValidPix-1)/(MAX_THREADS_PER_BLK)+1;
	int block = (MAX_THREADS_PER_BLK);

	//initialize the compacted cd pixel array according to the original pixel array
	//and the compacted index array.
	getPixelFromIndexKernel<<<grid, block>>>(d_finalDebPixelIndexArray[level],
			d_cdPixArray, d_compactedcdPixelArray, numValidPix);

	////////////////////////////////////////////////////
	//create float sum scan configuration(for fdflux).
	CUDPPConfiguration scanconfig;
	scanconfig.op = CUDPP_ADD;
	scanconfig.datatype = CUDPP_FLOAT;
	scanconfig.algorithm = CUDPP_SEGMENTED_SCAN;
	scanconfig.options = CUDPP_OPTION_BACKWARD | CUDPP_OPTION_INCLUSIVE;

	CUDPPResult res = cudppPlan(theCudpp, &scanplan, scanconfig, numValidPix, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP segment float sum scan Plan");

	res = cudppSegmentedScan(scanplan,
			d_fdfluxSegment,
			d_compactedcdPixelArray, //?????
			d_segmentMask,
			numValidPix);
	checkcudppSuccess(res, "Error in running the segment fdflux scan");

	// Destroy the segment prefix scan plan
	res = cudppDestroyPlan(scanplan);
	checkcudppSuccess(res, "Error destroying CUDPP segment float sum scan Plan");

	////////////////////////////////////////////////////

	//create sum reduce configuration(for computing the num. valid objs).
	config.op = CUDPP_ADD;
	config.datatype = CUDPP_UINT;
	config.algorithm = CUDPP_REDUCE;

	res = cudppPlan(theCudpp, &scanplan, config, numValidPix, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP reduce Plan(to get the num. of valid obj)");

	res = cudppReduce(scanplan,
			d_numValidObj,
			d_segmentMask,
			numValidPix);
	checkcudppSuccess(res, "Error in running the  CUDPP reduce(to get the num. of valid obj)");

	// Destroy the reduce plan
	res = cudppDestroyPlan(scanplan);
	checkcudppSuccess(res, "Error destroying CUDPP reduce Plan(to get the num. of valid obj)");

	cudaMemcpy(&h_numValidObj, d_numValidObj, sizeof(unsigned int), cudaMemcpyDeviceToHost);

	///////////////////////////////////////////////////

	//allocate memory space to store the valid object properties.
	checkCudaErrors(cudaMalloc((void**) &d_debPixelCountArray[level], h_numValidObj*sizeof(unsigned int)));
	checkCudaErrors(cudaMalloc((void**) &d_debFdfluxArray[level], h_numValidObj*sizeof(float)));
	checkCudaErrors(cudaMalloc((void**) &d_debDthresh[level], 	h_numValidObj*sizeof(float)));
	checkCudaErrors(cudaMalloc((void**) &d_debOk[level], 		h_numValidObj*sizeof(unsigned int)));
	checkCudaErrors(cudaMalloc((void**) &d_debParentLabel[level], h_numValidObj*sizeof(unsigned int)));
	checkCudaErrors(cudaMalloc((void**) &d_finalDebObjIndexArray[level], h_numValidObj*sizeof(unsigned int)));
	////////////////////////////////////////////////////
	if(level == 1)
	{
		checkCudaErrors(cudaMalloc((void**) &d_numCompactedObj, sizeof(size_t)));
	}

	//create compact scan configuration(for computing the properties of valid objs).
	//CUDPPConfiguration compactconfig1;
	config.datatype = CUDPP_INT;
	config.algorithm = CUDPP_COMPACT;
	config.options = CUDPP_OPTION_FORWARD | CUDPP_OPTION_INCLUSIVE;

	//create the cudpp compact plan
	res = cudppPlan(theCudpp, &compactplan, config, npixAbovethresh, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP compact Plan(to compute the properties of objs in deb)");

	res = cudppCompact(compactplan,
			d_debPixelCountArray[level],
			d_numCompactedObj,
			d_pixelCountSegment,
			d_prunedSegmentMask,
			npixAbovethresh);
	checkcudppSuccess(res, "Error in running the  CUDPP compact (to compute the d_pixelCountArray properties of valid objs)");

	res = cudppCompact(compactplan,
			d_debParentLabel[level],
			d_numCompactedObj,
			d_compactedParentLabel,
			d_prunedSegmentMask,
			npixAbovethresh);
	checkcudppSuccess(res, "Error in running the  CUDPP compact (to compute the d_ymaxArray properties of valid objs)");

	// Destroy the compact plan
	res = cudppDestroyPlan(compactplan);
	checkcudppSuccess(res, "Error destroying CUDPP compact Plan(to compute the int properties of valid objs)");

	///////////////////////////////////////////////
	//create compact scan configuration(for computing the properties of valid objs).
	config.datatype = CUDPP_FLOAT;
	config.algorithm = CUDPP_COMPACT;
	config.options = CUDPP_OPTION_FORWARD | CUDPP_OPTION_INCLUSIVE;

	res = cudppPlan(theCudpp, &compactplan, config, numValidPix, 1, 0);
	checkcudppSuccess(res, "Error creating CUDPP compact Plan(to compute the float properties of valid objs)");

	res = cudppCompact(compactplan,
			d_debFdfluxArray[level],
			d_numCompactedObj,
			d_fdfluxSegment,
			d_segmentMask,
			numValidPix);
	checkcudppSuccess(res, "Error in running the  CUDPP compact (to compute the d_fdfluxArray properties of valid objs)");

	// Destroy the compact plan
	res = cudppDestroyPlan(compactplan);
	checkcudppSuccess(res, "Error destroying CUDPP compact Plan(to compute the float properties of valid objs)");


	////////////////////////////////////////////////////////////////

	int grid1 = (h_numValidObj-1)/(MAX_THREADS_PER_BLK)+1;
	int block1 = (MAX_THREADS_PER_BLK);

	okInit_kernel<<<grid1, block1>>>(d_debOk[level], h_numValidObj);

////////////////////////////////////////////////////////////

	//create prefix sum scan configuration(to record the pos of each obj in final index array).
	scanconfig.op = CUDPP_ADD;
	scanconfig.datatype = CUDPP_UINT;
	scanconfig.algorithm = CUDPP_SCAN;
	scanconfig.options = CUDPP_OPTION_FORWARD | CUDPP_OPTION_EXCLUSIVE;

	//create prefix scan plan
	scanplan = 0;
	res = cudppPlan(theCudpp, &scanplan, scanconfig, h_numValidObj, 1, 0);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error creating CUDPP segment mask array scan Plan\n");
		exit(-1);
	}

	//perform a prefix sum scan of the pixel count array and output the result to d_finalObjIndexArray
	res = cudppScan(scanplan, d_finalDebObjIndexArray[level], d_debPixelCountArray[level], h_numValidObj);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error in running the segment mask scan\n");
		exit(-1);
	}

	// Destroy the prefix scan plan
	res = cudppDestroyPlan(scanplan);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error destroying CUDPP prefix scan Plan\n");
		exit(-1);
	}
	/////////////////////////////////////////////////////////////

	//must be computed after get the right d_finalDebObjIndexArray
	debDthreshInit_kernel<<<grid1, block1>>>(d_debDthresh[level],
			d_finalDebObjIndexArray[level],
			d_finalDebPixelIndexArray[level],
			d_rootLabelArray,
			d_multiThreshArray,
			level,
			h_numValidObj,
			h_finalValidObj[0]);

	////////////////////////////////////////////////////////////

	if(level == nthresh-1)
	{
		checkCudaErrors(cudaFree(d_numValidObj));
		checkCudaErrors(cudaFree(d_numCompactedObj));
	}

	return h_numValidObj;
}

__global__ void objLevelLabelInit_kernel(
		unsigned int *d_cuttedObjLevelArray,
		unsigned int *d_cuttedObjLabelArray,
		int level,
		int	startbase,
		int h_numObjAfterCutting) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= h_numObjAfterCutting)
		return;

	d_cuttedObjLevelArray[tid] = level;
	d_cuttedObjLabelArray[tid] = startbase + tid;
}


__global__ void rootLabelArrayInit_kernel(
		unsigned int *d_cuttedRootLabelArray,
		unsigned int *d_pixelIndexArray,
		unsigned int *d_objIndexArray,
		int	*d_rootLabelArray,
		int h_numObjAfterCutting)
{
	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= h_numObjAfterCutting)
		return;

	unsigned int first_index = d_pixelIndexArray[d_objIndexArray[tid]];
	d_cuttedRootLabelArray[tid] = d_rootLabelArray[first_index];
}

//get the sorted result (leve 1 to n) from sorted label array
__global__ void getsortedresult_kernel(
		unsigned int *d_sortedLabelArray,
		unsigned int *d_sortedObjLevelArray,
		unsigned int *d_sortedObjIndexArray,
		unsigned int *d_sortedPixCountArray,
		float 		 *d_sortedDthreshArray,
		unsigned int *d_cuttedObjLevelArray,
		unsigned int *d_cuttedObjIndexArray,
		unsigned int *d_cuttedPixCountArray,
		float		 *d_cuttedDthreshArray,
		int numobj)
{
	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= numobj)
		return;

	int label = d_sortedLabelArray[tid];

	d_sortedObjLevelArray[tid] = d_cuttedObjLevelArray[label];
	d_sortedObjIndexArray[tid] = d_cuttedObjIndexArray[label];
	d_sortedPixCountArray[tid] = d_cuttedPixCountArray[label];
	d_sortedDthreshArray[tid]  = d_cuttedDthreshArray[label];
}

__global__ void rootlabelSegmentInitKernel(
		unsigned int *d_cuttedRootLabel,
		unsigned int *d_startpos,
		unsigned int numElements)
{
	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= numElements)
		return;

	int rootlabel = d_cuttedRootLabel[tid];

	if (tid == 0)
		d_startpos[rootlabel-1] = tid;

	else if (tid < numElements)
	{
		if (d_cuttedRootLabel[tid] > d_cuttedRootLabel[tid - 1])
		{
			d_startpos[rootlabel-1] = tid;
		}
	}
}


//each thread process an un-allocated pixel
__global__ void gatherup_kernel(
		int 		 *d_labelArray,		 //allocate label array
		unsigned int *d_cuttedRootLabel,
		unsigned int *d_finalLabelArray, //level 0 pixel label array
		unsigned int *d_pixelIndexArray, //level 0 pixel index array
		unsigned int *d_startPosArray,	 //start position array of each segment
		double		*d_mx,
		double		*d_my,
		float		*d_cxx,
		float		*d_cyy,
		float		*d_cxy,
		float		*d_abcor,
		float		*d_amp,
		int 		*d_allocateMap,
		int			width,
		unsigned int numpix)
{
	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= numpix)
		return;

	float dx, dy, dist, distmin, drand;
	int	 iclst;
	//foreach pix, scan the objects
	unsigned int index = d_pixelIndexArray[tid];
	int x = index % width;
	int y = index / width;

	int allocatelabel = d_labelArray[index];

	if(allocatelabel == -1)
	{
		int rootlabel = d_finalLabelArray[tid];
		//start position in the cutted***Array
		int startpos = d_startPosArray[rootlabel-1];

		int seglength = 0;

		distmin = 1e+31;
		iclst = 0;
		float p = 0.0;
		int i;
		//scan objects with same root label
		for(i=startpos; ; i++)
		{
			if(d_cuttedRootLabel[i] == rootlabel)
				seglength++;
			else
				break;

			dx = x - d_mx[i];
			dy = y - d_my[i];

			dist=0.5*(d_cxx[i]*dx*dx+d_cyy[i]*dy*dy+d_cxy[i]*dx*dy)/d_abcor[i];
			//p[i-startpos+1] = p[i-startpos] + (dist<70.0?d_amp[i]*exp(-dist) : 0.0);
			p += (dist<70.0?d_amp[i]*exp(-dist) : 0.0);
			if (dist<distmin)
			{
				distmin = dist;
				iclst = i;
			}
		}

//		if (p > 1.0e-31)
//		{
//			curandState_t state;
//			curand_init (tid , 0, 0, &state);
//
//			drand = p*curand_uniform (&state);
//
//			p = 0.0;
//			//for (i=1; i<nobj && p[i]<drand; i++);
//			for(i=startpos; i<startpos+seglength; i++)
//			{
//				dx = x - d_mx[i];
//				dy = y - d_my[i];
//
//				dist=0.5*(d_cxx[i]*dx*dx+d_cyy[i]*dy*dy+d_cxy[i]*dx*dy)/d_abcor[i];
//				//p[i-startpos+1] = p[i-startpos] + (dist<70.0?d_amp[i]*exp(-dist) : 0.0);
//				p += (dist<70.0?d_amp[i]*exp(-dist) : 0.0);
//
//				if(p >= drand)
//					break;
//			}
//			if (i == startpos+seglength)
//				i=iclst;
//		}
//		else
			i = iclst;

		d_allocateMap[tid] = i;
		d_labelArray[index] = i;
	}
	else
	{
		d_allocateMap[tid] = allocatelabel;
	}
}

__global__ void objpixelSegmentInit_kernel(
		int			 *d_allocateMap,
		unsigned int *objIndexArray,
		unsigned int numpix)
{
	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= numpix)
		return;

	int objIndex = d_allocateMap[tid];

	if (tid == 0)
		objIndexArray[objIndex] = tid;

	else if (tid < numpix)
	{
		if (d_allocateMap[tid] > d_allocateMap[tid - 1])
		{
			objIndexArray[objIndex] = tid;
		}
	}
}

__global__ void computeSegmentLength_kernel(
		unsigned int *d_startPosArray,
		unsigned int *d_lengthArray,
		unsigned int numobj,
		unsigned int numpix) {

	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid < numobj-1)
		d_lengthArray[tid] = d_startPosArray[tid+1] - d_startPosArray[tid];
	else if(tid == numobj-1)
	{
		d_lengthArray[tid] = numpix - d_startPosArray[tid];
	}
}

__global__ void resetDthresh_kernel(
		float	*d_cuttedDthreshArray,
		float	globaldthresh,
		unsigned int numobj)
{
	const int tid = blockDim.x * blockIdx.x + threadIdx.x;

	if(tid >= numobj)
		return;

	d_cuttedDthreshArray[tid] = globaldthresh;
}

//allocated but not freed object in this function.
//	d_cuttedObjLevelArray;
//	d_cuttedObjLabelArray;
//	d_cuttedObjIndexArray;
//	d_cuttedObjFlagArray;
//	d_cuttedPixCountArray;
//	d_cuttedRootlabelArray;
//	d_cuttedDthreshArray;
//  22 object attributes

int cut_branch(int n_thresh, double DEBLEND_MINCONT) {

	cudaEventRecord(start, 0);

	CUDPPResult res;
	int total = 0;

	unsigned int *d_numObjAfterCutting;
	size_t *d_numCompactedObj;

	unsigned int *h_numObjAfterCutting = (unsigned int*)malloc(n_thresh*sizeof(unsigned int));

	unsigned int	*d_numson;
	unsigned int	*d_flag;

	cudaMalloc((void**) &d_numObjAfterCutting, sizeof(unsigned int));
	cudaMalloc((void**) &d_numCompactedObj, sizeof(size_t));

	for(int level=n_thresh-1; level>=0; level--)
	{
		if(level > 0)
		{
			int grid_obj = ((int)h_finalValidObj[level]-1)/(MAX_THREADS_PER_BLK)+1;
			int block_obj = (MAX_THREADS_PER_BLK);

			checkCudaErrors(cudaMalloc((void**) &d_flag, (int)(h_finalValidObj[level]*sizeof(unsigned int))));
			checkCudaErrors(cudaMalloc((void**) &d_numson, (int)(h_finalValidObj[level-1]*sizeof(unsigned int))));
			checkCudaErrors(cudaMemset(d_numson, 0, (int)(h_finalValidObj[level-1]*sizeof(unsigned int))));

			decidePrune1_kernel<<<grid_obj, block_obj>>>(
					d_flag,
					d_numson,
					d_debFdfluxArray[level],
					d_debDthresh[level],
					d_debPixelCountArray[level],
					d_finalDebPixelIndexArray[level],
					d_finalDebObjIndexArray[level],
					d_debOk[level],
					d_debOk[level-1],
					d_debParentLabel[level],
					d_rootLabelArray,
					d_debFdfluxArray[0],
					h_finalValidObj[level],
					DEBLEND_MINCONT);

			decidePrune2_kernel<<<grid_obj, block_obj>>>(
					d_flag,
					d_numson,
					d_debOk[level],
					d_debOk[level-1],
					d_debParentLabel[level],
					h_finalValidObj[level]);

			checkCudaErrors(cudaFree(d_numson));
			checkCudaErrors(cudaFree(d_flag));
		}

		/* cut the output array to keep only the elements whose corresponding d_flag is 1.*/
		//get the number of remaining objects after cutting.
		config.op = CUDPP_ADD;
		config.datatype = CUDPP_UINT;
		config.algorithm = CUDPP_REDUCE;

		res = cudppPlan(theCudpp, &scanplan, config, h_finalValidObj[level], 1, 0);
		checkcudppSuccess(res, "Error creating CUDPP reduce Plan(in cutting)");

		res = cudppReduce(scanplan,
				d_numObjAfterCutting,
				d_debOk[level],
				h_finalValidObj[level]);
		checkcudppSuccess(res, "Error in running the  CUDPP reduce(in cutting)");

		// Destroy the reduce plan
		res = cudppDestroyPlan(scanplan);
		checkcudppSuccess(res, "Error destroying CUDPP reduce Plan(in cutting)");

		cudaMemcpy(&h_numObjAfterCutting[level], d_numObjAfterCutting, sizeof(unsigned int),
				cudaMemcpyDeviceToHost);

		total += h_numObjAfterCutting[level];

		//printf("%d\t%d\n", level, h_numObjAfterCutting[level]);

	}

#ifdef DEBUG_CUDA
	printf("Total number of cutted objects is %d\n", total);
#endif

	/* allocate memory for the cutted object arrays */
	cudaMalloc((void**) &d_cuttedObjLevelArray, total*sizeof(unsigned int));
	cudaMalloc((void**) &d_cuttedObjLabelArray, total*sizeof(unsigned int)); //used for sort
	cudaMalloc((void**) &d_cuttedObjIndexArray, total*sizeof(unsigned int)); //obj pos in pixel index
	cudaMalloc((void**) &d_cuttedPixCountArray, total*sizeof(unsigned int));
	cudaMalloc((void**) &d_cuttedRootlabelArray,total*sizeof(unsigned int));
	cudaMalloc((void**) &d_cuttedDthreshArray,  total*sizeof(float));
	cudaMalloc((void**) &d_cuttedObjFlagArray,  total*sizeof(unsigned int));

	cudaMemset(d_cuttedObjFlagArray, 0, total*sizeof(unsigned int));

	unsigned int *objlevel = d_cuttedObjLevelArray;
	unsigned int *objlabel = d_cuttedObjLabelArray;
	unsigned int *objindex = d_cuttedObjIndexArray;
	unsigned int *pixcount = d_cuttedPixCountArray;
	unsigned int *rootlabel= d_cuttedRootlabelArray;
	float		 *dthresh  = d_cuttedDthreshArray;

	init_objects(total);

	for(int level=0; level < n_thresh; level++)
	{
		if(level>0)
		{
			objlevel += h_numObjAfterCutting[level-1];
			objlabel += h_numObjAfterCutting[level-1];
			objindex += h_numObjAfterCutting[level-1];
			pixcount += h_numObjAfterCutting[level-1];
			rootlabel += h_numObjAfterCutting[level-1];
			dthresh += h_numObjAfterCutting[level-1];
		}
		if(h_numObjAfterCutting[level] == 0)
			continue;

		/* do compaction to get the real cutted objects */
		config.datatype = CUDPP_UINT;
		config.algorithm = CUDPP_COMPACT;
		config.options = CUDPP_OPTION_FORWARD | CUDPP_OPTION_INCLUSIVE;

		//create the cudpp compact plan
		res = cudppPlan(theCudpp, &compactplan, config, (int)h_finalValidObj[level], 1, 0);
		checkcudppSuccess(res, "Error creating CUDPP compact Plan (in cutting)");

		res = cudppCompact(compactplan,
				objindex,
				d_numCompactedObj,
				d_finalDebObjIndexArray[level],
				d_debOk[level],
				(int)h_finalValidObj[level]);
		checkcudppSuccess(res, "Error in running the  CUDPP compact (in cutting)");

		res = cudppCompact(compactplan,
				pixcount,
				d_numCompactedObj,
				d_debPixelCountArray[level],
				d_debOk[level],
				(int)h_finalValidObj[level]);
		checkcudppSuccess(res, "Error in running the  CUDPP compact (in cutting)");

		res = cudppDestroyPlan(compactplan);
		checkcudppSuccess(res, "Error destroying CUDPP compact Plan (in cutting)");

		/* compact dthresh array */
		config.datatype = CUDPP_FLOAT;
		config.algorithm = CUDPP_COMPACT;
		config.options = CUDPP_OPTION_FORWARD | CUDPP_OPTION_INCLUSIVE;

		//create the cudpp compact plan
		res = cudppPlan(theCudpp, &compactplan, config, (int)h_finalValidObj[level], 1, 0);
		checkcudppSuccess(res, "Error creating CUDPP compact Plan (in cutting)");

		res = cudppCompact(compactplan,
				dthresh,
				d_numCompactedObj,
				d_debDthresh[level],
				d_debOk[level],
				(int)h_finalValidObj[level]);
		checkcudppSuccess(res, "Error in running the  CUDPP compact (in cutting)");

		res = cudppDestroyPlan(compactplan);
		checkcudppSuccess(res, "Error destroying CUDPP compact Plan (in cutting)");

		///////////
		int grid_obj1 = (h_numObjAfterCutting[level]-1)/(MAX_THREADS_PER_BLK)+1;
		int block_obj1 = (MAX_THREADS_PER_BLK);

		//init the label and level array
		objLevelLabelInit_kernel<<<grid_obj1, block_obj1>>>(
				objlevel,
				objlabel,
				level,
				(objlevel-d_cuttedObjLevelArray),
				h_numObjAfterCutting[level]);

		//init the cutted root label array
		rootLabelArrayInit_kernel<<<grid_obj1, block_obj1>>>(
				rootlabel,
				d_finalDebPixelIndexArray[level],
				objindex,
				d_rootLabelArray,
				h_numObjAfterCutting[level]);
	}

	//sort the object by order of their root object number
	//takes about 1ms
	sortbyRootlabel(
			d_cuttedObjLevelArray,
			d_cuttedObjLabelArray,
			d_cuttedObjIndexArray,
			d_cuttedPixCountArray,
			d_cuttedRootlabelArray,
			d_cuttedDthreshArray,
			total);

	//mark the start of each segment, objects with the same
	//root label belongs to the same segment
	///////////////////////////////////////////////
	unsigned int *d_startPosArray;  //record the start position of each segment
	cudaMalloc((void**)&d_startPosArray, (int)(h_finalValidObj[0]*sizeof(unsigned int)));
	//cudaMalloc((void**)&d_segmentLength, h_finalValidObj[0]*sizeof(unsigned int));
	cudaMemset(d_startPosArray, -1, (int)(h_finalValidObj[0]*sizeof(unsigned int)));
	//cudaMemset(d_segmentLength, -1, h_finalValidObj[0]*sizeof(unsigned int));

	cudaError_t err = cudaGetLastError();
	checkCudaErrors(err);

	int grid_obj2 = (total-1)/(MAX_THREADS_PER_BLK)+1;
	int block_obj2 = (MAX_THREADS_PER_BLK);

	//mark the start pos of each segment in obj array into d_startPosArray
	rootlabelSegmentInitKernel<<<grid_obj2, block_obj2>>>(
			d_cuttedRootlabelArray,
			d_startPosArray,
			total);

	//full preanalysis
	float *d_amp;	//gatherup attribute
	cudaMalloc((void**)&d_amp,		total*sizeof(float));

	//use the labelArray as allocate map(do we really need this?)
	//maybe we can find a way to record this in an array with (level 0 pixel array) length
	cudaMemset(d_labelArray, -1, width*height*sizeof(int));

	unsigned int **d_pixelIndexArray;
	cudaMalloc((void**) &d_pixelIndexArray, n_thresh*sizeof(unsigned int*));
	cudaMemcpy(d_pixelIndexArray,
			d_finalDebPixelIndexArray,
			n_thresh*sizeof(unsigned int*),
			cudaMemcpyHostToDevice);

	int grid_obj3 = (total-1)/(MAX_THREADS_PER_BLK)+1;
	int block_obj3 = (MAX_THREADS_PER_BLK);

	int plistexist_dthresh = 0;
	//pre analyse objects
	//initialize gatherup attributes(allocatemap and amp array)
	preanalyse_full_kernel<<<grid_obj3, block_obj3>>>(
			d_cuttedObjLevelArray,
			d_cuttedObjIndexArray,
			d_cuttedPixCountArray,
			d_cuttedObjFlagArray,
			d_cuttedDthreshArray,
			d_cdPixArray,
			d_pixelArray,
			d_labelArray,
			d_pixelIndexArray,
			/* output starts */
			d_xmin,
			d_xmax,
			d_ymin,
			d_ymax,
			d_dnpix,
			d_mx,
			d_my,
			d_mx2,
			d_my2,
			d_mxy,
			d_cxx,
			d_cxy,
			d_cyy,
			d_a,
			d_b,
			d_theta,
			d_abcor,
			d_fdpeak,
			d_dpeak,
			d_fdflux,
			d_dflux,
			d_singuflag,
			d_amp,
			/* output ends */
			width,
			height,
			thresh,
			plistexist_dthresh,
			ANALYSE_FULL,
			total);

	resetDthresh_kernel<<<grid_obj3, block_obj3>>>(
			d_cuttedDthreshArray,
			global_dthresh,
			total);

	//gatherup
	//1) get un-allocated pixel
	//2)
	//3)

	int *d_allocateMap;
	cudaMalloc((void**)&d_allocateMap, (int)(h_finalValidPix[0]*sizeof(int)));
	cudaMemset(d_allocateMap, -1,  (int)(h_finalValidPix[0]*sizeof(int)));

	int grid_obj4 = ((int)h_finalValidPix[0]-1)/(MAX_THREADS_PER_BLK)+1;
	int block_obj4 = (MAX_THREADS_PER_BLK);

	gatherup_kernel<<<grid_obj4, block_obj4>>>(
			d_labelArray,		 	//allocate label array
			d_cuttedRootlabelArray,
			d_finalLabelArray, 		//level 0 pixel label array
			d_finalPixelIndexArray, //level 0 pixel index array
			d_startPosArray,	 	//start position array of each segment
			d_mx,
			d_my,
			d_cxx,
			d_cyy,
			d_cxy,
			d_abcor,
			d_amp,
			d_allocateMap,
			width,
			(int)h_finalValidPix[0]);

	//sort d_finalPixelIndexArray according to allocate map
	//and mask the start position of each object
	//then pixels belong to the same object will form a segment
	sortPixelByObj(d_finalPixelIndexArray,
			d_allocateMap,
			d_cuttedObjIndexArray,
			d_cuttedPixCountArray,
			(int)h_finalValidPix[0],
			total);

	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	float time;
	cudaEventElapsedTime(&time, start, stop);

#ifdef DEBUG_CUDA
	printf("Time counsumed by deblend cut branch is: %f\n", time);
#endif

	///////////////////

	free(h_numObjAfterCutting);
	checkCudaErrors(cudaFree(d_pixelIndexArray));
	checkCudaErrors(cudaFree(d_allocateMap));
	checkCudaErrors(cudaFree(d_amp));
	checkCudaErrors(cudaFree(d_startPosArray));
	checkCudaErrors(cudaFree(d_numObjAfterCutting));
	checkCudaErrors(cudaFree(d_numCompactedObj));

	return total;
}

void sortbyRootlabel(
		unsigned int *d_cuttedObjLevelArray,
		unsigned int *d_cuttedObjLabelArray,
		unsigned int *d_cuttedObjIndexArray,
		unsigned int *d_cuttedPixCountArray,
		unsigned int *d_cuttedRootlabelArray,
		float 		 *d_cuttedDthreshArray,
		int total)
{
	CUDPPResult res;

	//sort the cutted object by root label
	//CUDPPConfiguration sort_config;
	config.datatype = CUDPP_INT;
	config.algorithm = CUDPP_SORT_RADIX;
	config.options = CUDPP_OPTION_KEY_VALUE_PAIRS;

	//create the cudpp sort plan
	//CUDPPHandle sortplan = 0;
	res = cudppPlan(theCudpp, &sortplan, config, total, 1, 0);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error creating CUDPP sort Plan in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	// Run the sort
	res = cudppRadixSort(sortplan,
			d_cuttedRootlabelArray,
			d_cuttedObjLabelArray,
			total);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error in cudppSort() for sorting compacted labels in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	// Destroy the sort plan
	res = cudppDestroyPlan(sortplan);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error destroying CUDPP sort Plan in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	unsigned int *d_sortedObjLevelArray;
	unsigned int *d_sortedObjIndexArray;
	unsigned int *d_sortedPixCountArray;
	float 		 *d_sortedDthreshArray;

	cudaMalloc((void**) &d_sortedObjLevelArray, total*sizeof(unsigned int));
	cudaMalloc((void**) &d_sortedObjIndexArray, total*sizeof(unsigned int));
	cudaMalloc((void**) &d_sortedPixCountArray, total*sizeof(unsigned int));
	cudaMalloc((void**) &d_sortedDthreshArray,  total*sizeof(float));

	int grid_obj2 = (total-1)/(MAX_THREADS_PER_BLK)+1;
	int block_obj2 = (MAX_THREADS_PER_BLK);

	//get sorted result from sorted label array.
	getsortedresult_kernel<<<grid_obj2, block_obj2>>>(
			d_cuttedObjLabelArray,
			d_sortedObjLevelArray,
			d_sortedObjIndexArray,
			d_sortedPixCountArray,
			d_sortedDthreshArray,
			d_cuttedObjLevelArray,
			d_cuttedObjIndexArray,
			d_cuttedPixCountArray,
			d_cuttedDthreshArray,
			total);

	//copy the sorted result back
	cudaMemcpy(d_cuttedObjLevelArray,
			d_sortedObjLevelArray,
			total*sizeof(unsigned int),
			cudaMemcpyDeviceToDevice);

	cudaMemcpy(d_cuttedObjIndexArray,
			d_sortedObjIndexArray,
			total*sizeof(unsigned int),
			cudaMemcpyDeviceToDevice);

	cudaMemcpy(d_cuttedPixCountArray,
			d_sortedPixCountArray,
			total*sizeof(unsigned int),
			cudaMemcpyDeviceToDevice);

	cudaMemcpy(d_cuttedDthreshArray,
			d_sortedDthreshArray,
			total*sizeof(float),
			cudaMemcpyDeviceToDevice);

	checkCudaErrors(cudaFree(d_sortedObjLevelArray));
	checkCudaErrors(cudaFree(d_sortedObjIndexArray));
	checkCudaErrors(cudaFree(d_sortedPixCountArray));
	checkCudaErrors(cudaFree(d_sortedDthreshArray));
}

void sortPixelByObj(
		unsigned int *d_finalPixelIndexArray,
		int 		 *d_allocateMap,
		unsigned int *d_objIndexArray,
		unsigned int *d_pixelCountArray,
		int numpix,
		int numobj)
{
	CUDPPResult res;

	//sort the cutted object by root label
	//CUDPPConfiguration sort_config;
	config.datatype = CUDPP_INT;
	config.algorithm = CUDPP_SORT_RADIX;
	config.options = CUDPP_OPTION_KEY_VALUE_PAIRS;

	//create the cudpp sort plan
	res = cudppPlan(theCudpp, &sortplan, config, numpix, 1, 0);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error creating CUDPP sort Plan in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	// Run the sort
	res = cudppRadixSort(sortplan,
			d_allocateMap,
			d_finalPixelIndexArray,
			numpix);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error in cudppSort() for sorting compacted labels in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	// Destroy the sort plan
	res = cudppDestroyPlan(sortplan);
	if (CUDPP_SUCCESS != res)
	{
		printf("Error destroying CUDPP sort Plan in %s at line %d\n", __FILE__, __LINE__);
		exit(-1);
	}

	int grid = (numpix-1)/(MAX_THREADS_PER_BLK)+1;
	int block = (MAX_THREADS_PER_BLK);

	objpixelSegmentInit_kernel<<<grid, block>>>(
			d_allocateMap,
			d_objIndexArray,
			numpix);

	int grid1 = (numobj-1)/(MAX_THREADS_PER_BLK)+1;
	int block1 = (MAX_THREADS_PER_BLK);

	computeSegmentLength_kernel<<<grid1, block1>>>(
			d_objIndexArray,
			d_pixelCountArray,
			numobj,
			numpix);
}

extern "C" void clear_deblend(int _deblend_nthresh) {

	//destroy the result for deb compact and sort.

	free(d_debPixelCountArray);
	free(d_debFdfluxArray);
	free(d_debDthresh);

	free(d_debOk);
	free(d_debParentLabel);

	free(d_finalDebObjIndexArray);
	free(d_finalDebPixelIndexArray);
	free(d_finalDebLabelArray);

	checkCudaErrors(cudaFree(d_multiThreshArray));
	checkCudaErrors(cudaFree(d_rootLabelArray));

	//another 11 global vars to be freed
}
