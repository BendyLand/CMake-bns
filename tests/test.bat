@echo off
pushd "%~dp0"
..\bin\debug\cmake-bns.exe /scripts=.. /file=..\cmake-bns.lua %* test
popd
