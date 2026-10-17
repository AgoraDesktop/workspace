# Workspace's own suite.
#
# W0 IS MEASURED AGAINST AGORA'S OWN WINDOW SERVER, because a desktop window is only a desktop window if the
# COMPOSITOR put it below everything. The suite runs the server headless, runs the BUNDLE's executable (not the
# bare binary — the bundle path is part of what W0 proves), places a NORMAL window over the desktop with the
# server's own test client, and reads the server's screenshot.

find_program(PYTHON3 python3 REQUIRED)

# THE OFFSCREEN SUITES need Foundation and nothing else — no compositor, no AppKit.
find_package(Foundation CONFIG REQUIRED)
find_package(libobjc CONFIG REQUIRED)

add_executable(desktop_layout desktop_layout.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLayout.m")
target_include_directories(desktop_layout PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(desktop_layout PRIVATE Foundation::Foundation objc)
add_test(NAME workspace-desktop-layout COMMAND desktop_layout)
set_tests_properties(workspace-desktop-layout PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>")

add_executable(metadata_store metadata_store.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMetadataStore.m")
target_include_directories(metadata_store PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(metadata_store PRIVATE Foundation::Foundation objc)
add_test(NAME workspace-metadata-store COMMAND metadata_store)
set_tests_properties(workspace-metadata-store PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>")

# The sibling's built outputs. Named and cached BEFORE use, so a fresh configure does not expand them to
# nothing — the trap libagora-app's own tests record.
set(AGORA_WINDOW_SERVER_BINARY
    "${CMAKE_CURRENT_SOURCE_DIR}/../../window-server/build/window-server"
    CACHE FILEPATH "window-server's built binary, for the desktop suite")
set(AGORA_WINDOW_SERVER_TEST_CLIENT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../window-server/build/tests/window-server-test-client"
    CACHE FILEPATH "window-server's test client, which draws a NORMAL window over the desktop")

add_test(NAME workspace-desktop
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run-desktop.sh"
            "$<TARGET_FILE_DIR:Workspace>/Workspace.app/Contents/MacOS/Workspace"
            "${AGORA_WINDOW_SERVER_BINARY}"
            "${AGORA_WINDOW_SERVER_TEST_CLIENT}"
            "${PYTHON3}"
            "${CMAKE_CURRENT_SOURCE_DIR}/check.py")

set_tests_properties(workspace-desktop PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:AgoraApp::App>")
