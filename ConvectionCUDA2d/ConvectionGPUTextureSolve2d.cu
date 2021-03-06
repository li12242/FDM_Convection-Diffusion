#include <cuda.h>

extern "C"
{

#include "ConvectionGPU2d.h"

//texture reference
texture<float> t_Q;
texture<float> t_rhs;
texture<float> t_bcFlag;

static float *d_Q;
static float *d_temp;
static float *d_rhs;
static float *d_bcFlag;

__constant__ physics d_phys;  // phys properties
__constant__ float d_dx,d_dy; // spacial interval
__constant__ int d_ndim1,d_ndim2;

//private functions
float getTimeInterval(structMesh *mesh, physics *phys, float CFL);
float** BCFlag_create(structMesh *mesh);
__global__ void AdvectionGPU2d(int Ntotal, float *d_rhs);
__global__ void DiffusionGPU2d(int Ntotal, float *d_rhs);
__global__ void TiemAdvectionGPU2d(int Ntotal, float *d_Q, float dt);
__global__ void SlopeLimiter(int Ntotal, float *d_temp, float *d_bcFlag);


void ConvectionGPUSolve2d(structMesh *mesh, physics *phys, 
	float **c, float finalTime){

	float time = 0.0f;
    float CFL  = 0.1f;
    int Ntotal = mesh->ndim1*mesh->ndim2;
    // calculate dt
    float dt = getTimeInterval(mesh, phys, CFL);

    // GPU constant memory
    cudaMemcpyToSymbol(d_phys,  phys,        sizeof(physics));
    cudaMemcpyToSymbol(d_dx,    &mesh->dx,   sizeof(float));
    cudaMemcpyToSymbol(d_dy,    &mesh->dy,   sizeof(float));
    cudaMemcpyToSymbol(d_ndim1, &mesh->ndim1, sizeof(int));
    cudaMemcpyToSymbol(d_ndim2, &mesh->ndim2, sizeof(int));

    // allocate and copy GPU global memory
    int sz = Ntotal*sizeof(float);
    cudaMalloc ((void**) &d_Q, sz);
    cudaMalloc ((void**) &d_temp, sz);
    cudaMalloc ((void**) &d_rhs, sz);
    cudaMalloc ((void**) &d_bcFlag, sz);

    cudaMemcpy(d_Q, c[0], Ntotal*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_temp, c[0], Ntotal*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_rhs, c[0], Ntotal*sizeof(float), cudaMemcpyHostToDevice);

    //set bcFlag
    float **bcFlag = BCFlag_create(mesh);
    SaveMatrix("bc.txt", bcFlag, mesh->ndim1, mesh->ndim2);
    cudaMemcpy(d_bcFlag, bcFlag[0], Ntotal*sizeof(float), cudaMemcpyHostToDevice);
    Matrix_free(bcFlag);

    // bind GPU memory
    cudaBindTexture( NULL, t_Q, d_Q, sizeof(float)*Ntotal);
    cudaBindTexture( NULL, t_rhs, d_rhs, sizeof(float)*Ntotal);
    cudaBindTexture( NULL, t_bcFlag, d_bcFlag, sizeof(float)*Ntotal);

    // time
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);

#if 0
    int counter = 0;
    char filename[NAMELEN];
#endif
    printf("The spatical interval: dx=%f, dy=%f\n", mesh->dx, mesh->dy);
    printf("The time interval: dt=%f\n", dt);

    // set threads number
    int ThreadsPerBlock = 256;
    int BolcksPerGrid   = (Ntotal+ThreadsPerBlock-1)/ThreadsPerBlock;

    while(time<finalTime){
        if(time+dt<finalTime){
            time += dt;
        }else{
            dt   = finalTime - time;
            time = finalTime;
        }
    // int i;
    // for(i=0; i<90; i++){

        AdvectionGPU2d<<<BolcksPerGrid, ThreadsPerBlock>>>(Ntotal, d_rhs);
        DiffusionGPU2d<<<BolcksPerGrid, ThreadsPerBlock>>>(Ntotal, d_rhs);
        TiemAdvectionGPU2d<<<BolcksPerGrid, ThreadsPerBlock>>>(Ntotal, d_Q, dt);
        SlopeLimiter<<<BolcksPerGrid, ThreadsPerBlock>>>(Ntotal, d_temp, d_bcFlag);

        cudaMemcpy(d_Q, d_temp, Ntotal*sizeof(float), cudaMemcpyDeviceToDevice);
    }

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    float   elapsedTime;
    cudaEventElapsedTime(&elapsedTime, start, stop);
    printf("\nTime Usages: %f\n", elapsedTime);

    cudaMemcpy(c[0], d_Q, Ntotal*sizeof(float), cudaMemcpyDeviceToHost);
    cudaUnbindTexture(t_Q);
    cudaUnbindTexture(t_rhs);
    cudaUnbindTexture(t_bcFlag);

    cudaFree(d_Q);
    cudaFree(d_rhs);
    cudaFree(d_bcFlag);

    return;
}

__global__ void SlopeLimiter(int Ntotal, float *d_temp, float *d_bcFlag){
    int offset = threadIdx.x + blockIdx.x * blockDim.x;

    if(offset < Ntotal){
        int bottom = offset - 1;
        int top    = offset + 1;
        int left   = offset - d_ndim2;
        int right  = offset + d_ndim2;

        float flag   = d_bcFlag[offset];

        if(flag<0.5f){
            float c = tex1Dfetch(t_Q,offset);
            float t = tex1Dfetch(t_Q,top);
            float l = tex1Dfetch(t_Q,left);
            float r = tex1Dfetch(t_Q,right);
            float b = tex1Dfetch(t_Q,bottom);

            d_temp[offset] = (t+l+b+r+c)/5.0f;
        }
    }

    return;
}

/* Advection terms */
__global__ void AdvectionGPU2d(int Ntotal, float *d_rhs){
    int offset = threadIdx.x + blockIdx.x * blockDim.x;

    if(offset < Ntotal){
    
        int bottom = offset - 1;
        int top    = offset + 1;
        int left   = offset - d_ndim2;
        int right  = offset + d_ndim2;

        float flag   = tex1Dfetch(t_bcFlag, offset);

        if(flag<0.5f){
            float c = tex1Dfetch(t_Q,offset);
            float t = tex1Dfetch(t_Q,top);
            float l = tex1Dfetch(t_Q,left);
            float r = tex1Dfetch(t_Q,right);
            float b = tex1Dfetch(t_Q,bottom);

            if(d_phys.u > 0) //upwind scheme
                d_rhs[offset] = -d_phys.u*(c-l)/d_dx;
            else
                d_rhs[offset] = -d_phys.u*(r-c)/d_dx;

            if(d_phys.v > 0)
                d_rhs[offset] += -d_phys.v*(c-b)/d_dy;
            else
                d_rhs[offset] += -d_phys.v*(t-c)/d_dy;
        }

    }
    return;
}

__global__ void DiffusionGPU2d(int Ntotal, float *d_rhs){

    int offset = threadIdx.x + blockIdx.x * blockDim.x;

    if(offset < Ntotal){
    
        int bottom = offset - 1;
        int top    = offset + 1;
        int left   = offset - d_ndim2;
        int right  = offset + d_ndim2;

        float flag   = tex1Dfetch(t_bcFlag, offset);

        if(flag<0.5f){

            float t = tex1Dfetch(t_Q,top);
            float l = tex1Dfetch(t_Q,left);
            float c = tex1Dfetch(t_Q,offset);
            float r = tex1Dfetch(t_Q,right);
            float b = tex1Dfetch(t_Q,bottom);

            d_rhs[offset] += -d_phys.Dx*(r+l-2*c)/d_dx/d_dx     
                        -d_phys.Dy*(t+b-2*c)/d_dy/d_dy;
        }

    }
    return;
}

/* Euler Advance scheme for Time Discretization */
__global__ void TiemAdvectionGPU2d(int Ntotal, float *d_Q, float dt){
    int offset = threadIdx.x + blockIdx.x * blockDim.x;
    float rhs  = tex1Dfetch(t_rhs, offset);

    if(offset < Ntotal)
        d_Q[offset] += rhs*dt;

    return;
}

/* Create boundary condition flag matrix */
float** BCFlag_create(structMesh *mesh){
    float **bcFlag = Matrix_create(mesh->ndim1, mesh->ndim2);
    int dim1, dim2;

    for(dim1=0; dim1<mesh->ndim1; dim1++){
        dim2=0;
        bcFlag[dim1][dim2] = 1.0f;
        bcFlag[dim2][dim1] = 1.0f;

        dim2=mesh->ndim2-1;
        bcFlag[dim1][dim2] = 1.0f;
        bcFlag[dim2][dim1] = 1.0f;
    }
    return bcFlag;
}

/**
 * @brief
 * Calculate the Time Interval.
 *
 */
float getTimeInterval(structMesh *mesh, physics *phy, float CFL){
    float dt;
    float dx = mesh->dx;
    float dy = mesh->dy;
    dt = dx/phy->u;
    dt = minf(dt, dy/phy->v);
    dt = minf(dt, dx*dx/phy->Dx);
    dt = minf(dt, dy*dy/phy->Dy);
    return dt*CFL;
}

}