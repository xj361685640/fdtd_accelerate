#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>
#include <hdf5.h>

#define NPML 10

const float light_velocity = 2.99792458e8;	// m s- 
const float ep0 = 8.85418781762038920e-12;	// F m-1 (permittivity at vacuum)
const float	mu0 = 1.25663706143591730e-6;	// N A-2 (permeability at vacuum)
const float imp0 = sqrt( mu0/ep0 );	// (impedance at vacuum)
const float pi = 3.14159265358979323846;

const int MAX_BPG = 65535;
const int MAX_TPB = 512;	 

// Allocate constant memory for CPML
__constant__ float rcmbE[2*NPML];
__constant__ float rcmaE[2*NPML];
__constant__ float rcmbH[2*NPML];
__constant__ float rcmaH[2*NPML];


typedef struct N3 {
	int x, y, z;
} N3;


typedef struct N3dim3 {
	dim3 x, y, z;
} N3dim3;


typedef struct P3F3 {
	float ***x, ***y, ***z;
} P3F3;


typedef struct P1F3 {
	float *x, *y, *z;
} P1F3;


typedef struct P1F2 {
	float *f, *b;
} P1F2;


typedef struct P1F6 {
	P1F2 x, y, z;
} P1F6;


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


__host__ void print_array(N3 N, float ***a) {
	int j,k;
	for (j=0; j<N.y; j++) {
		for (k=0; k<N.z; k++) {
			printf("%1.4f\t", a[N.x/2][j][k]);
		}
		printf("\n");
	}
	printf("\n");
}


__host__ float ***makeArray(N3 N) {
	float ***f;

	f = (float ***) calloc (N.x, sizeof(float **));
	f[0] = (float **) calloc (N.y*N.x, sizeof(float *));
	f[0][0] = (float *) calloc (N.z*N.y*N.x, sizeof(float));

	for (int i=0; i<N.x; i++) f[i] = f[0] + i*N.y;
	for (int i=0; i<N.y*N.x; i++) f[0][i] = f[0][0] + i*N.z;

	return f;
}


__host__ void set_geometry(N3 N, P3F3 CE) {
	int i,j,k;

	for (i=0; i<N.x; i++) {
		for (j=0; j<N.y; j++) {
			for (k=0; k<N.z; k++) {
				CE.x[i][j][k] = 0.5;
				CE.y[i][j][k] = 0.5;
				CE.z[i][j][k] = 0.5;
			}
		}
	}
}


__host__ void verify_16xNz(int Nz) {
	int R = Nz%16;
	int N1 = Nz-R; 
	int N2 = N1+16; 
	if ( R == 0 ) printf("Nz is a multiple of 16.\n");
	else {
		printf("Error: Nz is not a multiple of 16.\n");
		printf("Recommend Nz: %d or %d\n", N1, N2);
		exit(0);
	}
}


__host__ int selectTPB(int Ntot) {
	float occupancy;
	float max_occupancy=0;
	int selTPB=0;
	int TPB;	// thread/block
	int WPB;	// wrap/block
	int ABPM;	// active block/streaming multiprocessor
	int AWPM;	// active warp/streaming multiprocessor
	int MAX_ABPM = 8;	 
	int MAX_AWPM = 32;	 
	//int MAX_TPM = 1024;	 
	int TPW = 32;	// thread/warp

	for ( TPB=MAX_TPB; TPB>0; TPB-- ) {
		if ( Ntot%TPB == 0 && TPB%16 == 0 ) {
			WPB = TPB%TPW == 0 ? TPB/TPW : TPB/TPW+1;
			ABPM = MAX_AWPM/WPB <= 8 ? MAX_AWPM/WPB : MAX_ABPM;
			AWPM = WPB*ABPM;
			occupancy = (float)AWPM/MAX_AWPM;
			if ( max_occupancy < occupancy ) {
				max_occupancy = occupancy;
				selTPB = TPB;
			}
			//printf("TPB=%d, WPB=%d, ABPM=%d, AWPM=%d, occupancy=%g, max_occupancy=%g, selTPB=%d\n", TPB, WPB, ABPM, AWPM, occupancy, max_occupancy, selTPB);
		}
	}

	if ( selTPB == 0 ) {
		printf("Error: There is not a TPB which is a aliquot part of the Ntot(%d).\n", Ntot);
		exit(0);
	}

	printf("Occupancy=%1.2f\n", max_occupancy);
	return selTPB;
}


__global__ void initArray(int Ntot, float *a, int idx0) {
	int idx = idx0 + blockIdx.x*blockDim.x + threadIdx.x;

	if ( idx < Ntot ) a[idx] = 0;
}


__host__ void initMainArrays(N3 N, P1F3 F) {
	int i;
	int Ntot = (N.x+1)*N.y*N.z;
	int TPB = MAX_TPB;
	int BPG = Ntot%TPB == 0 ? Ntot/TPB : Ntot/TPB + 1;

	int NK = BPG/MAX_BPG + 1;
	int sBPG = BPG/NK;
	int idx0[NK];
	dim3 DG[NK];
	for ( i=0; i<NK; i++) {
		idx0[i] = TPB*sBPG*i;
		DG[i] = dim3(sBPG);
	}
	DG[NK-1] = dim3(sBPG+BPG%NK);
	dim3 DB(TPB);
	for ( i=0; i<NK; i++) {
		initArray <<<DG[i],DB>>> (Ntot, F.x, idx0[i]); 
		initArray <<<DG[i],DB>>> (Ntot, F.y, idx0[i]); 
		initArray <<<DG[i],DB>>> (Ntot, F.z, idx0[i]); 
	}
	printf("main init: Ntot=%d(%dx%dx%d), TPB=%d, BPG=%d, sBPG(%d)=%d\n", Ntot, N.x+1, N.y, N.z, TPB, BPG, NK, sBPG);
}


__host__ void initPsiArrays(N3 N, N3 Ntot, N3dim3 DGpml, N3dim3 DBpml, P1F6 psix, P1F6 psiy, P1F6 psiz) {
	initArray <<<DGpml.x,DBpml.x>>> (Ntot.x, psix.y.f, 0); 
	initArray <<<DGpml.x,DBpml.x>>> (Ntot.x, psix.y.b, 0); 
	initArray <<<DGpml.x,DBpml.x>>> (Ntot.x, psix.z.f, 0); 
	initArray <<<DGpml.x,DBpml.x>>> (Ntot.x, psix.z.b, 0); 
	
	initArray <<<DGpml.y,DBpml.y>>> (Ntot.y, psiy.z.f, 0); 
	initArray <<<DGpml.y,DBpml.y>>> (Ntot.y, psiy.z.b, 0); 
	initArray <<<DGpml.y,DBpml.y>>> (Ntot.y, psiy.x.f, 0); 
	initArray <<<DGpml.y,DBpml.y>>> (Ntot.y, psiy.x.b, 0); 

	initArray <<<DGpml.z,DBpml.z>>> (Ntot.y, psiz.x.f, 0); 
	initArray <<<DGpml.z,DBpml.z>>> (Ntot.y, psiz.x.b, 0); 
	initArray <<<DGpml.z,DBpml.z>>> (Ntot.y, psiz.y.f, 0); 
	initArray <<<DGpml.z,DBpml.z>>> (Ntot.y, psiz.y.b, 0); 
}


__host__ void freeMainArrays(P1F3 F) {
	cudaFree(F.x);
	cudaFree(F.y);
	cudaFree(F.z);
}


__host__ void freePsiArrays(P1F6 psix, P1F6 psiy, P1F6 psiz) {
	cudaFree(psix.y.f);
	cudaFree(psix.y.b);
	cudaFree(psix.z.f);
	cudaFree(psix.z.b);

	cudaFree(psiy.z.f);
	cudaFree(psiy.z.b);
	cudaFree(psiy.x.f);
	cudaFree(psiy.x.b);

	cudaFree(psiz.x.f);
	cudaFree(psiz.x.b);
	cudaFree(psiz.y.f);
	cudaFree(psiz.y.b);
}


__global__ void updateE(N3 N, int TPB, P1F3 E, P1F3 H, P1F3 CE, int idx0) {
	int tk = threadIdx.x;
	int idx = blockIdx.x*TPB + tk + idx0;
	int Nyz = N.y*N.z;
	int eidx = idx + Nyz;

	extern __shared__ float hs[];
	float* hx = (float*) hs;
	float* hy = (float*) &hx[TPB+1];
	float* hz = (float*) &hy[TPB+1];

	hx[tk] = H.x[idx];
	hy[tk] = H.y[idx];
	hz[tk] = H.z[idx];
	if ( tk==TPB-1 ) {
		hx[tk+1] = H.x[idx+1];
		hy[tk+1] = H.y[idx+1];
	}
	__syncthreads();

	E.x[eidx] += CE.x[idx]*( H.z[idx+N.z] - hz[tk] - hy[tk+1] + hy[tk] );
	E.y[eidx] += CE.y[idx]*( hx[tk+1] - hx[tk] - H.z[idx+Nyz] + hz[tk] );
	E.z[eidx] += CE.z[idx]*( H.y[idx+Nyz] - hy[tk] - H.x[idx+N.z] + hx[tk] );
}


__global__ void updateH(N3 N, int TPB, P1F3 E, P1F3 H, int idx0) {
	int tk = threadIdx.x;
	int idx = blockIdx.x*TPB + tk + idx0;
	int Nyz = N.y*N.z;
	int eidx = idx + Nyz;

	extern __shared__ float es[];
	float* ex = (float*) es;
	float* ey = (float*) &ex[TPB+1];
	float* ez = (float*) &ey[TPB+1];

	ex[tk+1] = E.x[eidx];
	ey[tk+1] = E.y[eidx];
	ez[tk] = E.z[eidx];
	if ( tk==0 ) {
		ex[0] = E.x[eidx-1];
		ey[0] = E.y[eidx-1];
	}
	__syncthreads();

	H.x[idx] -= 0.5*( ez[tk] - E.z[eidx-N.z] - ey[tk+1] + ey[tk] );
	H.y[idx] -= 0.5*( ex[tk+1] - ex[tk] - ez[tk] + E.z[eidx-Nyz] );
	H.z[idx] -= 0.5*( ey[tk+1] - E.y[eidx-Nyz] - ex[tk+1] + E.x[eidx-N.z] );
}


__global__ void updateSrc(N3 N, P1F3 E, int tstep) {
	int idx = threadIdx.x;
	//int ijk = idx*N.y*N.z + (N.y/2)*N.z + (N.z/2);
	int ijk = (N.x/2+1)*N.y*N.z + (N.y/2)*N.z + idx;

	//E.x[ijk] += sin(0.1*tstep);
	E.z[ijk] += sin(0.1*tstep);
}


__global__ void updateCPMLxE_cmem(N3 N, P1F3 E, P1F3 H, P1F3 CE, float *psi1, float *psi2, int backward) {
	int pidx = blockIdx.x*blockDim.x + threadIdx.x;
	int Nyz = N.y*N.z;
	int pi = pidx/Nyz + backward*NPML;

	int idx = pidx + backward*(N.x-NPML-1)*Nyz;
	int eidx = idx + Nyz;

	psi1[pidx] = rcmbE[pi]*psi1[pidx] + rcmaE[pi]*( H.z[idx+Nyz] - H.z[idx] );
	E.y[eidx] -= CE.y[idx]*psi1[pidx];

	psi2[pidx] = rcmbE[pi]*psi2[pidx] + rcmaE[pi]*( H.y[idx+Nyz] - H.y[idx] );
	E.z[eidx] += CE.z[idx]*psi2[pidx];
}


__global__ void updateCPMLxH_cmem(N3 N, P1F3 E, P1F3 H, float *psi1, float *psi2, int backward) {
	int pidx = blockIdx.x*blockDim.x + threadIdx.x;
	int Nyz = N.y*N.z;
	int pi = pidx/Nyz + backward*NPML;

	int idx = pidx + backward*(N.x-NPML)*Nyz;
	int eidx = idx + Nyz;

	psi1[pidx] = rcmbH[pi]*psi1[pidx] + rcmaH[pi]*( E.z[eidx] - E.z[eidx-Nyz] );
	H.y[idx] += 0.5*psi1[pidx];

	psi2[pidx] = rcmbH[pi]*psi2[pidx] + rcmaH[pi]*( E.y[eidx] - E.y[eidx-Nyz] );
	H.z[idx] -= 0.5*psi2[pidx];
}


__global__ void updateCPMLyE_cmem1(N3 N, P1F3 E, P1F3 H, P1F3 CE, float *psi1, float *psi2, int backward) {
	int pidx = blockIdx.x*blockDim.x + threadIdx.x;
	int i = pidx/(NPML*N.z);
	int pj = ( pidx - i*NPML*N.z )/N.z + backward*NPML;

	int idx = pidx + (i+backward)*(N.y-NPML)*N.z - backward*N.z;
	//int idx = pidx + i*(N.y-NPML)*N.z + backward*(N.y-NPML-1)*N.z;
	int eidx = idx + N.y*N.z;

	psi1[pidx] = rcmbE[pj]*psi1[pidx] + rcmaE[pj]*( H.x[idx+N.z] - H.x[idx] );
	E.z[eidx] -= CE.z[idx]*psi1[pidx];

	psi2[pidx] = rcmbE[pj]*psi2[pidx] + rcmaE[pj]*( H.z[idx+N.z] - H.z[idx] );
	E.x[eidx] += CE.x[idx]*psi2[pidx];
}


__global__ void updateCPMLyH_cmem1(N3 N, P1F3 E, P1F3 H, float *psi1, float *psi2, int backward) {
	int pidx = blockIdx.x*blockDim.x + threadIdx.x;
	int i = pidx/(NPML*N.z);
	int pj = ( pidx - i*NPML*N.z )/N.z + backward*NPML;

	int idx = pidx + (i+backward)*(N.y-NPML)*N.z;
	int eidx = idx + N.y*N.z;

	psi1[pidx] = rcmbH[pj]*psi1[pidx] + rcmaH[pj]*( E.x[eidx] - E.x[eidx-N.z] );
	H.z[idx] += 0.5*psi1[pidx];

	psi2[pidx] = rcmbH[pj]*psi2[pidx] + rcmaH[pj]*( E.z[eidx] - E.z[eidx-N.z] );
	H.x[idx] -= 0.5*psi2[pidx];
}


__global__ void updateCPMLyE_cmem2(N3 N, P1F3 E, P1F3 H, P1F3 CE, float *psi1, float *psi2, int backward) {
	int pidx = blockIdx.x*blockDim.x + threadIdx.x;
	int j = pidx/(N.x*N.z);
	int i = (pidx - j*N.x*N.z)/N.z;
	int k = pidx%N.z;
	int pj = j + backward*NPML;

	int idx = k + (j + i*N.y)*N.z + backward*(N.y-NPML-1)*N.z;
	int eidx = idx + N.y*N.z;

	psi1[pidx] = rcmbE[pj]*psi1[pidx] + rcmaE[pj]*( H.x[idx+N.z] - H.x[idx] );
	E.z[eidx] -= CE.z[idx]*psi1[pidx];

	psi2[pidx] = rcmbE[pj]*psi2[pidx] + rcmaE[pj]*( H.z[idx+N.z] - H.z[idx] );
	E.x[eidx] += CE.x[idx]*psi2[pidx];
}


__global__ void updateCPMLyH_cmem2(N3 N, P1F3 E, P1F3 H, float *psi1, float *psi2, int backward) {
	int pidx = blockIdx.x*blockDim.x + threadIdx.x;
	int j = pidx/(N.x*N.z);
	int i = (pidx - j*N.x*N.z)/N.z;
	int k = pidx%N.z;
	int pj = j + backward*NPML;

	int idx = k + (j + i*N.y)*N.z + backward*(N.y-NPML)*N.z;
	int eidx = idx + N.y*N.z;

	psi1[pidx] = rcmbH[pj]*psi1[pidx] + rcmaH[pj]*( E.x[eidx] - E.x[eidx-N.z] );
	H.z[idx] += 0.5*psi1[pidx];

	psi2[pidx] = rcmbH[pj]*psi2[pidx] + rcmaH[pj]*( E.z[eidx] - E.z[eidx-N.z] );
	H.x[idx] -= 0.5*psi2[pidx];
}



int main() {
	int tstep;
	char time_str[32];
	time_t t0;
	int i;

	// --------------------------------------------------------------------------------
	// Set the parameters
	N3 N;
	N.x = 200;
	N.y = 200;
	N.z = 208;
	//N.y = 16;
	//N.z = 20;
	int TMAX = 10000;
	
	float S = 0.5;
	float dx = 10e-9;
	float dt = S*dx/light_velocity;
	printf("NPML=%d\n", NPML);
	printf("N(%d,%d,%d), TMAX=%d\n", N.x, N.y, N.z, TMAX);
	verify_16xNz( N.z );

	// --------------------------------------------------------------------------------
	// Allocate host memory
	P3F3 CE;
	CE.x = makeArray(N);
	CE.y = makeArray(N);
	CE.z = makeArray(N);
	float ***Ex, ***Ez;
	N3 Nxp;
	Nxp.x = N.x+1;
	Nxp.y = N.y;
	Nxp.z = N.z;
	Ex = makeArray(Nxp);
	Ez = makeArray(Nxp);

	// --------------------------------------------------------------------------------
	// Geometry
	set_geometry(N, CE);

	// --------------------------------------------------------------------------------
	// Parameters for CPML
	int m = 4;	// grade_order
	float sigma_max = (m+1.)/(15*pi*NPML*dx);
	float alpha = 0.05;
	float *sigmaE, *bE, *aE;
	float *sigmaH, *bH, *aH;

	sigmaE = (float *) calloc (2*NPML, sizeof(float));
	sigmaH = (float *) calloc (2*NPML, sizeof(float));
	bE = (float *) calloc (2*NPML, sizeof(float));
	bH = (float *) calloc (2*NPML, sizeof(float));
	aE = (float *) calloc (2*NPML, sizeof(float));
	aH = (float *) calloc (2*NPML, sizeof(float));
	for (i=0; i<NPML; i++) {
		sigmaE[i] = pow( (NPML-0.5-i)/NPML, m )*sigma_max;
		sigmaE[i+NPML] = pow( (0.5+i)/NPML, m )*sigma_max;
		sigmaH[i] = pow( (float)(NPML-i)/NPML, m )*sigma_max;
		sigmaH[i+NPML] = pow( (1.+i)/NPML, m )*sigma_max;
	}

	for (i=0; i<2*NPML; i++) {
		bE[i] = exp( -(sigmaE[i] + alpha)*dt/ep0 );
		bH[i] = exp( -(sigmaH[i] + alpha)*dt/ep0 );
		aE[i] = sigmaE[i]/(sigmaE[i]+alpha)*(bE[i]-1);
		aH[i] = sigmaH[i]/(sigmaH[i]+alpha)*(bH[i]-1);
		//printf("[%d]\tsigmaE=%g,\tbE=%g,aE=%g\n", i, sigmaE[i], bE[i], aE[i]);
		//printf("[%d]\tsigmaH=%g,\tbH=%g,aH=%g\n", i, sigmaH[i], bH[i], aH[i]);
	}
	free(sigmaE);
	free(sigmaH);

	// --------------------------------------------------------------------------------
	// Copy arrays from host to constant memory
	cudaMemcpyToSymbol(rcmbE, bE, 2*NPML*sizeof(float));
	cudaMemcpyToSymbol(rcmaE, aE, 2*NPML*sizeof(float));
	cudaMemcpyToSymbol(rcmbH, bH, 2*NPML*sizeof(float));
	cudaMemcpyToSymbol(rcmaH, aH, 2*NPML*sizeof(float));

	// --------------------------------------------------------------------------------
	// Allocate device memory
	P1F3 devE, devH;
	P1F3 devCE;

	cudaMalloc ( (void**) &devE.x, (N.x+1)*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devE.y, (N.x+1)*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devE.z, (N.x+1)*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devH.x, (N.x+1)*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devH.y, (N.x+1)*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devH.z, (N.x+1)*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devCE.x, N.x*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devCE.y, N.x*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &devCE.z, N.x*N.y*N.z*sizeof(float) );
	
	// Allocate device memory for CPML
	P1F6 psixE, psiyE, psizE;
	P1F6 psixH, psiyH, psizH;

	cudaMalloc ( (void**) &psixE.y.f, NPML*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psixE.y.b, NPML*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psixE.z.f, NPML*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psixE.z.b, NPML*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psixH.y.f, NPML*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psixH.y.b, NPML*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psixH.z.f, NPML*N.y*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psixH.z.b, NPML*N.y*N.z*sizeof(float) );

	cudaMalloc ( (void**) &psiyE.z.f, N.x*NPML*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psiyE.z.b, N.x*NPML*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psiyE.x.f, N.x*NPML*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psiyE.x.b, N.x*NPML*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psiyH.z.f, N.x*NPML*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psiyH.z.b, N.x*NPML*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psiyH.x.f, N.x*NPML*N.z*sizeof(float) );
	cudaMalloc ( (void**) &psiyH.x.b, N.x*NPML*N.z*sizeof(float) );

	size_t pml_pitch;
	cudaMallocPitch ( (void**) &psizE.x.f, &pml_pitch, NPML*sizeof(float), N.x*N.y );
	cudaMallocPitch ( (void**) &psizE.x.b, &pml_pitch, NPML*sizeof(float), N.x*N.y );
	cudaMallocPitch ( (void**) &psizE.y.f, &pml_pitch, NPML*sizeof(float), N.x*N.y );
	cudaMallocPitch ( (void**) &psizE.y.b, &pml_pitch, NPML*sizeof(float), N.x*N.y );
	cudaMallocPitch ( (void**) &psizH.x.f, &pml_pitch, NPML*sizeof(float), N.x*N.y );
	cudaMallocPitch ( (void**) &psizH.x.b, &pml_pitch, NPML*sizeof(float), N.x*N.y );
	cudaMallocPitch ( (void**) &psizH.y.f, &pml_pitch, NPML*sizeof(float), N.x*N.y );
	cudaMallocPitch ( (void**) &psizH.y.b, &pml_pitch, NPML*sizeof(float), N.x*N.y );

	// --------------------------------------------------------------------------------
	// Copy arrays from host to device
	cudaMemcpy ( devCE.x, CE.x[0][0], N.x*N.y*N.z*sizeof(float), cudaMemcpyHostToDevice );
	cudaMemcpy ( devCE.y, CE.x[0][0], N.x*N.y*N.z*sizeof(float), cudaMemcpyHostToDevice );
	cudaMemcpy ( devCE.z, CE.x[0][0], N.x*N.y*N.z*sizeof(float), cudaMemcpyHostToDevice );

	free(CE.x);
	free(CE.y);
	free(CE.z);

	// --------------------------------------------------------------------------------
	// Set the GPU parameters
	// TPB: Number of threads per block
	// BPG: Number of thread blocks per grid
	int Ntot, TPB, BPG;

	// main update
	Ntot = N.x*N.y*N.z;
	TPB = selectTPB( Ntot );	 
	//BPG = Ntot%TPB == 0 ? Ntot/TPB : Ntot/TPB + 1;
	BPG = Ntot/TPB;
	int NK = BPG/MAX_BPG + 1;	// Number of kernel
	int sBPG = BPG/NK;
	int idx0[NK];
	dim3 DGmain[NK];
	for ( i=0; i<NK; i++ ) {
		idx0[i] = TPB*sBPG*i;
		DGmain[i] = dim3(sBPG);
	}
	DGmain[NK-1] = dim3(sBPG+BPG%NK);
	dim3 DBmain = dim3(TPB);
	size_t NSmain = sizeof(float)*( 2*(TPB+1)+TPB );
	printf("main: Ntot=%d(%dx%dx%d), TPB=%d, BPG=%d, sBPG(%d)=%d, NS=%d\n", Ntot, N.x, N.y, N.z, TPB, BPG, NK, sBPG, NSmain);
	int TPBmain = TPB;	 
	
	// source 
	//TPB = N.x;
	TPB = N.z;
	BPG = 1;
	dim3 DBsrc(TPB);
	dim3 DGsrc(BPG);
	printf("source: TPB=%d, BPG=%d\n", TPB, BPG);

	// cpml 
	N3 Ntotpml;
	N3dim3 DBpml, DGpml;

	Ntot = NPML*N.y*N.z;
	TPB = selectTPB( Ntot );	 
	BPG = Ntot/TPB;
	DBpml.x = dim3(TPB);
	DGpml.x = dim3(BPG);
	printf("pml (x): Ntot=%d(%dx%dx%d), TPB=%d, BPG=%d\n", Ntot, NPML, N.y, N.z, TPB, BPG);
	Ntotpml.x = Ntot;

	Ntot = N.x*NPML*N.z;
	TPB = selectTPB( Ntot );	 
	BPG = Ntot/TPB;
	DBpml.y = dim3(TPB);
	DGpml.y = dim3(BPG);
	printf("pml (y): Ntot=%d(%dx%dx%d), TPB=%d, BPG=%d\n", Ntot, N.x, NPML, N.z, TPB, BPG);
	Ntotpml.y = Ntot;

	int NPML_pitch = NPML/16 + 16; 
	Ntot = N.x*N.y*NPML_pitch;
	TPB = selectTPB( Ntot );	 
	BPG = Ntot/TPB;
	DBpml.z = dim3(TPB);
	DGpml.z = dim3(BPG);
	printf("pml (z): Ntot=%d(%dx%dx%d), TPB=%d, BPG=%d\n", Ntot, N.x, N.y, NPML_pitch, TPB, BPG);
	Ntotpml.z = Ntot;

	// --------------------------------------------------------------------------------
	// Initialize the device arrays
	initMainArrays ( N, devE );
	initMainArrays ( N, devH );
	initPsiArrays ( N, Ntotpml, DGpml, DBpml, psixE, psiyE, psizE );
	initPsiArrays ( N, Ntotpml, DGpml, DBpml, psixH, psiyH, psizH );

	// --------------------------------------------------------------------------------
	// time loop
	t0 = time(0);
	//for ( tstep=1; tstep<=TMAX; tstep++) {
	for ( tstep=1; tstep<=5000; tstep++) {
		// E-fields main region update
		for ( i=0; i<NK; i++) updateE <<<DGmain[i],DBmain,NSmain>>> ( N, TPBmain, devE, devH, devCE, idx0[i] );

		/*
		// E-fields CPML region update
		updateCPMLxE_cmem <<<DGpml.x,DBpml.x>>> ( N, devE, devH, devCE, psixE.y.f, psixE.z.f, 0);
		updateCPMLxE_cmem <<<DGpml.x,DBpml.x>>> ( N, devE, devH, devCE, psixE.y.b, psixE.z.b, 1); 
		//updateCPMLyE_cmem1 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, devCE, psiyE.z.f, psiyE.x.f, 0);
		//updateCPMLyE_cmem1 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, devCE, psiyE.z.b, psiyE.x.b, 1);
		updateCPMLyE_cmem2 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, devCE, psiyE.z.f, psiyE.x.f, 0);
		updateCPMLyE_cmem2 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, devCE, psiyE.z.b, psiyE.x.b, 1);
		*/

		// Source update
		updateSrc <<<DGsrc,DBsrc>>> ( N, devE, tstep );

		// H-fields main region update
		for ( i=0; i<NK; i++) updateH <<<DGmain[i],DBmain,NSmain>>> ( N, TPBmain, devE, devH, idx0[i] );

		/*
		// H-fields CPML region update
		updateCPMLxH_cmem <<<DGpml.x,DBpml.x>>> ( N, devE, devH, psixH.y.f, psixH.z.f, 0); 
		updateCPMLxH_cmem <<<DGpml.x,DBpml.x>>> ( N, devE, devH, psixH.y.b, psixH.z.b, 1); 
		//updateCPMLyH_cmem1 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, psiyH.z.f, psiyH.x.f, 0);
		//updateCPMLyH_cmem1 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, psiyH.z.b, psiyH.x.b, 1);
		updateCPMLyH_cmem2 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, psiyH.z.f, psiyH.x.f, 0);
		updateCPMLyH_cmem2 <<<DGpml.y,DBpml.y>>> ( N, devE, devH, psiyH.z.b, psiyH.x.b, 1);

		if ( tstep/50*50 == tstep ) {
			// Copy arrays from device to host
			//cudaMemcpy( Ex[0][0], devE.x, (N.x+1)*N.y*N.z*sizeof(float), cudaMemcpyDeviceToHost );
			cudaMemcpy( Ez[0][0], devE.z, (N.x+1)*N.y*N.z*sizeof(float), cudaMemcpyDeviceToHost );

			//print_array(N, Ex);
			//dumpToH5(N.x+1, N.y, N.z, N.x/2, 0, 0, N.x/2, N.y-1, N.z-1, Ex, "gpu_png/Ex-%05d.h5", tstep);
			//exec("h5topng -ZM0.1 -x0 -S4 -c /usr/share/h5utils/colormaps/dkbluered gpu_png/Ex-%05d.h5", tstep);
			dumpToH5(N.x+1, N.y, N.z, 0, 0, N.z/2, N.x, N.y-1, N.z/2, Ez, "gpu_png/Ez-%05d.h5", tstep);
			//dumpToH5(N.x+1, N.y, N.z, 0, 0, 0, N.x, N.y-1, 0, Ez, "gpu_png/Ez-%05d.h5", tstep);
			exec("h5topng -ZM0.1 -z0 -S4 -c /usr/share/h5utils/colormaps/dkbluered gpu_png/Ez-%05d.h5", tstep);

			updateTimer(t0, tstep, time_str);
			printf("tstep=%d\t%s\n", tstep, time_str);
		}
		*/
	}
	updateTimer(t0, tstep, time_str);
	printf("tstep=%d\t%s\n", tstep, time_str);
	
	free(Ex);
	free(Ez);
	freeMainArrays ( devE );
	freeMainArrays ( devH );
	freeMainArrays ( devCE );
	freePsiArrays ( psixE, psiyE, psizE );
	freePsiArrays ( psixH, psiyH, psizH );
}
