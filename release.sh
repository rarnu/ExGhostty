#!/bin/sh

rm -fr zig-out
rm -fr .zig-cache
zig build -Doptimize=ReleaseSmall

