#!/usr/bin/env python

import numpy as np
import pycuda.driver as cuda
import pycuda.autoinit

MAX_GRID = 65535

kernels ="""
#define Dx 16
#define Dy 8
#define Dz 4
#define sDx 19
#define sDy 11
#define sDz 7

__global__ void update_h(int nx, int ny, int nz, float cl, float *ex, float *ey, float *ez, float *hx, float *hy, float *hz, float *chx, float *chy, float *chz) {
	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int tz = threadIdx.z;
	int gDy = ny/Dy;
	int by = blockIdx.y%gDy;
	int bz = blockIdx.y/gDy;
	int i = blockIdx.x*Dx+tx;
	int j = by*Dy+ty;
	int k = bz*Dz+tz;
	int idx = i + j*nx + k*nx*ny;
	int sidx = tx + ty*sDx + tz*sDx*sDy;

	extern __shared__ float s[];
	float* sx = (float*) &s[2*(sDx*(sDy+1)+1)];
	float* sy = (float*) &sx[sDx*sDy*sDz];
	float* sz = (float*) &sy[sDx*sDy*(sDz-2)];

	sx[sidx] = ex[idx];
	sy[sidx] = ey[idx];
	sz[sidx] = ez[idx];
	if (tx == 0 && i > 1) {
		sy[sidx-2] = ey[idx-2];
		sz[sidx-2] = ez[idx-2];
		sy[sidx-1] = ey[idx-1];
		sz[sidx-1] = ez[idx-1];
	}
	if (tx == Dx-1 && i < nx-1) {
		sy[sidx+1] = ey[idx+1];
		sz[sidx+1] = ez[idx+1];
	}
	if (ty == 0 && j > 1) {
		sx[sidx-2*sDx] = ex[idx-2*nx];
		sz[sidx-2*sDx] = ez[idx-2*nx];
		sx[sidx-sDx] = ex[idx-nx];
		sz[sidx-sDx] = ez[idx-nx];
	}
	if (ty == Dy-1 && j < ny-1) {
		sx[sidx+sDx] = ex[idx+nx];
		sz[sidx+sDx] = ez[idx+nx];
	}
	if (tz == 0 && k > 1) {
		sx[sidx-2*sDx*sDy] = ex[idx-2*nx*ny];
		sy[sidx-2*sDx*sDy] = ey[idx-2*nx*ny];
		sx[sidx-sDx*sDy] = ex[idx-nx*ny];
		sy[sidx-sDx*sDy] = ey[idx-nx*ny];
	}
	if (tz == Dz-1 && k < nz-1) {
		sx[sidx+sDx*sDy] = ex[idx+nx*ny];
		sy[sidx+sDx*sDy] = ey[idx+nx*ny];
	}
	__syncthreads();

	if( j>1 && j<ny-1 && k>1 && k<nz-1 ) 
		hx[idx] -= cl*chx[idx]*( 27*( sz[sidx] - sz[sidx-sDx] - sy[sidx] + sy[sidx-sDx*sDy] )
								- ( sz[sidx+sDx] - sz[sidx-2*sDx] - sy[sidx+sDx*sDy] + sy[sidx-2*sDx*sDy] ) );
	if( i>1 && i<nx-1 && k>1 && k<nz-1 ) 
		hy[idx] -= cl*chy[idx]*( 27*( sx[sidx] - sx[sidx-sDx*sDy] - sz[sidx] + sz[sidx-1] )
								- ( sx[sidx+sDx*sDy] - sx[sidx-2*sDx*sDy] - sz[sidx+1] + sz[sidx-2] ) );
	if( i>1 && i<nx-1 && j>1 && j<ny-1 ) 
		hz[idx] -= cl*chz[idx]*( 27*( sy[sidx] - sy[sidx-1] - sx[sidx] + sx[sidx-sDx] )
								- ( sy[sidx+1] - sy[sidx-2] - sx[idx+sDx] + sx[idx-2*sDx] ) );
}

__global__ void update_e(int nx, int ny, int nz, float dl, float *ex, float *ey, float *ez, float *hx, float *hy, float *hz, float *cex, float *cey, float *cez) {
	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int tz = threadIdx.z;
	int gDy = ny/Dy;
	int by = blockIdx.y%gDy;
	int bz = blockIdx.y/gDy;
	int i = blockIdx.x*Dx+tx;
	int j = by*Dy+ty;
	int k = bz*Dz+tz;
	int idx = i + j*nx + k*nx*ny;
	int sidx = tx + ty*sDx + tz*sDx*sDy;

	extern __shared__ float s[];
	float* sx = (float*) &s[sDx*(sDy+1)+1];
	float* sy = (float*) &sx[sDx*sDy*sDz];
	float* sz = (float*) &sy[sDx*sDy*(sDz-1)];

	sx[sidx] = hx[idx];
	sy[sidx] = hy[idx];
	sz[sidx] = hz[idx];
	if (tx == 0 && i > 0) {
		sy[sidx-1] = hy[idx-1];
		sz[sidx-1] = hz[idx-1];
	}
	if (tx == Dx-1 && i < nx-2) {
		sy[sidx+1] = hy[idx+1];
		sz[sidx+1] = hz[idx+1];
		sy[sidx+2] = hy[idx+2];
		sz[sidx+2] = hz[idx+2];
	}
	if (ty == 0 && j > 0) {
		sx[sidx-sDx] = hx[idx-nx];
		sz[sidx-sDx] = hz[idx-nx];
	}
	if (ty == Dy-1 && j < ny-2) {
		sx[sidx+sDx] = hx[idx+nx];
		sz[sidx+sDx] = hz[idx+nx];
		sx[sidx+2*sDx] = hx[idx+2*nx];
		sz[sidx+2*sDx] = hz[idx+2*nx];
	}
	if (tz == 0 && k > 0) {
		sx[sidx-sDx*sDy] = hx[idx-nx*ny];
		sy[sidx-sDx*sDy] = hy[idx-nx*ny];
	}
	if (tz == Dz-1 && k < nz-2) {
		sx[sidx+sDx*sDy] = hx[idx+nx*ny];
		sy[sidx+sDx*sDy] = hy[idx+nx*ny];
		sx[sidx+2*sDx*sDy] = hx[idx+2*nx*ny];
		sy[sidx+2*sDx*sDy] = hy[idx+2*nx*ny];
	}
	__syncthreads();

	if( j>0 && j<ny-2 && k>0 && k<nz-2 ) 
		ex[idx] += dl*cex[idx]*( 27*( sz[sidx+sDx] - sz[sidx] - sy[sidx+sDx*sDy] + sy[sidx] )
								- ( sz[sidx+2*sDx] - sz[sidx-sDx] - sy[sidx+2*sDx*sDy] + sy[sidx-sDx*sDy] ) );
	if( i>0 && i<nx-2 && k>0 && k<nz-2 ) 
		ey[idx] += dl*cey[idx]*( 27*( sx[sidx+sDx*sDy] - sx[sidx] - sz[sidx+1] + sz[sidx] )
								- ( sx[sidx+2*sDx*sDy] - sx[sidx-sDx*sDy] - sz[sidx+2] + sz[sidx-1] ) );
	if( i>0 && i<nx-2 && j>0 && j<ny-2 ) 
		ez[idx] += dl*cez[idx]*( 27*( sy[sidx+1] - sy[sidx] - sx[sidx+sDx] + sx[sidx] )
								- ( sy[sidx+2] - sy[sidx-1] - sx[sidx+2*sDx] + sx[sidx-sDx] ) );
}

__global__ void update_src(int nx, int ny, int nz, float tn, float *f) {
	int idx = threadIdx.x;
	int ijk = (nz/2)*nx*ny + (ny/2)*nx + idx;

	if( idx < nx ) f[ijk] += sin(0.1*tn);
}
"""


if __name__ == '__main__':
	nx, ny, nz = 256, 256, 240

	S = 0.743	# Courant stability factor
	# symplectic integrator coefficients
	c1, c2, c3 = 0.17399689146541, -0.12038504121430, 0.89277629949778
	d1, d2 = 0.62337932451322, -0.12337932451322
	cl = np.array([c1,c2,c3,c2,c1], dtype=np.float32)
	dl = np.array([d1,d2,d2,d1,0], dtype=np.float32)

	print 'dim (%d, %d, %d)' % (nx, ny, nz)
	total_bytes = nx*ny*nz*4*12
	if total_bytes/(1024**3) == 0:
		print 'mem %d MB' % ( total_bytes/(1024**2) )
	else:
		print 'mem %1.2f GB' % ( float(total_bytes)/(1024**3) )

	# memory allocate
	f = np.zeros((nx,ny,nz), 'f', order='F')
	#f = np.random.randn(nx*ny*nz).astype(np.float32).reshape((nx,ny,nz),order='F')
	cf = np.ones_like(f)*(S/24)

	ex_gpu = cuda.to_device(f)
	ey_gpu = cuda.to_device(f)
	ez_gpu = cuda.to_device(f)
	hx_gpu = cuda.to_device(f)
	hy_gpu = cuda.to_device(f)
	hz_gpu = cuda.to_device(f)

	cex_gpu = cuda.to_device(cf)
	cey_gpu = cuda.to_device(cf)
	cez_gpu = cuda.to_device(cf)
	chx_gpu = cuda.to_device(cf)
	chy_gpu = cuda.to_device(cf)
	chz_gpu = cuda.to_device(cf)

	# prepare kernels
	from pycuda.compiler import SourceModule
	mod = SourceModule(kernels)
	update_h = mod.get_function("update_h")
	update_e = mod.get_function("update_e")
	update_src = mod.get_function("update_src")

	Db = (16,8,4)
	Dg = (nx/16, ny*nz/(8*4))
	print Db, Dg

	nnx, nny, nnz = np.int32(nx), np.int32(ny), np.int32(nz)
	update_h.prepare("iiifPPPPPPPPP", block=Db, shared=(( (16+3)*(8+3)*((4+3)*2 + 4) )*4))
	update_e.prepare("iiifPPPPPPPPP", block=Db, shared=(( (16+3)*(8+3)*((4+3)*2 + 4) )*4))
	update_src.prepare("iiifP", block=(256,1,1))

	# prepare for plot
	from matplotlib.pyplot import *
	ion()
	imsh = imshow(np.ones((ny,nz),'f'), cmap=cm.hot, origin='lower', vmin=0, vmax=0.01)
	colorbar()

	# measure kernel execution time
	#from datetime import datetime
	#t1 = datetime.now()
	start = cuda.Event()
	stop = cuda.Event()
	start.record()

	# main loop
	for tn in xrange(1, 100+1):
		for sn in xrange(4):
			update_h.prepared_call(
					Dg, nnx, nny, nnz, cl[sn],
					ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, 
					chx_gpu, chy_gpu, chz_gpu)

			update_e.prepared_call(
					Dg, nnx, nny, nnz, dl[sn],
					ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, 
					cex_gpu, cey_gpu, cez_gpu)

			update_src.prepared_call((1,1), nnx, nny, nnz, np.float32(tn+sn/5.), ex_gpu)

		update_h.prepared_call(
				Dg, nnx, nny, nnz, cl[4],
				ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, 
				chx_gpu, chy_gpu, chz_gpu)
			
		'''
		if tn%10 == 0:
		#if tn == 100:
			print 'tn =', tn
			cuda.memcpy_dtoh(f, ex_gpu)
			imsh.set_array( f[nx/2,:,:]**2 )
			draw()
			#savefig('./png-wave/%.5d.png' % tstep) 
		'''

	stop.record()
	stop.synchronize()
	print stop.time_since(start)*1e-3
	#print datetime.now() - t1
