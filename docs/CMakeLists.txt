if (DOXYGEN_FOUND)

    # set input and output files

    #message(${DOXYGEN_INPUT_DIR})

    set(DOXYGEN_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/doxygen)
    set(DOXYGEN_INDEX_FILE ${DOXYGEN_OUTPUT_DIR}/html/index.html)
    set(DOXYFILE_IN ${CMAKE_CURRENT_SOURCE_DIR}/Doxyfile.in)
    set(DOXYFILE_OUT ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile)

    configure_file(${DOXYFILE_IN} ${DOXYFILE_OUT} @ONLY)

    file(MAKE_DIRECTORY ${DOXYGEN_OUTPUT_DIR}) #Doxygen won't create this for us

    add_custom_command(OUTPUT ${DOXYGEN_INDEX_FILE}
            DEPENDS ${DOXYGEN_PUBLIC_HEADERS} ${DOXYFILE_IN}
            COMMAND ${DOXYGEN_EXECUTABLE} ${DOXYFILE_OUT}
            MAIN_DEPENDENCY ${DOXYFILE_OUT} ${DOXYFILE_IN}
            COMMENT "Generating docs")

    add_custom_target(DoxygenDKVCG ALL DEPENDS ${DOXYGEN_INDEX_FILE})

    install(DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/doxygen/html DESTINATION share/doc)

else (DOXYGEN_FOUND)
    message("Doxygen need to be installed to generate the doxygen documentation")
endif (DOXYGEN_FOUND)