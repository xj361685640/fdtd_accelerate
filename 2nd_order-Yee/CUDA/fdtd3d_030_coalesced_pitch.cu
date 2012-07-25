#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>
#include <hdf5.h>


__host__ void updateTimer(time_t t0, int tstep, char str[]) {
	int elapsedTime=(int)(time(0)-t0);
	sprintf(str, "%02d:%02d:%02d", elapsedTime/3600, elapsedTime%3600/60, elapsedTime%60);
}


__host__ void exec(char *format, ...) {
	char str[1024];
	va_list ap;
	va_start(ap, format);
	vsprintf(str, format, ap);
	system(str);
}


__host__ void dumpToH5(int Ni, int Nj, int Nk, int is, int js, int ks, int ie, int je, int ke, float ***f, char *format, ...) {
	char filename[1024];
	va_list ap;
	va_start(ap, format);
	vsprintf(filename, format, ap);
	hid_t file, dataset, filespace, memspace;

	hsize_t dimsm[3] = { Ni, Nj, Nk };
	hsize_t start[3] = { is, js, ks };
	hsize_t count[3] = { 1-is+ie, 1-js+je, 1-ks+ke };
	memspace = H5Screate_simple(3, dimsm, 0);
	filespace = H5Screate_simple(3, count, 0);
	file = H5Fcreate(filename, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
	dataset = H5Dcreate(file, "Data", H5T_NATIVE_FLOAT, filespace, H5P_DEFAULT);
	H5Sselect_hyperslab(memspace, H5S_SELECT_SET, start, 0, count, 0);
	H5Dwrite(dataset, H5T_NATIVE_FLOAT, memspace, filespace, H5P_DEFAULT, f[0][0]);
	H5Dclose(dataset);
	H5Sclose(filespace);
	H5Sclose(memspace);
	H5Fclose(file);
}


__host__ void print_array(int Nx, int Ny, int Nz, float ***a) {
	int j,k;
	for (j=0; j<Ny; j++) {
		for (k=0; k<Nz; k++) {
			printf("%1.4f\t", a[Nx/2][j][k]);
		}
		printf("\n");
	}
	printf("\n");
}


__host__ float ***makeArray(int Nx, int Ny, int Nz) {
	float ***f;

	f = (float ***) calloc (Nx, sizeof(float **));
	f[0] = (float **) calloc (Ny*Nx, sizeof(float *));
	f[0][0] = (float *) calloc (Nz*Ny*Nx, sizeof(float));

	for (int i=0; i<Nx; i++) f[i] = f[0] + i*Ny;
	for (int i=0; i<Ny*Nx; i++) f[0][i] = f[0][0] + i*Nz;

	return f;
}


__host__ void set_geometry(int Nx, int Ny, int Nz, 
		float ***CEx, float ***CEy, float ***CEz) {
	int i,j,k;

	for (i=0; i<Nx; i++) {
		for (j=0; j<Ny; j++) {
			for (k=0; k<Nz; k++) {
				CEx[i][j][k] = 0.5;
				CEy[i][j][k] = 0.5;
				CEz[i][j][k] = 0.5;
			}
		}
	}
}


__global__ void initArrays(int Nx, int Ny, int Nz, int Nzpit,
		float *Ex, float *Ey, float *Ez, 
		float *Hx, float *Hy, float *Hz) {
	int idx;

	idx = blockIdx.x*blockDim.x + threadIdx.x;
	
	//printf("gridDim.x=%d\n",gridDim.x);
	//printf("blockIdx.x=%d, blockDim.x=%d, threadIdx.x=%d\n", blockIdx.x, blockDim.x, threadIdx.x);
	if ( idx < Nx*Ny*Nzpit ) {
		Ex[idx] = 0;
		Ey[idx] = 0;
		Ez[idx] = 0;
		Hx[idx] = 0;
		Hy[idx] = 0;
		Hz[idx] = 0;
	}
}


__global__ void updateE(int Nx, int Ny, int Nz, int Nzpit,
		float *Ex, float *Ey, float *Ez, 
		float *Hx, float *Hy, float *Hz, 
		float *CEx, float *CEy, float *CEz) {
	int idx;
	idx = blockIdx.x*blockDim.x + threadIdx.x;

	//printf("gridDim.x=%d\n",gridDim.x);
	//printf("blockIdx.x=%d, blockDim.x=%d, threadIdx.x=%d\n", blockIdx.x, blockDim.x, threadIdx.x);
	if ( idx < Nx*Ny*Nzpit ) {
		int i,j,k;
		int Nyz = Ny*Nzpit;
		i = idx/Nyz;
		j = ( idx - i*Nyz )/Nzpit;
		k = idx - i*Nyz - j*Nzpit;

		//printf("[%d](%d,%d,%d)\n",idx,i,j,k);

		__shared__ float hx[500], hy[500], hz[500];
		if ( k < Nz ) {
			//printf("k=%d\n",k);
			hx[k] = Hx[idx];
			hy[k] = Hy[idx];
			hz[k] = Hz[idx];
		}
		__syncthreads();
		if ( k < Nz ) {
			if ( j<Ny-1 && k<Nz-1 ) Ex[idx] += CEx[idx]*( Hz[idx+Nzpit] - hz[k] - hy[k+1] + hy[k] );
			if ( i<Nx-1 && k<Nz-1 ) Ey[idx] += CEy[idx]*( hx[k+1] - hx[k] - Hz[idx+Nyz] + hz[k] );
			if ( i<Nx-1 && j<Ny-1 ) Ez[idx] += CEz[idx]*( Hy[idx+Nyz] - hy[k] - Hx[idx+Nzpit] + hx[k] );
		}
	}
}


__global__ void updateSrc(int Nx, int Ny, int Nz, int Nzpit, 
		float *Ex, int tstep) {
	int idx, ijk;

	idx = blockIdx.x*blockDim.x + threadIdx.x;
	ijk = idx*(Ny)*(Nzpit) + (Ny/2)*(Nzpit) + (Nz/2);

	//printf("idx=%d, ijk=%d\n", idx, ijk);
	//Ex[ijk] += __sinf(0.1*tstep);
	if ( idx < Nx ) {
		Ex[ijk] += sin(0.1*tstep);
	}
}


__global__ void updateH(int Nx, int Ny, int Nz, int Nzpit,
	   	float *Ex, float *Ey, float *Ez, 
		float *Hx, float *Hy, float *Hz) {
	int idx;
	idx = blockIdx.x*blockDim.x + threadIdx.x;

	if ( idx < Nx*Ny*Nzpit ) {
		int i,j,k;
		int Nyz = Ny*Nzpit;
		i = idx/Nyz;
		j = ( idx - i*Nyz )/Nzpit;
		k = idx - i*Nyz - j*Nzpit;

		__shared__ float ex[500], ey[500], ez[500];
		if ( k < Nz ) {
			ex[k] = Ex[idx];
			ey[k] = Ey[idx];
			ez[k] = Ez[idx];
		}
		__syncthreads();

		if ( k < Nz ) {
			if ( j>0 && k>0 ) Hx[idx] -= 0.5*( ez[k] - Ez[idx-Nzpit] - ey[k] + ey[k-1] );
			if ( i>0 && k>0 ) Hy[idx] -= 0.5*( ex[k] - ex[k-1] - ez[k] + Ez[idx-Nyz] );
			if ( i>0 && j>0 ) Hz[idx] -= 0.5*( ey[k] - Ey[idx-Nyz] - ex[k] + Ex[idx-Nzpit] );
		}
	}
}


int main() {
	int tstep;
	char time_str[32];
	time_t t0;

	// Set the parameters
	int Nx, Ny, Nz, TMAX;
	Nx = 100;
	Ny = 200;
	Nz = 500;
	TMAX = 1000;

	// Allocate host memory
	//float ***Ex;
	float ***CEx, ***CEy, ***CEz;
	//Ex = makeArray(Nx, Ny, Nz);
	CEx = makeArray(Nx, Ny, Nz);
	CEy = makeArray(Nx, Ny, Nz);
	CEz = makeArray(Nx, Ny, Nz);

	// Geometry
	set_geometry(Nx, Ny, Nz, CEx, CEy, CEz);


	// Allocate device memory
	float *devEx, *devEy, *devEz;
	float *devHx, *devHy, *devHz;
	float *devCEx, *devCEy, *devCEz;
	int z_size = Nz*sizeof(float);
	size_t pitch;
	cudaMallocPitch ( (void**) &devEx, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devEy, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devEz, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devCEx, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devCEy, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devCEz, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devHx, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devHy, &pitch, z_size, Nx*Ny );
	cudaMallocPitch ( (void**) &devHz, &pitch, z_size, Nx*Ny );
	
	// Copy arrays from host to device
	cudaMemcpy2D ( devCEx, pitch, CEx[0][0], z_size, z_size, Nx*Ny, cudaMemcpyHostToDevice );
	cudaMemcpy2D ( devCEy, pitch, CEy[0][0], z_size, z_size, Nx*Ny, cudaMemcpyHostToDevice );
	cudaMemcpy2D ( devCEz, pitch, CEz[0][0], z_size, z_size, Nx*Ny, cudaMemcpyHostToDevice );
	
	int Nz_pitch = pitch/4;
	printf("pitch= %u, Nz_pitch= %d\n", pitch, Nz_pitch);

	// Number of thread blocks in the grid
	int N = Nx*Ny*Nz_pitch;
	int TPB = Nz_pitch;
	int BPG = N%TPB == 0 ? N/TPB : N/TPB + 1;
	printf("TPB=%d, BPG=%d\n", TPB, BPG);
	dim3 gridDim(BPG);
	// Number of threads per block
	dim3 blockDim(TPB);

	//int BPGsrc = Nx%TPB == 0 ? Nx/TPB : Nx/TPB + 1;
	int BPGsrc = 1;
	dim3 gridDimsrc(BPGsrc);
	dim3 blockDimsrc(Nx);

	// Initialize the device arrays
	initArrays <<<gridDim,blockDim>>> ( Nx, Ny, Nz, Nz_pitch, devEx, devEy, devEz, devHx, devHy, devHz );

	// Main time loop
	t0 = time(0);
	//for ( tstep=1; tstep<=TMAX; tstep++) {
	for ( tstep=1; tstep<=10; tstep++) {
		// Update on the GPU
		updateE <<<gridDim,blockDim>>> ( Nx, Ny, Nz, Nz_pitch, devEx, devEy, devEz, devHx, devHy, devHz, devCEx, devCEy, devCEz );
		//updateSrc <<<gridDimsrc,blockDimsrc>>> (Nx, Ny, Nz, Nz_pitch, devEx, tstep);
		//updateH <<<gridDim,blockDim>>> (Nx, Ny, Nz, Nz_pitch, devEx, devEy, devEz, devHx, devHy, devHz);

		/*
		//if ( tstep/10*10 == tstep ) {
			// Copy arrays from device to host
			cudaMemcpy2D( Ex[0][0], z_size, devEx, pitch, z_size, Nx*Ny, cudaMemcpyDeviceToHost );

			//print_array(Nx, Ny, Nz, Ex);
			dumpToH5(Nx, Ny, Nz, Nx/2, 0, 0, Nx/2, Ny-1, Nz-1, Ex, "gpu_png/Ex-%05d.h5", tstep);
			exec("h5topng -ZM0.1 -x0 -S4 -c /usr/share/h5utils/colormaps/dkbluered gpu_png/Ex-%05d.h5", tstep);

			updateTimer(t0, tstep, time_str);
			printf("tstep=%d\t%s\n", tstep, time_str);
		//}
		*/
	}
	updateTimer(t0, tstep, time_str);
	printf("tstep=%d\t%s\n", tstep, time_str);
}
