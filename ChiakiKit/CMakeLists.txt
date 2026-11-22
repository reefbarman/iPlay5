# iOS build of chiaki-ng's core library (local-network play only).
#
# Builds chiaki-ng lib + jerasure/gf-complete + nanopb + mbedtls 3.6 LTS + opus as
# static libraries for one Apple platform slice. scripts/build-chiaki.sh merges
# the slices into ChiakiKit.xcframework.
#
# Differences from upstream lib/CMakeLists.txt:
# - mbedtls instead of OpenSSL (upstream's Switch code path). chiaki's mbedtls
#   code targets 2.x, so shim/mbedtls_compat.h is force-included to build it
#   against 3.6 without patching the submodule.
# - PSN internet play (remote/holepunch.c, aia*.c) is replaced by stubs, which
#   removes curl, libevent, json-c and miniupnpc.
# - takion.pb.{c,h} are pre-generated in generated/ so protoc/python are not
#   needed at build time. Regenerate them with nanopb's generator from
#   vendor/chiaki-ng/lib/protobuf/takion.proto if a chiaki-ng bump changes it.
# - chiaki-ng's lib/src and lib/include are copied into the build directory and
#   patches/*.patch are applied to the copy (the submodule stays pristine).
#   0001-takion-v20.patch adds the opt-in Takion v20 mode, ported from P5M
#   (https://github.com/beecrepaldi-afk/P5M-mac, AGPL-3.0, mac/TAKION-V20.md).
#   Regenerate a patch against a pristine copy of vendor/chiaki-ng/lib with
#   `diff -ruN a b` (paths a/src/..., applied with patch -p1).

cmake_minimum_required(VERSION 3.20)
project(ChiakiKit C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF)

get_filename_component(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(CHIAKI_DIR "${ROOT}/vendor/chiaki-ng")
set(TP "${CHIAKI_DIR}/third-party")

# ------------------------------------------------------------- mbedtls 3.6 LTS
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
# Applies to mbedtls and chiaki (added later in this directory), so both agree on struct layouts
add_compile_definitions("MBEDTLS_USER_CONFIG_FILE=\"${CMAKE_CURRENT_SOURCE_DIR}/shim/mbedtls_user_config.h\"")
add_subdirectory("${ROOT}/vendor/mbedtls" mbedtls EXCLUDE_FROM_ALL)

# ------------------------------------------------------------------------ opus
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory("${ROOT}/vendor/opus" opus EXCLUDE_FROM_ALL)
# chiaki includes <opus/opus.h>; opus ships include/opus.h
file(COPY "${ROOT}/vendor/opus/include/" DESTINATION "${CMAKE_BINARY_DIR}/opusinc/opus")

# ---------------------------------------------------------------------- nanopb
add_library(nanopb STATIC
	"${TP}/nanopb/pb_common.c"
	"${TP}/nanopb/pb_encode.c"
	"${TP}/nanopb/pb_decode.c")
target_include_directories(nanopb PUBLIC "${TP}/nanopb")
target_compile_definitions(nanopb PUBLIC PB_C99_STATIC_ASSERT)

# --------------------------------------------------------- gf-complete/jerasure
add_library(gf_complete STATIC
	"${TP}/gf-complete/src/gf.c"
	"${TP}/gf-complete/src/gf_wgen.c"
	"${TP}/gf-complete/src/gf_w4.c"
	"${TP}/gf-complete/src/gf_w8.c"
	"${TP}/gf-complete/src/gf_w16.c"
	"${TP}/gf-complete/src/gf_w32.c"
	"${TP}/gf-complete/src/gf_w64.c"
	"${TP}/gf-complete/src/gf_w128.c"
	"${TP}/gf-complete/src/gf_rand.c"
	"${TP}/gf-complete/src/gf_general.c"
	"${TP}/gf-complete/src/gf_cpu.c")
target_include_directories(gf_complete PUBLIC "${TP}/gf-complete/include")
target_compile_options(gf_complete PRIVATE -w)

add_library(jerasure STATIC
	"${TP}/jerasure/src/galois.c"
	"${TP}/jerasure/src/jerasure.c"
	"${TP}/jerasure/src/reed_sol.c"
	"${TP}/jerasure/src/cauchy.c"
	"${TP}/jerasure/src/liberation.c")
target_include_directories(jerasure PUBLIC "${TP}/jerasure/include")
target_link_libraries(jerasure PUBLIC gf_complete)
target_compile_options(jerasure PRIVATE -w)

# ---------------------------------------------------------- patched chiaki lib
set(CHIAKI_LIB "${CMAKE_BINARY_DIR}/chiaki-lib")
file(GLOB CHIAKI_PATCHES "${CMAKE_CURRENT_SOURCE_DIR}/patches/*.patch")
list(SORT CHIAKI_PATCHES)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${CHIAKI_PATCHES})
file(REMOVE_RECURSE "${CHIAKI_LIB}")
file(COPY "${CHIAKI_DIR}/lib/src" "${CHIAKI_DIR}/lib/include" DESTINATION "${CHIAKI_LIB}")
foreach(PATCH_FILE ${CHIAKI_PATCHES})
	execute_process(
		COMMAND patch -p1 --forward --batch --no-backup-if-mismatch -i "${PATCH_FILE}"
		WORKING_DIRECTORY "${CHIAKI_LIB}"
		RESULT_VARIABLE PATCH_RESULT
		OUTPUT_VARIABLE PATCH_OUTPUT
		ERROR_VARIABLE PATCH_OUTPUT)
	if(NOT PATCH_RESULT EQUAL 0)
		message(FATAL_ERROR "Applying ${PATCH_FILE} to chiaki-ng failed:\n${PATCH_OUTPUT}")
	endif()
	message(STATUS "Applied chiaki-ng patch ${PATCH_FILE}")
endforeach()

# ------------------------------------------------------------------ chiaki lib
set(L "${CHIAKI_LIB}/src")
add_library(chiaki STATIC
	${L}/common.c ${L}/sock.c ${L}/session.c ${L}/thread.c ${L}/base64.c
	${L}/http.c ${L}/log.c ${L}/ctrl.c ${L}/rpcrypt.c ${L}/takion.c
	${L}/senkusha.c ${L}/streamconnection.c ${L}/ecdh.c ${L}/launchspec.c
	${L}/random.c ${L}/gkcrypt.c ${L}/audio.c ${L}/audioreceiver.c
	${L}/audiosender.c ${L}/videoreceiver.c ${L}/frameprocessor.c
	${L}/packetstats.c ${L}/discovery.c ${L}/congestioncontrol.c
	${L}/stoppipe.c ${L}/reorderqueue.c ${L}/discoveryservice.c
	${L}/feedback.c ${L}/feedbacksender.c ${L}/controller.c
	${L}/takionsendbuffer.c ${L}/time.c ${L}/fec.c ${L}/regist.c
	${L}/opusdecoder.c ${L}/opusencoder.c ${L}/orientation.c ${L}/bitstream.c
	${L}/remote/rudp.c ${L}/remote/rudpsendbuffer.c
	"${CMAKE_CURRENT_SOURCE_DIR}/generated/takion.pb.c"
	"${CMAKE_CURRENT_SOURCE_DIR}/src/remote_stubs.c"
	"${CMAKE_CURRENT_SOURCE_DIR}/src/ck_bridge.c")

target_include_directories(chiaki
	PUBLIC "${CHIAKI_LIB}/include" "${CMAKE_CURRENT_SOURCE_DIR}/include"
	PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/generated" "${L}" "${CMAKE_BINARY_DIR}/opusinc"
		"${CMAKE_CURRENT_SOURCE_DIR}/shim"
		"${ROOT}/vendor/opus/include")
target_compile_definitions(chiaki PUBLIC
	CHIAKI_LIB_ENABLE_MBEDTLS
	CHIAKI_VERSION_MAJOR=1 CHIAKI_VERSION_MINOR=10 CHIAKI_VERSION_PATCH=1
	CHIAKI_VERSION="1.10.1")
target_compile_options(chiaki PRIVATE -Wall -Wno-unused-function -Wno-unused-variable
	-include "${CMAKE_CURRENT_SOURCE_DIR}/shim/mbedtls_compat.h")
target_link_libraries(chiaki PUBLIC mbedtls mbedx509 mbedcrypto opus nanopb jerasure)

add_custom_target(chiakikit_all ALL DEPENDS chiaki mbedtls mbedx509 mbedcrypto opus nanopb jerasure gf_complete)
