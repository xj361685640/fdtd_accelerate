#!/usr/bin/env python

# Access Patterns used in 3D FDTD
#
#
# f[idx], f[idx+1], f[idx+nx], f[idx+nxy]		# row-major (C)
#
# if( j<ny-1 && k<nz-1 ) ex[idx] += cex[idx]*( hz[idx+nz] - hz[idx] - hy[idx+1] + hy[idx] );
# if( i<nx-1 && k<nz-1 ) ey[idx] += cey[idx]*( hx[idx+1] - hx[idx] - hz[idx+ny*nz] + hz[idx] );
# if( i<nx-1 && j<ny-1 ) ez[idx] += cez[idx]*( hy[idx+ny*nz] - hy[idx] - hx[idx+nz] + hx[idx] );
#
#
# f[idx], f[idx+1], f[idx+nz], f[idx+nyz]		# column-major (Fortran)
#
# if( j<ny-1 && k<nz-1 ) ex[idx] += cex[idx]*( hz[idx+nx] - hz[idx] - hy[idx+nxy] + hy[idx] );
# if( i<nx-1 && k<nz-1 ) ey[idx] += cey[idx]*( hx[idx+nxy] - hx[idx] - hz[idx+1] + hz[idx] );
# if( i<nx-1 && j<ny-1 ) ez[idx] += cez[idx]*( hy[idx+1] - hy[idx] - hx[idx+nx] + hx[idx] );
#


kernels = """
#define TPB 256
#define Dz 16
#define Dy 4
#define Dx 4

texture<float, 3, cudaReadModeElementType> tcex;
texture<float, 3, cudaReadModeElementType> tcey;
texture<float, 3, cudaReadModeElementType> tcez;

__global__ void e_naive(float *ex, float *ey, float *ez, float *hx, float *hy, float *hz, float *cex, float *cey, float *cez) {
	int idx = blockDim.x*blockIdx.x + threadIdx.x;
	int i = idx%nx;
	int j = (idx%nxy)/nx;
	int k = idx/nxy;

	if( j<ny-1 && k<nz-1 ) ex[idx] += cex[idx]*( hz[idx+nx] - hz[idx] - hy[idx+nxy] + hy[idx] );
	if( i<nx-1 && k<nz-1 ) ey[idx] += cey[idx]*( hx[idx+nxy] - hx[idx] - hz[idx+1] + hz[idx] );
	if( i<nx-1 && j<ny-1 ) ez[idx] += cez[idx]*( hy[idx+1] - hy[idx] - hx[idx+nx] + hx[idx] );
}

__global__ void e_naive_tex(float *ex, float *ey, float *ez, float *hx, float *hy, float *hz) {
	int idx = blockDim.x*blockIdx.x + threadIdx.x;
	int i = idx%nx;
	int j = (idx%nxy)/nx;
	int k = idx/nxy;

	if( j<ny-1 && k<nz-1 ) ex[idx] += tex3D(tcex,i,j,k)*( hz[idx+nx] - hz[idx] - hy[idx+nxy] + hy[idx] );
	if( i<nx-1 && k<nz-1 ) ey[idx] += tex3D(tcey,i,j,k)*( hx[idx+nxy] - hx[idx] - hz[idx+1] + hz[idx] );
	if( i<nx-1 && j<ny-1 ) ez[idx] += tex3D(tcez,i,j,k)*( hy[idx+1] - hy[idx] - hx[idx+nx] + hx[idx] );
}

__global__ void e_naive_tex_2dblk(float *ex, float *ey, float *ez, float *hx, float *hy, float *hz) {
	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int bx = blockIdx.x;
	int by = blockIdx.y;
	int i = bx*blockDim.x + tx;
	int j = (by*blockDim.y + ty)%ny;
	int k = (by*blockDim.y + ty)/ny;
	int idx = k*nxy + j*nx + i;

	if( j<ny-1 && k<nz-1 ) ex[idx] += tex3D(tcex,i,j,k)*( hz[idx+nx] - hz[idx] - hy[idx+nxy] + hy[idx] );
	if( i<nx-1 && k<nz-1 ) ey[idx] += tex3D(tcey,i,j,k)*( hx[idx+nxy] - hx[idx] - hz[idx+1] + hz[idx] );
	if( i<nx-1 && j<ny-1 ) ez[idx] += tex3D(tcez,i,j,k)*( hy[idx+1] - hy[idx] - hx[idx+nx] + hx[idx] );
}

__global__ void e_naive_tex_2dblk_2(float *ex, float *ey, float *ez, float *hx, float *hy, float *hz) {
	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int bx = blockIdx.x;
	int by = blockIdx.y;
	int i = (bx*blockDim.x + tx)%nx;
	int j = (bx*blockDim.x + tx)/nx;
	int k = by*blockDim.y + ty;
	int idx = k*nxy + j*nx + i;

	if( j<ny-1 && k<nz-1 ) ex[idx] += tex3D(tcex,i,j,k)*( hz[idx+nx] - hz[idx] - hy[idx+nxy] + hy[idx] );
	if( i<nx-1 && k<nz-1 ) ey[idx] += tex3D(tcey,i,j,k)*( hx[idx+nxy] - hx[idx] - hz[idx+1] + hz[idx] );
	if( i<nx-1 && j<ny-1 ) ez[idx] += tex3D(tcez,i,j,k)*( hy[idx+1] - hy[idx] - hx[idx+nx] + hx[idx] );
}

__global__ void e_naive_tex_3dblk(float *ex, float *ey, float *ez, float *hx, float *hy, float *hz) {
	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int tz = threadIdx.z;
	int bx = blockIdx.x;
	int by = blockIdx.y%(ny/blockDim.y);
	int bz = blockIdx.y/(ny/blockDim.y);
	int i = bx*blockDim.x + tx;
	int j = by*blockDim.y + ty;
	int k = bz*blockDim.z + tz;
	int idx = k*nxy + j*nx + i;

	if( j<ny-1 && k<nz-1 ) ex[idx] += tex3D(tcex,i,j,k)*( hz[idx+nx] - hz[idx] - hy[idx+nxy] + hy[idx] );
	if( i<nx-1 && k<nz-1 ) ey[idx] += tex3D(tcey,i,j,k)*( hx[idx+nxy] - hx[idx] - hz[idx+1] + hz[idx] );
	if( i<nx-1 && j<ny-1 ) ez[idx] += tex3D(tcez,i,j,k)*( hy[idx+1] - hy[idx] - hx[idx+nx] + hx[idx] );
}
"""

import numpy as np
import sys
import pycuda.driver as cuda
import pycuda.autoinit


def arrcopy(mcopy, src, dst):
	mcopy.set_src_host( src )
	mcopy.set_dst_array( dst )
	mcopy()

if __name__ == '__main__':
	nx, ny, nz = 240, 256, 256

	print 'dim (%d, %d, %d)' % (nx, ny, nz)
	total_bytes = nx*ny*nz*4
	if total_bytes/(1024**3) == 0:
		print 'mem %d MB' % ( total_bytes/(1024**2) )
	else:
		print 'mem %1.2f GB' % ( float(total_bytes)/(1024**3) )

	# memory allocate
	#f = np.zeros((nx,ny,nz), 'f', order='F')
	f = np.random.randn(nx*ny*nz).astype(np.float32).reshape((nx,ny,nz), order='F')
	cf = np.ones((nx,ny,nz), 'f', order='F')*0.5

	ex_gpu = cuda.to_device(f)
	ey_gpu = cuda.to_device(f)
	ez_gpu = cuda.to_device(f)
	hx_gpu = cuda.to_device(f)
	hy_gpu = cuda.to_device(f)
	hz_gpu = cuda.to_device(f)

	cex_gpu = cuda.to_device( cf )
	cey_gpu = cuda.to_device( cf )
	cez_gpu = cuda.to_device( cf )

	descr = cuda.ArrayDescriptor3D()
	descr.width = nx
	descr.height = ny
	descr.depth = nz
	descr.format = cuda.dtype_to_array_format(f.dtype)
	descr.num_channels = 1
	descr.flags = 0
	tcex_gpu = cuda.Array(descr)
	tcey_gpu = cuda.Array(descr)
	tcez_gpu = cuda.Array(descr)

	mcopy = cuda.Memcpy3D()
	mcopy.width_in_bytes = mcopy.src_pitch = f.strides[1]
	mcopy.src_height = mcopy.height = ny
	mcopy.depth = nz
	arrcopy(mcopy, cf, tcex_gpu)
	arrcopy(mcopy, cf, tcey_gpu)
	arrcopy(mcopy, cf, tcez_gpu)

	# prepare kernels
	from pycuda.compiler import SourceModule
	mod = SourceModule( kernels.replace('nxy',str(nx*ny)).replace('nx',str(nx)).replace('ny',str(ny)).replace('nz',str(nz)) )
	e_naive = mod.get_function("e_naive")
	e_naive_tex = mod.get_function("e_naive_tex")
	e_naive_tex_2dblk = mod.get_function("e_naive_tex_2dblk")
	e_naive_tex_2dblk_2 = mod.get_function("e_naive_tex_2dblk_2")
	e_naive_tex_3dblk = mod.get_function("e_naive_tex_3dblk")

	tcex = mod.get_texref("tcex")
	tcey = mod.get_texref("tcey")
	tcez = mod.get_texref("tcez")
	tcex.set_array(tcex_gpu)
	tcey.set_array(tcey_gpu)
	tcez.set_array(tcez_gpu)

	# measure kernel execution time
	start = cuda.Event()
	stop = cuda.Event()
	start.record()

	e_naive( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, cex_gpu, cey_gpu, cez_gpu, block=(256,1,1), grid=(nx*ny*nz/256,1) )
	e_naive_tex( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(256,1,1), grid=(nx*ny*nz/256,1), texrefs=[tcex,tcey,tcez])
	e_naive_tex_2dblk( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(16,16,1), grid=(nx/16,ny*nz/16), texrefs=[tcex,tcey,tcez])
	e_naive_tex_2dblk( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(32,16,1), grid=(nx/32,ny*nz/16), texrefs=[tcex,tcey,tcez])
	e_naive_tex_2dblk( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(16,32,1), grid=(nx/16,ny*nz/32), texrefs=[tcex,tcey,tcez])

	e_naive_tex_2dblk_2( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(16,16,1), grid=(nx*ny/16,nz/16), texrefs=[tcex,tcey,tcez])
	e_naive_tex_2dblk_2( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(32,16,1), grid=(nx*ny/32,nz/16), texrefs=[tcex,tcey,tcez])
	e_naive_tex_2dblk_2( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(64,8,1), grid=(nx*ny/64,nz/8), texrefs=[tcex,tcey,tcez])

	e_naive_tex_3dblk( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(16,4,4), grid=(nx/16,ny*nz/16), texrefs=[tcex,tcey,tcez])
	e_naive_tex_3dblk( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(32,4,4), grid=(nx/32,ny*nz/16), texrefs=[tcex,tcey,tcez])
	e_naive_tex_3dblk( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(16,8,4), grid=(nx/16,ny*nz/32), texrefs=[tcex,tcey,tcez])
	e_naive_tex_3dblk( ex_gpu, ey_gpu, ez_gpu, hx_gpu, hy_gpu, hz_gpu, block=(16,4,8), grid=(nx/16,ny*nz/32), texrefs=[tcex,tcey,tcez])

	stop.record()
	stop.synchronize()
	print stop.time_since(start)*1e-3
