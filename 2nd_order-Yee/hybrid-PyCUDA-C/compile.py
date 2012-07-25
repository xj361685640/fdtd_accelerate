#!/usr/bin/env python

import os

c_file = 'dielectric.c'
so_file = 'dielectric.so'

cmd = 'gcc -O3 -fpic -msse -fopenmp -I/usr/include/python2.6 -I/usr/lib/python2.6/site-packages/numpy/core/include -shared %s -o %s' %(c_file, so_file)
print cmd

os.system(cmd)