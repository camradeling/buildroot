#!/bin/bash
echo 10 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio10/direction
