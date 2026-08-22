# shellcheck shell=bash

declare -a autoPatchelfLibs
declare -a extraAutoPatchelfLibs
# Interleaved mode/path pairs, in registration order.
declare -a autoPatchelfSearchPaths

gatherLibraries() {
    autoPatchelfLibs+=("$1/lib")
}

# shellcheck disable=SC2154
# (targetOffset is referenced but not assigned.)
addEnvHooks "$targetOffset" gatherLibraries

# Can be used to manually add additional directories with shared object files
# to be included for the next autoPatchelf invocation.
addAutoPatchelfSearchPath() {
    local recurse=1

    while [ $# -gt 0 ]; do
        case "$1" in
            --) shift; break;;
            --no-recurse) shift; recurse=;;
            --*)
                echo "addAutoPatchelfSearchPath: ERROR: Invalid command line" \
                     "argument: $1" >&2
                return 1;;
            *) break;;
        esac
    done

    # No path argument means the working directory, as find itself would.
    if [ $# -eq 0 ]; then
        set -- .
    fi

    # The roots are handed over as roots: auto-patchelf expands them with the
    # same sorted walk it uses for $out, so one place decides which library wins
    # a duplicate soname.
    #
    # Both modes go into one list, because registration order is what decides
    # between two roots exporting the same soname. Keeping recursive and
    # shallow registrations in separate lists would silently reorder them.
    local mode=shallow
    if [ -n "$recurse" ]; then
        mode=recursive
    fi

    local path=
    for path in "$@"; do
        # An empty path means the working directory to auto-patchelf, so a
        # caller passing an unset variable would have the whole build tree
        # indexed instead of failing. Warn and skip. auto-patchelf rejects
        # these too, for anything not registered through here.
        if [ -z "$path" ]; then
            echo "addAutoPatchelfSearchPath: WARNING: ignoring empty search" \
                 "path" >&2
            continue
        fi
        autoPatchelfSearchPaths+=("$mode" "$path")
    done
}


autoPatchelf() {
    local norecurse=
    while [ $# -gt 0 ]; do
        case "$1" in
            --) shift; break;;
            --no-recurse) shift; norecurse=1;;
            --*)
                echo "autoPatchelf: ERROR: Invalid command line" \
                     "argument: $1" >&2
                return 1;;
            *) break;;
        esac
    done

    concatTo ignoreMissingDepsArray autoPatchelfIgnoreMissingDeps
    concatTo appendRunpathsArray appendRunpaths
    concatTo runtimeDependenciesArray runtimeDependencies
    concatTo patchelfFlagsArray patchelfFlags
    concatTo autoPatchelfFlagsArray autoPatchelfFlags

    # Check if ignoreMissingDepsArray contains "1" and if so, replace it with
    # "*", printing a deprecation warning.
    for dep in "${ignoreMissingDepsArray[@]}"; do
        if [ "$dep" == "1" ]; then
            echo "autoPatchelf: WARNING: setting 'autoPatchelfIgnoreMissingDeps" \
                 "= true;' is deprecated and will be removed in a future release." \
                 "Use 'autoPatchelfIgnoreMissingDeps = [ \"*\" ];' instead." >&2
            ignoreMissingDepsArray=( "*" )
            break
        fi
    done

    # One --search-path MODE PATH per registration, in order.
    local -a searchPathArgs=()
    local i=
    for (( i = 0; i < ${#autoPatchelfSearchPaths[@]}; i += 2 )); do
        searchPathArgs+=(
            --search-path
            "${autoPatchelfSearchPaths[i]}"
            "${autoPatchelfSearchPaths[i + 1]}"
        )
    done

    auto-patchelf                                                       \
        ${norecurse:+--no-recurse}                                      \
        --ignore-missing "${ignoreMissingDepsArray[@]}"                 \
        --paths "$@"                                                    \
        --libs "${autoPatchelfLibs[@]}"                                 \
               "${extraAutoPatchelfLibs[@]}"                            \
        "${searchPathArgs[@]}"                                          \
        --runtime-dependencies "${runtimeDependenciesArray[@]/%//lib}"  \
        --append-rpaths "${appendRunpathsArray[@]}"                     \
        "${autoPatchelfFlagsArray[@]}"                                  \
        --extra-args "${patchelfFlagsArray[@]}"
}

autoPatchelfPostFixup() {
    # XXX: This should ultimately use fixupOutputHooks but we currently don't have
    # a way to enforce the order. If we have $runtimeDependencies set, the setup
    # hook of patchelf is going to ruin everything and strip out those additional
    # RPATHs.
    #
    # So what we do here is basically run in postFixup and emulate the same
    # behaviour as fixupOutputHooks because the setup hook for patchelf is run in
    # fixupOutput and the postFixup hook runs later.
    if [[ -z "${dontAutoPatchelf-}" ]]; then
        autoPatchelf -- $(for output in $(getAllOutputNames); do
            [ -e "${!output}" ] || continue
            [ "${output}" = debug ] && continue
            echo "${!output}"
        done)
    fi
}

postFixupHooks+=(autoPatchelfPostFixup)
