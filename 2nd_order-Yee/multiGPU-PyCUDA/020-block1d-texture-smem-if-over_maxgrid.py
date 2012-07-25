#!/usr/bin/env python

import numpy as np
import pycuda.driver as cuda
import pycuda.autoinit

MAX_GRID = 65535

kernels = """
texture<float, 1, cudaReadModeElementType> tcex;
texture<float, 1, cudaReadModeElementType> tcey;
texture<float, 1, cudaReadModeElementType> tcez;
texture<float, 1, cudaReadModeElementType> tchx;
texture<float, 1, cudaReadModeElementType> tchy;
texture<float, 1, cudaReadModeElementType> tchz;

__global__ void update_e(int nx, int ny, int nz, int idx0, float *ex, float *ey, float *ez, float *hx, float *hy, float *hz) {
	int tx = threadIdx.x;
	int idx = blockIdx.x*blockDim.x + tx + idx0;

	extern __shared__ float s[];
	float* sx = (float*) s;
	float* sy = (float*) &sx[blockDim.x+1];
	float* sz = (float*) &sy[blockDim.x+1];

	sx[tx] = hx[idx];
	sy[tx] = hy[idx];
	sz[tx] = hz[idx];
	__syncthreads();

	float hy_x = sy[tx+1];
	float hz_x = sz[tx+1];
	if( tx == blockDim.x - 1 ) {
		hy_x = hy[idx+1];
		hz_x = hz[idx+1];
	}

	int k = idx/(nx*ny);
	int j = (idx - k*nx*ny)/nx;
	int i = idx%nx;

	if( j<ny-1 && k<nz-1 ) ex[idx] += tex1Dfetch(tcex,idx)*( hz[idx+nx] - sz[tx] - hy[idx+nx*ny] + sy[tx] );
	if( i<nx-1 && k<nz-1 ) ey[idx] += tex1Dfetch(tcey,idx)*( hx[idx+nx*ny] - sx[tx] - hz_x + sz[tx] );
	if( i<nx-1 && j<ny-1 ) ez[idx] += tex1Dfetch(tcez,idx)*( hy_x - sy[tx] - hx[idx+nx] + sx[tx] );
}

__global__ void update_h(int nx, int ny, int nz, int idx0, float *ex, float *ey, float *ez, float *hx, float *hy, float *hz) {
	int tx = threadIdx.x;
	int idx = blockIdx.x*blockDim.x + tx + idx0;

	extern __shared__ float s[];
	float* sx = (float*) s;
	float* sy = (float*) &sx[blockDim.x];
	float* sz = (float*) &sy[blockDim.x];

	sx[tx] = ex[idx];
	sy[tx] = ey[idx];
	sz[tx] = ez[idx];
	__syncthreads();

	float hy_x = sy[tx-1];
	float hz_x = sz[tx-1];
	if( tx == 0 ) {
		hy_x = ey[idx-1];
		hz_x = ez[idx-1];
	}

	int k = idx/(nx*ny);
	int j = (idx - k*nx*ny)/nx;
	int i = idx%nx;

	if( j>0 && k>0 ) hx[idx] -= tex1Dfetch(tchx,idx)*( sz[tx] - ez[idx-nx] - sy[tx] + ey[idx-nx*ny] );
	if( i>0 && k>0 ) hy[idx] -= tex1Dfetch(tchy,idx)*( sx[tx] - ex[idx-nx*ny] - sz[tx] + hz_x );
	if( i>0 && j>0 ) hz[idx] -= tex1Dfetch(tchz,idx)*( sy[tx] - hy_x - sx[tx] + ex[idx-nx] );
}

__global__ void update_src(int nx, int ny, int nz, int tn, float *f) {
	int idx = threadIdx.x;
	int ijk = (nz/2)*nx*ny + (ny/2)*nx + idx;

	if( idx < nx ) f[ijk] += sin(0.1*tn);
}
"""


def set_c(cf, pt):
	cf[:,:,:] = 0.5
	if pt[0] != None: cf[pt[0],:,:] = 0
	if pt[1] != None: cf[:,pt[1],:] = 0
	if pt[2] != None: cf[:,:,pt[2]] = 0

	return cf


if __name__ == '__main__':
	nx, ny, nz = 512, 512, 335

	print 'dim (%d, %d, %d)' % (nx, ny, nz)
	total_bytes = nx*ny*nz*4*12
	if total_bytes/(1024**3) == 0:
		print 'mem %d MB' % ( total_bytes/(1024**2) )
	else:
		print 'mem %1.2f GB' % ( float(total_bytes)/(1024**3) )

	# memory allocate
	f = np.zeros((nx,ny,nz), 'f', order='F')

	ex_gpu = cuda.to_device(f)
	ey_gpu = cuda.to_device(f)
	ez_gpu = cuda.to_device(f)
	hx_gpu = cuda.to_device(f)
	hy_gpu = cuda.to_device(f)
	hz_gpu = cuda.to_device(f)

	cex_gpu = cuda.to_device( set_c(f,(None,-1,-1)) )
	cey_gpu = cuda.to_device( set_c(f,(-1,None,-1)) )
	cez_gpu = cuda.to_device( set_c(f,(-1,-1,None)) )
	chx_gpu = cuda.to_device( set_c(f,(None,0,0)) )
	chy_gpu = cuda.to_device( set_c(f,(0,None,0)) )
	chz_gpu = cuda.to_device( set_c(f,(0,0,None)) )

	# prepare kernels
	from pycuda.compiler import SourceModule
	mod = SourceModule(kernels)
	update_e = mod.get_function("update_e")
	update_h = mod.get_function("update_h")
	update_src = mod.get_function("update_src")

	# bind a texture reference to linear memory
	tcex = mod.get_texref("tcex")
	tcey = mod.get_texref("tcey")
	tcez = mod.get_texref("tcez")
	tchx = mod.get_texref("tchx")
	tchy = mod.get_texref("tchy")
	tchz = mod.get_texref("tchz")

	tcex.set_address(cex_gpu, f.nbytes)
	tcey.set_address(cey_gpu, f.nbytes)
	tcez.set_address(cez_gpu, f.nbytes)
	tchx.set_address(chx_gpu, f.nbytes)
	tchy.set_address(chy_gpu, f.nbytes)
	tchz.set_address(chz_gpu, f.nbytes)


	tpb = 256
	bpg = (nx*ny*nz)/tpb

	Db = (tpb,1,1)
	Dg_list = [ (bpg%MAX_GRID, 1) ]
	idx0_list = [ np.int32(0) ]
	ng = int( np.ceil( float(bpg)/MAX_GRID ) )
	for i in range(1, ng): 
		Dg_list.insert( 0, (MAX_GRID, 1) )
		idx0_list.append( np.int32(MAX_GRID*tpb*(i)) )
	print Db
	print Dg_list
	print idx0_list

	nnx, nny, nnz = np.int32(nx), np.int32(ny), np.int32(nz)
	update_e.prepare("iiiiPPPPPP", block=Db, texrefs=[tcex,tcey,tcez], shared=tpb*3*4)
	update_h.prepare("iiiiPPPPPP", block=Db, texrefs=[tchx,tchy,tchz], shared=tpb*3*4)
	update_src.prepare("iiiiP", block=(512,1,1))

	'''
	# prepare for plot
	from matplotlib.pyplot import *
	ion()
	imsh = imshow(np.ones((ny,nz),'f'), cmap=cm.hot, origin='lower', vmin=0, vmax=0.001)
	colorbar()
	'''

	# measure kernel execution time
	#from datetime import datetime
	#t1 = datetime.now()
	start = cuda.Event()
	stop = cuda.Event()
	start.record()

	# main loop
	for tn in xrange(1, 1001):
		for i, Dg in enumerate(Dg_list): update_e.prepared_call(
				Dg, nnx, nny, nnz, idx0_list[i],
				ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu)

		update_src.prepared_call((1,1), nnx, nny, nnz, np.int32(tn), ex_gpu)

		for i, Dg in enumerate(Dg_list): update_h.prepared_call(
				Dg, nnx, nny, nnz, idx0_list[i],
				ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu)
			
		'''
		if tn%100 == 0:
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
