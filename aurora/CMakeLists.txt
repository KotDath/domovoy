# This file will be recreated at the next build. To avoid this, delete this line.

# CMAKE_SYSTEM_PROCESSOR - CPU architecture name (armv7l, aarch64, x86_64)
# CMAKE_BUILD_TYPE       - Build mode (debug, profile, release)

cmake_minimum_required(VERSION 3.10)
project(${FLUTTER_PROJECT_NAME} LANGUAGES CXX)

include(GNUInstallDirs)

set(BINARY_NAME ${CMAKE_PROJECT_NAME})
set(FLUTTER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/flutter)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_CXX_FLAGS "-Wall -Wextra")
set(CMAKE_CXX_FLAGS_RELEASE "-O3")

set(CMAKE_SKIP_RPATH OFF)
set(CMAKE_INSTALL_RPATH "\$ORIGIN/../share/${BINARY_NAME}/lib")

add_executable(${BINARY_NAME} main.cpp)

include(flutter/generated_plugins.cmake)

set(PACKAGE_INSTALL_DIR    ${CMAKE_INSTALL_DATADIR}/${BINARY_NAME})
set(DESKTOP_INSTALL_DIR    ${CMAKE_INSTALL_DATADIR}/applications)
set(ICONS_INSTALL_ROOT_DIR ${CMAKE_INSTALL_DATADIR}/icons/hicolor)

install(FILES     ${PROJECT_BINARY_DIR}/bundle/icudtl.dat     DESTINATION ${PACKAGE_INSTALL_DIR})
install(DIRECTORY ${PROJECT_BINARY_DIR}/bundle/flutter_assets DESTINATION ${PACKAGE_INSTALL_DIR})
install(DIRECTORY ${PROJECT_BINARY_DIR}/bundle/lib            DESTINATION ${PACKAGE_INSTALL_DIR})

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES desktop/${BINARY_NAME}.desktop DESTINATION ${DESKTOP_INSTALL_DIR})

foreach(ICONS_SIZE 86x86 108x108 128x128 172x172)
    install(FILES icons/${ICONS_SIZE}.png
            RENAME ${BINARY_NAME}.png
            DESTINATION ${ICONS_INSTALL_ROOT_DIR}/${ICONS_SIZE}/apps/)
endforeach(ICONS_SIZE)
