#!/bin/sh
# Name: KPM · 更新软件源
# Author: seven
# 刷新 KPM 的包索引
# Refresh the KPM package sources. /mnt/us is noexec, so call the interpreter.
exec /bin/sh /var/local/kmc/sbin/kpm.sh update
