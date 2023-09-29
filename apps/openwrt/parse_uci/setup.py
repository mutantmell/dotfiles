#!/usr/bin/env python

from setuptools import setup

setup(
  name='parse-uci',
  version='0.1.0',
  py_modules=['parse_uci'],
  entry_points={
    'console_scripts': ['parse-uci = parse_uci:main']
  },
)
