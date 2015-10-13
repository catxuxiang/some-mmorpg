#!/bin/bash

PROJECT=DzServer
TXT=CMakeLists.txt

echo "cmake_minimum_required(VERSION 3.3)" > $TXT
echo "project(${PROJECT})" >> $TXT
echo "" >> $TXT
echo 'set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++11")' >> $TXT
echo "" >> $TXT
echo 'set(SOURCE_TXTS' >> $TXT
find . \( -name *.lua -o -name *.c -o -name *.h \) -exec echo "    "{} \; >> $TXT
echo ")" >> $TXT
echo "" >> $TXT
echo "add_executable(${PROJECT} \${SOURCE_TXTS})" >> $TXT

echo ok
