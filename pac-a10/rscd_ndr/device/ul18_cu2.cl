#define _OPENCL_COMPILER_

#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable
#pragma OPENCL EXTENSION cl_khr_global_int32_extended_atomics : enable

#include "common.h"


// Generate model on FPGA side
int gen_model_param(int x1, int y1, int vx1, int vy1, int x2, int y2, int vx2, int vy2, float *model_param) {
    float temp;
    // xc -> model_param[0], yc -> model_param[1], D -> model_param[2], R -> model_param[3]
    temp = (float)((vx1 * (vx1 - (2 * vx2))) + (vx2 * vx2) + (vy1 * vy1) - (vy2 * ((2 * vy1) - vy2)));
    if(temp == 0) { // Check to prevent division by zero
        return (0);
    }
    model_param[0] = (((vx1 * ((-vx2 * x1) + (vx1 * x2) - (vx2 * x2) + (vy2 * y1) - (vy2 * y2))) +
                          (vy1 * ((-vy2 * x1) + (vy1 * x2) - (vy2 * x2) - (vx2 * y1) + (vx2 * y2))) +
                          (x1 * ((vy2 * vy2) + (vx2 * vx2)))) /
                      temp);
    model_param[1] = (((vx2 * ((vy1 * x1) - (vy1 * x2) - (vx1 * y1) + (vx2 * y1) - (vx1 * y2))) +
                          (vy2 * ((-vx1 * x1) + (vx1 * x2) - (vy1 * y1) + (vy2 * y1) - (vy1 * y2))) +
                          (y2 * ((vx1 * vx1) + (vy1 * vy1)))) /
                      temp);

    temp = (float)((x1 * (x1 - (2 * x2))) + (x2 * x2) + (y1 * (y1 - (2 * y2))) + (y2 * y2));
    if(temp == 0) { // Check to prevent division by zero
        return (0);
    }
    model_param[2] = ((((x1 - x2) * (vx1 - vx2)) + ((y1 - y2) * (vy1 - vy2))) / temp);
    model_param[3] = ((((x1 - x2) * (vy1 - vy2)) + ((y2 - y1) * (vx1 - vx2))) / temp);
    return (1);
}

__kernel 
__attribute((num_compute_units(2)))
void RANSAC_kernel_block(int flowvector_count, int error_threshold, float convergence_threshold,
    __global flowvector *restrict flowvectors,  __global int *restrict random_numbers, 
	__global int *restrict model_candidate, __global int *restrict outliers_candidate, 
    __global int *g_out_id ) {
    
    const size_t iter = get_global_id(0);

    float vx_error, vy_error;
    int   outlier_local_count = 0;

	float model_param[4] = {0,0,0,0};
 
	// Select two random flow vectors
	flowvector fv[2];
    int rand_num = random_numbers[iter * 2 + 0];
    fv[0]    = flowvectors[rand_num];
    rand_num = random_numbers[iter * 2 + 1];
    fv[1]    = flowvectors[rand_num];

    int ret = 0;
    int vx1 = fv[0].vx - fv[0].x;
    int vy1 = fv[0].vy - fv[0].y;
    int vx2 = fv[1].vx - fv[1].x;
    int vy2 = fv[1].vy - fv[1].y;

    // Function to generate model parameters according to F-o-F (xc, yc, D and R)
    ret = gen_model_param(fv[0].x, fv[0].y, vx1, vy1, fv[1].x, fv[1].y, vx2, vy2, model_param);
    if(ret == 0)
		model_param[0] = -2011;
    
    if(model_param[0] != -2011){
		// Reset local outlier counter
		outlier_local_count = 0;

		// Compute number of outliers
		#pragma unroll 18
		for(int i = 0; i < flowvector_count; i ++) {
			flowvector fvreg = flowvectors[i]; // x, y, vx, vy
			vx_error = fvreg.x + ((int)((fvreg.x - model_param[0]) * model_param[2]) -
								 (int)((fvreg.y - model_param[1]) * model_param[3])) -
					   fvreg.vx;
			vy_error = fvreg.y + ((int)((fvreg.y - model_param[1]) * model_param[2]) +
								 (int)((fvreg.x - model_param[0]) * model_param[3])) -
					   fvreg.vy;
			if((fabs(vx_error) >= error_threshold) || (fabs(vy_error) >= error_threshold)) {
				outlier_local_count++;
			}
		}

		// Compare to threshold
		if(outlier_local_count < flowvector_count * convergence_threshold) {
			int index                 = atomic_add(g_out_id, 1);
			outliers_candidate[index] = outlier_local_count;
			model_candidate[index]    = iter;
		}
	}
}

