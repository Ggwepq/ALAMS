cmake_minimum_required(VERSION 3.4.1)

set(CMAKE_BUILD_TYPE "release")

# Include headers
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

# NCNN static library
add_library(ncnn STATIC IMPORTED)
set_target_properties(ncnn PROPERTIES IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libncnn.a)

# OpenCV shared libraries
add_library(opencv_core SHARED IMPORTED)
set_target_properties(opencv_core PROPERTIES IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libopencv_core.so)

add_library(opencv_imgproc SHARED IMPORTED)
set_target_properties(opencv_imgproc PROPERTIES IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libopencv_imgproc.so)

# Source files
file(GLOB jni_srcs
        "anti_spoof_jni.cpp"
        "img_process.cpp"
        "live/*.cpp"
    )

add_library(antispoof SHARED ${jni_srcs})

target_link_libraries(antispoof log jnigraphics ncnn opencv_core opencv_imgproc android)
