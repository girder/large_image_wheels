# jxrlib.cmake - a cmake build for jxrlib (JPEG XR; the 4creators fork the
# linux and macos builds use), copied into the source tree as
# CMakeLists.txt by build_wheels.ps1.  jxrlib's own build is a GNU
# Makefile (the linux build runs it; macos patches it), and the Visual
# Studio project files it ships predate the toolset in use; this file
# builds the same two shared libraries from the same source lists as the
# Makefile (SRC_SYS/SRC_DEC/SRC_ENC -> jpegxr, SRC_GLUE -> jxrglue), with
# the Makefile's defines, installs the headers in the Makefile's layout,
# and writes the same libjxr.pc, so openslide's zeiss-czi-jxr patch finds
# the library through pkg-config exactly as on linux.
#
# The sources carry no export declarations; WINDOWS_EXPORT_ALL_SYMBOLS
# gives the DLLs the export table the ELF/Mach-O builds have implicitly.

cmake_minimum_required(VERSION 3.16)
project(jxrlib C)

set(JXR_VERSION 1.1)
add_compile_definitions(__ANSI__ DISABLE_PERF_MEASUREMENT _CRT_SECURE_NO_WARNINGS)
# image/sys/ansi.h sizes its pointer-width integers by __LP64__, which
# MSVC never defines; without it the 64-bit build fails its own
# compile-time assertion (strcodec.h: sizeof(UINTPTR_T) == sizeof(void*)).
# Consumers compile the same headers, so the define goes into libjxr.pc
# as well.
set(JXR_EXTRA_CFLAGS "")
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  add_compile_definitions(__LP64__=1)
  set(JXR_EXTRA_CFLAGS " -D__LP64__=1")
endif()
# The Makefile compiles with -w; the code is old and noisy.
if(MSVC)
  string(APPEND CMAKE_C_FLAGS " /w")
endif()
include_directories(common/include image/sys jxrgluelib jxrtestlib)

# JXRMeta.h uses __in_win/__out_win, which it knows only through its own
# wmsal.h -- and wmspecstring.h skips wmsal.h once MSVC's specstrings.h
# (via windows.h) has been included, as it is in openslide's sources.
# Define them from sal.h's __in/__out when they are missing (the header
# does that already under WIN32, which would also select the non-ANSI
# platform code).  Patched in the source so the installed header carries
# it; the file may have either line ending.
# JXRGlue.h declares the two IID_PKImageWmp* constants as plain extern
# data.  WINDOWS_EXPORT_ALL_SYMBOLS skips read-only data, so the library
# build exports them explicitly (JXR_DLL_EXPORT, defined for jxrglue
# below; the declaration's dllexport carries over to the definition in
# JXRGlue.c), and a consumer of jxrglue.dll can only link data through a
# dllimport declaration (MSVC thunks functions, not data), which
# JXR_DLL_IMPORT adds -- only libjxr.pc's Cflags define that.
file(READ "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRGlue.h" _jxr_glue)
string(REPLACE "EXTERN_C const PKIID IID_PKImageWmpEncode;"
  "#if defined(_WIN32) && defined(JXR_DLL_EXPORT)
#define JXR_DATA __declspec(dllexport)
#elif defined(_WIN32) && defined(JXR_DLL_IMPORT)
#define JXR_DATA __declspec(dllimport)
#else
#define JXR_DATA
#endif
EXTERN_C JXR_DATA const PKIID IID_PKImageWmpEncode;" _jxr_glue "${_jxr_glue}")
string(REPLACE "EXTERN_C const PKIID IID_PKImageWmpDecode;"
  "EXTERN_C JXR_DATA const PKIID IID_PKImageWmpDecode;" _jxr_glue "${_jxr_glue}")
file(WRITE "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRGlue.h" "${_jxr_glue}")

file(READ "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRMeta.h" _jxr_meta)
string(REGEX REPLACE "#ifdef WIN32(\r?\n)#define __in_win"
  "#if defined(WIN32) || !defined(__in_win)\\1#define __in_win" _jxr_meta "${_jxr_meta}")
file(WRITE "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRMeta.h" "${_jxr_meta}")

set(SRC_SYS adapthuff.c image.c strcodec.c strPredQuant.c strTransform.c perfTimerANSI.c)
list(TRANSFORM SRC_SYS PREPEND image/sys/)
set(SRC_DEC decode.c postprocess.c segdec.c strdec.c strInvTransform.c strPredQuantDec.c JXRTranscode.c)
list(TRANSFORM SRC_DEC PREPEND image/decode/)
set(SRC_ENC encode.c segenc.c strenc.c strFwdTransform.c strPredQuantEnc.c)
list(TRANSFORM SRC_ENC PREPEND image/encode/)
set(SRC_GLUE JXRGlue.c JXRMeta.c JXRGluePFC.c JXRGlueJxr.c)
list(TRANSFORM SRC_GLUE PREPEND jxrgluelib/)

add_library(jpegxr SHARED ${SRC_SYS} ${SRC_DEC} ${SRC_ENC})
set_target_properties(jpegxr PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
add_library(jxrglue SHARED ${SRC_GLUE})
set_target_properties(jxrglue PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
target_compile_definitions(jxrglue PRIVATE JXR_DLL_EXPORT)
target_link_libraries(jxrglue PRIVATE jpegxr)

install(TARGETS jpegxr jxrglue
  RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
install(DIRECTORY common/include/ DESTINATION include/libjxr/common FILES_MATCHING PATTERN "*.h")
install(DIRECTORY image/x86/ DESTINATION include/libjxr/image/x86 FILES_MATCHING PATTERN "*.h")
install(DIRECTORY image/sys/ image/encode/ image/decode/ DESTINATION include/libjxr/image FILES_MATCHING PATTERN "*.h")
install(DIRECTORY jxrgluelib/ DESTINATION include/libjxr/glue FILES_MATCHING PATTERN "*.h")
install(DIRECTORY jxrtestlib/ DESTINATION include/libjxr/test FILES_MATCHING PATTERN "*.h")

# The Makefile's libjxr.pc (its template uses python %-formatting).
file(WRITE "${CMAKE_BINARY_DIR}/libjxr.pc"
"prefix=${CMAKE_INSTALL_PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libjxr
Description: A library for reading JPEG XR images.

Version: ${JXR_VERSION}
Libs: -L\${libdir} -ljpegxr -ljxrglue
Libs.private: -lm
Cflags: -I\${includedir}/libjxr/common -I\${includedir}/libjxr/image/x86 -I\${includedir}/libjxr/image -I\${includedir}/libjxr/glue -I\${includedir}/libjxr/test -D__ANSI__ -DDISABLE_PERF_MEASUREMENT -DJXR_DLL_IMPORT${JXR_EXTRA_CFLAGS}
")
install(FILES "${CMAKE_BINARY_DIR}/libjxr.pc" DESTINATION lib/pkgconfig)
