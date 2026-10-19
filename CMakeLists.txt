#===----------------------------------------------------------------------===#
#
# Agora's build for Workspace, the file manager and the desktop.
#
# W0 IS THE SMALLEST HONEST WORKSPACE: it launches, it makes ONE borderless window at the desktop level, and it
# fills it with the Argentum wallpaper. It is an APPLICATION, so it consumes the AppKit as a built package
# (`AgoraApp::App`) and installs no package of its own — an application is not a library.
#
# THE BUNDLE IS PART OF THE DELIVERABLE. A program with an `Info.plist` beside it IS a bundle, and that is what
# the launch path and `libagora-launchservices` read, so the build lays `Workspace.app/Contents/` out rather
# than leaving a bare executable.
#
#===----------------------------------------------------------------------===#

cmake_minimum_required(VERSION 3.24)

project(AgoraWorkspace VERSION 0.1.0 LANGUAGES C OBJC)

include(GNUInstallDirs)

set(CMAKE_POSITION_INDEPENDENT_CODE YES)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# THE APPkit, AS A BUILT PACKAGE. It brings Foundation, Core Graphics, Core Text and the Objective-C runtime
# on its own interface, so nothing else is found here.
find_package(AgoraApp CONFIG REQUIRED)
find_package(AgoraIconServices CONFIG REQUIRED)
find_package(AgoraLaunchServices CONFIG REQUIRED)

add_executable(Workspace
    src/main.m
    src/WSAboutPanel.m
    src/WSApplication.m
    src/WSDesktopWindow.m
    src/WSDesktopView.m
    src/WSIconView.m
    src/WSFileWindowController.m
    src/WSHistory.m
    src/WSIconLayout.m
    src/WSItemIcons.m
    src/WSItemKind.m
    src/WSItemModel.m
    src/WSItemSort.m
    src/WSMainMenu.m
    src/WSListView.m
    src/WSMetadataStore.m
    src/WSPlaces.m
    src/WSPreferencesWindow.m)

# **THE CHROME'S THEME, AS THE APPKIT'S OWN DEMONSTRATION DOES IT.** The library resolves a theme only when
# `AGORA_CHROME_THEME` names one — the right default for a LIBRARY, which must not go looking for other people's
# art. An APPLICATION is the other case: without a theme its windows draw the chrome's fallback marks, which is
# why Workspace's About window showed flat grey stoplights beside the controls demo's real ones. The directory is
# the sibling's and is git-ignored (it may be absent), and an explicit `AGORA_CHROME_THEME` still wins.
# The path is resolved to a REAL one, so the resolved theme a log prints has no `..` in it.
get_filename_component(_ws_chrome_themes
    "${CMAKE_CURRENT_SOURCE_DIR}/../libagora-app/themes" REALPATH BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(Workspace PRIVATE AGORA_CHROME_DEFAULT_THEME="${_ws_chrome_themes}")

target_include_directories(Workspace PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(Workspace PRIVATE
    AgoraApp::App
    AgoraIconServices::IconServices
    AgoraLaunchServices::LaunchServices)

# ---------------------------------------------------------------------------
# The bundle: Workspace.app/Contents/{Info.plist, MacOS/Workspace}
# ---------------------------------------------------------------------------
set(_bundle "${CMAKE_BINARY_DIR}/Workspace.app")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in" "${_bundle}/Contents/Info.plist" @ONLY)
add_custom_command(TARGET Workspace POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_bundle}/Contents/MacOS"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:Workspace>"
            "${_bundle}/Contents/MacOS/Workspace"
    VERBATIM)

enable_testing()
add_subdirectory(tests)
