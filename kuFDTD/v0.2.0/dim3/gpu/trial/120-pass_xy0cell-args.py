#!/usr/bin/env python

from kufdtd.common import *
from kufdtd.dim3.gpu.base import *
from kufdtd.dim3.gpu.matter import Dielectric
from kufdtd.dim3.gpu.source import Source

import pycuda.autoinit


#--------------------------------------------------------------------
class DielectricIf( Dielectric ):
	def allocate_coeff( s ):
		shape = (s.Nx, s.Ny, s.Nz)
		s.CEx = sc.zeros( shape, 'f' )
		s.CEy = sc.zeros( shape, 'f' )
		s.CEz = sc.zeros( shape, 'f' )


	def set_coeff( s ):
		s.CEx[1:,1:-1,1:-1] = 0.5
		s.CEy[1:-1,1:,1:-1] = 0.5
		s.CEz[1:-1,1:-1,1:] = 0.5


	def allocate_main_in_dev( s ):
		s.devEx = cuda.mem_alloc( s.bytes )
		s.devEy = cuda.mem_alloc( s.bytes )
		s.devEz = cuda.mem_alloc( s.bytes )
		s.devHx = cuda.mem_alloc( s.bytes )
		s.devHy = cuda.mem_alloc( s.bytes )
		s.devHz = cuda.mem_alloc( s.bytes )


	def initmem_main_in_dev( s ):
		initmem = s.get_kernel_initmem()

		tpb = 512
		Db = (tpb,1,1)

		bpg = s.calc_bpg( s.size, tpb )
		N = sc.int32( s.size )
		Dg = (bpg,1)

		initmem( N, s.devEx, block=Db, grid=Dg )
		initmem( N, s.devEy, block=Db, grid=Dg )
		initmem( N, s.devEz, block=Db, grid=Dg )

		initmem( N, s.devHx, block=Db, grid=Dg )
		initmem( N, s.devHy, block=Db, grid=Dg )
		initmem( N, s.devHz, block=Db, grid=Dg )
		                      

	def allocate_coeff_in_dev( s ):
		s.devCEx = cuda.mem_alloc( s.bytes )
		s.devCEy = cuda.mem_alloc( s.bytes )
		s.devCEz = cuda.mem_alloc( s.bytes )


	def set_kernel_parameters( s ):
		s.tpb_main = 512
		#s.bpg_main = s.calc_bpg( s.size, s.tpb_main )
		s.bpg_main = s.calc_bpg( (s.Nx-1)*(s.Ny-1)*s.Nz, s.tpb_main )
		s.ns_main = ( 2*(s.tpb_main+1)+s.tpb_main )*s.bytes_f


	def prepare_kernels( s ):
		fpath = '%s/trial/core/pass_xy0cell-args.cu' % base_dir
		mod = cuda.SourceModule( file( fpath,'r' ).read() )
		s.update_e = mod.get_function("update_e")
		s.update_h = mod.get_function("update_h")

		Db = ( s.tpb_main, 1, 1 )
		s.update_e.prepare( "iiiiiPPPPPPPPP", block=Db )
		s.update_h.prepare( "iiiiiPPPPPP", block=Db )


	def updateE( s ):
		s.update_e.prepared_call( \
				( s.bpg_main, 1 ), \
				sc.int32( (s.Nx-1)*(s.Ny-1)*s.Nz ), s.kNz, sc.int32(s.Ny*s.Nz), sc.int32( (s.Ny-1)*s.Nz ), sc.int32( s.Ny*s.Nz + s.Nz ), \
				s.devEx, s.devEy, s.devEz, \
				s.devHx, s.devHy, s.devHz, \
				s.devCEx, s.devCEy, s.devCEz )
	

	def updateH( s ):
		s.update_h.prepared_call( \
				( s.bpg_main, 1 ), \
				sc.int32( (s.Nx-1)*(s.Ny-1)*s.Nz ), s.kNz, sc.int32(s.Ny*s.Nz), sc.int32( (s.Ny-1)*s.Nz ), sc.int32( s.Ny*s.Nz + s.Nz ), \
				s.devEx, s.devEy, s.devEz, \
				s.devHx, s.devHy, s.devHz )


#--------------------------------------------------------------------
Nx, Ny, Nz = 300, 300, 304
dx = 10e-9

#--------------------------------------------------------------------
S = DielectricIf( Nx, Ny, Nz, dx )

S.allocate_main_in_dev()
S.initmem_main_in_dev()
S.allocate_coeff_in_dev()

S.allocate_coeff()
S.set_coeff()
S.memcpy_htod_coeff()

S.set_kernel_parameters()
S.prepare_kernels()

#--------------------------------------------------------------------
Src = Source( S )
Src.prepare_kernels()

#--------------------------------------------------------------------
print '-'*47
print 'N(%d, %d, %d)' % (S.Nx, S.Ny, S.Nz)
print 'dx = %g' % S.dx
print 'dt = %g' % S.dt
print ''
S.print_main_kernel_parameters()
print '-'*47

#--------------------------------------------------------------------
# Output
Ez = sc.zeros( (Nx, Ny, Nz), 'f' )

'''
#--------------------------------------------------------------------
# Graphic
from pylab import *
ion()
figure()

Ez[:,:,Nz/2] = 1
imsh = imshow( transpose( Ez[:,:,Nz/2] ),
				cmap=cm.jet,
				vmin=-0.05, vmax=0.05,
				origin='lower',
				interpolation='bilinear')
colorbar()
'''

#--------------------------------------------------------------------
from time import *
t0 = time()
for tstep in xrange( 1, 11 ):
	S.updateE()

	Src.updateE( tstep, S.devEz )

	S.updateH()
	
	'''
	if tstep/50*50 == tstep:
		print_elapsed_time( t0, time(), tstep )
		
		cuda.memcpy_dtoh( Ez, S.devEz )
		imsh.set_array( transpose( Ez[:,:,Nz/2] ) )
		png_str = './gpu_png/Ez-%.6d.png' % tstep
		savefig(png_str) 
	'''


print_elapsed_time( t0, time(), tstep )


S.free_main_in_dev()
S.free_coeff_in_dev()
S.free_coeff()
