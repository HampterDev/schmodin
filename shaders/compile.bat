@echo off
REM Compile shaders to SPIR-V
REM Requires Vulkan SDK with glslc in PATH

glslc shader.vert -o vert.spv --target-env=vulkan1.2
glslc shader.frag -o frag.spv --target-env=vulkan1.2

echo Shaders compiled successfully
pause
