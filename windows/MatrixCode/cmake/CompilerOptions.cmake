function(matrixcode_target_options target)
  target_compile_definitions(${target} PRIVATE
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _WIN32_WINNT=0x0A00
  )
  if(MSVC)
    target_compile_options(${target} PRIVATE
      $<$<COMPILE_LANGUAGE:CXX>:/W4>
      $<$<COMPILE_LANGUAGE:CXX>:/WX>
      $<$<COMPILE_LANGUAGE:CXX>:/permissive->
      $<$<COMPILE_LANGUAGE:CXX>:/Zc:__cplusplus>
      $<$<COMPILE_LANGUAGE:CXX>:/Zc:inline>
      $<$<COMPILE_LANGUAGE:CXX>:/utf-8>
      $<$<COMPILE_LANGUAGE:CXX>:/sdl>
      $<$<COMPILE_LANGUAGE:CXX>:/guard:cf>
      $<$<COMPILE_LANGUAGE:CXX>:/fp:strict>
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:/O2>
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:/GL>
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:/Gw>
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:/Gy>
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:/Zi>
    )
    get_target_property(matrixcode_target_type ${target} TYPE)
    if(matrixcode_target_type STREQUAL "EXECUTABLE" OR
       matrixcode_target_type STREQUAL "SHARED_LIBRARY" OR
       matrixcode_target_type STREQUAL "MODULE_LIBRARY")
      target_link_options(${target} PRIVATE
        /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA /guard:cf
        $<$<CONFIG:Release>:/LTCG>
        $<$<CONFIG:Release>:/DEBUG:FULL>
        $<$<CONFIG:Release>:/OPT:REF>
        $<$<CONFIG:Release>:/OPT:ICF>
        $<$<AND:$<CONFIG:Release>,$<STREQUAL:${CMAKE_GENERATOR_PLATFORM},x64>>:/CETCOMPAT>
      )
    endif()
  endif()
endfunction()
