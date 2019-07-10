function(add_lldb_library name)
  # only supported parameters to this macro are the optional
  # MODULE;SHARED;STATIC library type and source files
  cmake_parse_arguments(PARAM
    "MODULE;SHARED;STATIC;OBJECT;PLUGIN"
    "INSTALL_PREFIX;ENTITLEMENTS"
    "EXTRA_CXXFLAGS;DEPENDS;LINK_LIBS;LINK_COMPONENTS"
    ${ARGN})
  llvm_process_sources(srcs ${PARAM_UNPARSED_ARGUMENTS})
  list(APPEND LLVM_LINK_COMPONENTS ${PARAM_LINK_COMPONENTS})

  if(PARAM_PLUGIN)
    set_property(GLOBAL APPEND PROPERTY LLDB_PLUGINS ${name})
  endif()

  if (MSVC_IDE OR XCODE)
    string(REGEX MATCHALL "/[^/]+" split_path ${CMAKE_CURRENT_SOURCE_DIR})
    list(GET split_path -1 dir)
    file(GLOB_RECURSE headers
      ../../include/lldb${dir}/*.h)
    set(srcs ${srcs} ${headers})
  endif()
  if (PARAM_MODULE)
    set(libkind MODULE)
  elseif (PARAM_SHARED)
    set(libkind SHARED)
  elseif (PARAM_OBJECT)
    set(libkind OBJECT)
  else ()
    # PARAM_STATIC or library type unspecified. BUILD_SHARED_LIBS
    # does not control the kind of libraries created for LLDB,
    # only whether or not they link to shared/static LLVM/Clang
    # libraries.
    set(libkind STATIC)
  endif()

  #PIC not needed on Win
  # FIXME: Setting CMAKE_CXX_FLAGS here is a no-op, use target_compile_options
  # or omit this logic instead.
  if (NOT WIN32)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC")
  endif()

  if (PARAM_OBJECT)
    add_library(${name} ${libkind} ${srcs})
  else()
    if(PARAM_ENTITLEMENTS)
      set(pass_ENTITLEMENTS ENTITLEMENTS ${PARAM_ENTITLEMENTS})
    endif()

    if(LLDB_NO_INSTALL_DEFAULT_RPATH)
      set(pass_NO_INSTALL_RPATH NO_INSTALL_RPATH)
    endif()

    llvm_add_library(${name} ${libkind} ${srcs}
      LINK_LIBS ${PARAM_LINK_LIBS}
      DEPENDS ${PARAM_DEPENDS}
      ${pass_ENTITLEMENTS}
      ${pass_NO_INSTALL_RPATH}
    )
  endif()

  if(PARAM_SHARED)
    set(install_dest lib${LLVM_LIBDIR_SUFFIX})
    if(PARAM_INSTALL_PREFIX)
      set(install_dest ${PARAM_INSTALL_PREFIX})
    endif()
    # RUNTIME is relevant for DLL platforms, FRAMEWORK for macOS
    install(TARGETS ${name} COMPONENT ${name}
      RUNTIME DESTINATION bin
      LIBRARY DESTINATION ${install_dest}
      ARCHIVE DESTINATION ${install_dest}
      FRAMEWORK DESTINATION ${install_dest})
    if (NOT CMAKE_CONFIGURATION_TYPES)
      add_llvm_install_targets(install-${name}
                              DEPENDS ${name}
                              COMPONENT ${name})
    endif()
  endif()

  # Hack: only some LLDB libraries depend on the clang autogenerated headers,
  # but it is simple enough to make all of LLDB depend on some of those
  # headers without negatively impacting much of anything.
  if(NOT LLDB_BUILT_STANDALONE)
    add_dependencies(${name} clang-tablegen-targets)
  endif()

  # Add in any extra C++ compilation flags for this library.
  target_compile_options(${name} PRIVATE ${PARAM_EXTRA_CXXFLAGS})

  if(PARAM_PLUGIN)
    set_target_properties(${name} PROPERTIES FOLDER "lldb plugins")
  else()
    set_target_properties(${name} PROPERTIES FOLDER "lldb libraries")
  endif()
endfunction(add_lldb_library)

function(add_lldb_executable name)
  cmake_parse_arguments(ARG
    "GENERATE_INSTALL"
    "INSTALL_PREFIX;ENTITLEMENTS"
    "LINK_LIBS;LINK_COMPONENTS"
    ${ARGN}
    )

  if(ARG_ENTITLEMENTS)
    set(pass_ENTITLEMENTS ENTITLEMENTS ${ARG_ENTITLEMENTS})
  endif()

  if(LLDB_NO_INSTALL_DEFAULT_RPATH)
    set(pass_NO_INSTALL_RPATH NO_INSTALL_RPATH)
  endif()

  list(APPEND LLVM_LINK_COMPONENTS ${ARG_LINK_COMPONENTS})
  add_llvm_executable(${name}
    ${pass_ENTITLEMENTS}
    ${pass_NO_INSTALL_RPATH}
    ${ARG_UNPARSED_ARGUMENTS}
  )

  target_link_libraries(${name} PRIVATE ${ARG_LINK_LIBS})
  set_target_properties(${name} PROPERTIES FOLDER "lldb executables")

  if(ARG_GENERATE_INSTALL)
    set(install_dest bin)
    if(ARG_INSTALL_PREFIX)
      set(install_dest ${ARG_INSTALL_PREFIX})
    endif()
    install(TARGETS ${name} COMPONENT ${name}
            RUNTIME DESTINATION ${install_dest})
    if (NOT CMAKE_CONFIGURATION_TYPES)
      add_llvm_install_targets(install-${name}
                               DEPENDS ${name}
                               COMPONENT ${name})
    endif()
    if(APPLE AND ARG_INSTALL_PREFIX)
      lldb_add_post_install_steps_darwin(${name} ${ARG_INSTALL_PREFIX})
    endif()
  endif()
endfunction()


macro(add_lldb_tool_subdirectory name)
  add_llvm_subdirectory(LLDB TOOL ${name})
endmacro()

function(add_lldb_tool name)
  cmake_parse_arguments(ARG "ADD_TO_FRAMEWORK" "" "" ${ARGN})
  if(LLDB_BUILD_FRAMEWORK AND ARG_ADD_TO_FRAMEWORK)
    set(subdir LLDB.framework/Versions/${LLDB_FRAMEWORK_VERSION}/Resources)
    add_lldb_executable(${name}
      GENERATE_INSTALL
      INSTALL_PREFIX ${LLDB_FRAMEWORK_INSTALL_DIR}/${subdir}
      ${ARG_UNPARSED_ARGUMENTS}
    )
    lldb_add_to_buildtree_lldb_framework(${name} ${subdir})
    return()
  endif()

  add_lldb_executable(${name} GENERATE_INSTALL ${ARG_UNPARSED_ARGUMENTS})
endfunction()

# Support appending linker flags to an existing target.
# This will preserve the existing linker flags on the
# target, if there are any.
function(lldb_append_link_flags target_name new_link_flags)
  # Retrieve existing linker flags.
  get_target_property(current_link_flags ${target_name} LINK_FLAGS)

  # If we had any linker flags, include them first in the new linker flags.
  if(current_link_flags)
    set(new_link_flags "${current_link_flags} ${new_link_flags}")
  endif()

  # Now set them onto the target.
  set_target_properties(${target_name} PROPERTIES LINK_FLAGS ${new_link_flags})
endfunction()

function(lldb_add_to_buildtree_lldb_framework name subdir)
  # Destination for the copy in the build-tree. While the framework target may
  # not exist yet, it will exist when the generator expression gets expanded.
  set(copy_dest "$<TARGET_FILE_DIR:liblldb>/../../../${subdir}")

  # Copy into the framework's Resources directory for testing.
  add_custom_command(TARGET ${name} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:${name}> ${copy_dest}
    COMMENT "Copy ${name} to ${copy_dest}"
  )
endfunction()

function(lldb_add_post_install_steps_darwin name install_prefix)
  if(NOT APPLE)
    message(WARNING "Darwin-specific functionality; not currently available on non-Apple platforms.")
    return()
  endif()

  get_target_property(output_name ${name} OUTPUT_NAME)
  if(NOT output_name)
    set(output_name ${name})
  endif()

  get_target_property(is_framework ${name} FRAMEWORK)
  if(is_framework)
    get_target_property(buildtree_dir ${name} LIBRARY_OUTPUT_DIRECTORY)
    if(buildtree_dir)
      set(bundle_subdir ${output_name}.framework/Versions/${LLDB_FRAMEWORK_VERSION}/)
    else()
      message(SEND_ERROR "Framework target ${name} missing property for output directory. Cannot generate post-install steps.")
      return()
    endif()
  else()
    get_target_property(target_type ${name} TYPE)
    if(target_type STREQUAL "EXECUTABLE")
      set(buildtree_dir ${LLVM_RUNTIME_OUTPUT_INTDIR})
    else()
      # Only ever install shared libraries.
      set(output_name "lib${output_name}.dylib")
      set(buildtree_dir ${LLVM_LIBRARY_OUTPUT_INTDIR})
    endif()
  endif()

  # Generate dSYM
  # TODO: Add an option to skip dSYM creation
  if(NOT ${name} STREQUAL "repl_swift")
    set(dsym_name ${output_name}.dSYM)
    if(is_framework)
      set(dsym_name ${output_name}.framework.dSYM)
    endif()
    if(LLDB_DEBUGINFO_INSTALL_PREFIX)
      # This makes the path absolute, so we must respect DESTDIR.
      set(dsym_name "\$ENV\{DESTDIR\}${LLDB_DEBUGINFO_INSTALL_PREFIX}/${dsym_name}")
    endif()

    set(buildtree_name ${buildtree_dir}/${bundle_subdir}${output_name})
    install(CODE "message(STATUS \"Externalize debuginfo: ${dsym_name}\")" COMPONENT ${name})
    install(CODE "execute_process(COMMAND xcrun dsymutil -o=${dsym_name} ${buildtree_name})"
            COMPONENT ${name})
  endif()

  # Strip distribution binary with -ST (removing debug symbol table entries and
  # Swift symbols). Avoid CMAKE_INSTALL_DO_STRIP and llvm_externalize_debuginfo()
  # as they can't be configured sufficiently.
  set(installtree_name "\$ENV\{DESTDIR\}${install_prefix}/${bundle_subdir}${output_name}")
  install(CODE "message(STATUS \"Stripping: ${installtree_name}\")" COMPONENT ${name})
  install(CODE "execute_process(COMMAND xcrun strip -ST ${installtree_name})"
          COMPONENT ${name})
endfunction()

# CMake's set_target_properties() doesn't allow to pass lists for RPATH
# properties directly (error: "called with incorrect number of arguments").
# Instead of defining two list variables each time, use this helper function.
function(lldb_setup_rpaths name)
  cmake_parse_arguments(LIST "" "" "BUILD_RPATH;INSTALL_RPATH" ${ARGN})
  set_target_properties(${name} PROPERTIES
    BUILD_WITH_INSTALL_RPATH OFF
    BUILD_RPATH "${LIST_BUILD_RPATH}"
    INSTALL_RPATH "${LIST_INSTALL_RPATH}"
  )
endfunction()