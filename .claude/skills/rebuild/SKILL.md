---
name: rebuild
description: Build orangepi3 firmware image using test.vars configuration
---

# Rebuild

## When to Use

When the user says /rebuild or asks to build the orangepi3 image.

## Steps

1. **Run the build in the background:**

   ```bash
   cd /home/denisov/progs/buildroot/output_orangepi3 && ./build.sh test.vars
   ```

   Use `run_in_background: true` and `timeout: 1800000` (30 minutes).

2. **When the build completes**, check exit code for success.

3. **On success**, report the build output image path:

   ```
   output_orangepi3/images/sdcard.img
   ```

## Error Handling

| Error | Fix |
|-------|-----|
| Build fails | Show the last 50 lines of output and diagnose the error |
