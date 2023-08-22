#!/usr/bin/env bash

for i in three-chained-ints three-separate-ints ; do
  vault namespace delete $i
  if [ -d $i ] ; then
    rm -rf ./$i
  fi
done
