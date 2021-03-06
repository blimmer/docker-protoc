#!/bin/bash

set -e

printUsage() {
    echo "gen-proto generates grpc and protobuf @ Namely"
    echo " "
    echo "Usage: gen-proto -f my-service.proto -l go"
    echo " "
    echo "options:"
    echo " -h, --help           Show help"
    echo " -f FILE              The proto source file to generate"
    echo " -d DIR               Scans the given directory for all proto files"
    echo " -l LANGUAGE          The language to generate (${SUPPORTED_LANGUAGES[@]})"
    echo " -o DIRECTORY         The output directory for generated files. Will be automatically created."
    echo " -i includes          Extra includes"
    echo " --lint CHECKS        Enable linting protoc-lint (CHECKS are optional - see https://github.com/ckaznocha/protoc-gen-lint#optional-checks)"
    echo " --with-gateway       Generate grpc-gateway files (experimental)."

}

GEN_GATEWAY=false
LINT=false
LINT_CHECKS=""
SUPPORTED_LANGUAGES=("go" "ruby" "csharp" "java" "python" "objc" "gogo" "php" "node")
EXTRA_INCLUDES=""
OUT_DIR=""

while test $# -gt 0; do
    case "$1" in
        -h|--help)
            printUsage
            exit 0
            ;;
        -f)
            shift
            if test $# -gt 0; then
                FILE=$1
            else
                echo "no input file specified"
                exit 1
            fi
            shift
            ;;
        -d)
            shift
            if test $# -gt 0; then
                PROTO_DIR=$1
            else
                echo "no directory specified"
                exit 1
            fi
            shift
            ;;
        -l)
            shift
            if test $# -gt 0; then
                GEN_LANG=$1
            else
                echo "no language specified"
                exit 1
            fi
            shift
            ;;
        -o) shift
            OUT_DIR=$1
            shift
            ;;
        -i) shift
            EXTRA_INCLUDES="-I$1"
            shift
            ;;
        --with-gateway)
            GEN_GATEWAY=true
            shift
            ;;
        --lint)
            LINT=true
            if [ "$#" -gt 1 ] && [[ $2 != -* ]]; then
                LINT_CHECKS=$2
		        shift
            fi
            shift
            ;;
        *)
            break
            ;;
    esac
done

if [[ -z $FILE && -z $PROTO_DIR ]]; then
    echo "Error: You must specify a proto file or proto directory"
    printUsage
    exit 1
fi

if [[ ! -z $FILE && ! -z $PROTO_DIR ]]; then
    echo "Error: You may specifiy a proto file or directory but not both"
    printUsage
    exit 1
fi

if [ -z $GEN_LANG ]; then
    echo "Error: You must specify a language: ${SUPPORTED_LANGUAGES[@]}"
    printUsage
    exit 1
fi

if [[ ! ${SUPPORTED_LANGUAGES[*]} =~ "$GEN_LANG" ]]; then
    echo "Language $GEN_LANG is not supported. Please specify one of: ${SUPPORTED_LANGUAGES[@]}"
    exit 1
fi

if [[ "$GEN_GATEWAY" == true && "$GEN_LANG" != "go" ]]; then
  echo "Generating grpc-gateway is Go specific."
  exit 1
fi

PLUGIN_LANG=$GEN_LANG
if [ $PLUGIN_LANG == 'objc' ] ; then
    PLUGIN_LANG='objective_c'
fi

if [[ $OUT_DIR == '' ]]; then
    GEN_DIR="gen"
    if [[ $GEN_LANG == "python" ]]; then
        # Python needs underscores to read the directory name.
        OUT_DIR="${GEN_DIR}/pb_$GEN_LANG"
    else
        OUT_DIR="${GEN_DIR}/pb-$GEN_LANG"
    fi
fi

echo "Generating $GEN_LANG files for ${FILE}${PROTO_DIR} in $OUT_DIR"

if [[ ! -d $OUT_DIR ]]; then
  # If a .jar is specified, protoc can output to the jar directly. So
  # don't create it as a directory.
  if [[ "$GEN_LANG" == "java" ]] && [[ $OUT_DIR == *.jar ]]; then
    mkdir -p `dirname $OUT_DIR`
  else
    mkdir -p $OUT_DIR
  fi
fi

GEN_STRING=''
case $GEN_LANG in
    "go")
        GEN_STRING="--go_out=plugins=grpc:$OUT_DIR"
        ;;
    "gogo")
        GEN_STRING="--gogofast_out=\
Mgoogle/protobuf/any.proto=github.com/gogo/protobuf/types,\
Mgoogle/protobuf/duration.proto=github.com/gogo/protobuf/types,\
Mgoogle/protobuf/struct.proto=github.com/gogo/protobuf/types,\
Mgoogle/protobuf/timestamp.proto=github.com/gogo/protobuf/types,\
Mgoogle/protobuf/wrappers.proto=github.com/gogo/protobuf/types,\
Mgoogle/protobuf/field_mask.proto=github.com/gogo/protobuf/types,\
plugins=grpc+embedded\
:$OUT_DIR"
        ;;
    "java")
        GEN_STRING="--grpc_out=$OUT_DIR --${GEN_LANG}_out=$OUT_DIR --plugin=protoc-gen-grpc=`which protoc-gen-grpc-java`"
        ;;
    "node")
        GEN_STRING="--grpc_out=$OUT_DIR --js_out=import_style=commonjs,binary:$OUT_DIR --plugin=protoc-gen-grpc=`which grpc_${PLUGIN_LANG}_plugin`"
        ;;
    *)
        GEN_STRING="--grpc_out=$OUT_DIR --${GEN_LANG}_out=$OUT_DIR --plugin=protoc-gen-grpc=`which grpc_${PLUGIN_LANG}_plugin`"
        ;;
esac

LINT_STRING=''
if [[ $LINT == true ]]; then
    if [[ $LINT_CHECKS == '' ]]; then
        LINT_STRING="--lint_out=."
    else
        LINT_STRING="--lint_out=$LINT_CHECKS:."
    fi
fi

PROTO_INCLUDE="-I /usr/include/ \
    -I /usr/local/include/ \
    -I ${GOPATH}/src/github.com/grpc-ecosystem/grpc-gateway/ \
    -I ${GOPATH}/src \
    $EXTRA_INCLUDES"

if [ ! -z $PROTO_DIR ]; then
    PROTO_INCLUDE="$PROTO_INCLUDE -I $PROTO_DIR"
    PROTO_FILES=(`find ${PROTO_DIR} -name "*.proto"`)
else
    PROTO_INCLUDE="-I . $PROTO_INCLUDE"
    PROTO_FILES=($FILE)
fi

protoc $PROTO_INCLUDE \
    $GEN_STRING \
    $LINT_STRING \
    ${PROTO_FILES[@]}

# Python also needs __init__.py files in each directory to import.
# If __init__.py files are needed at higher level directories (i.e.
# directories above $OUT_DIR), it's the caller's responsibility to
# create them.
if [[ $GEN_LANG == "python" ]]; then
    # Create __init__.py for everything in the OUT_DIR
    # (i.e. gen/pb_python/foo/bar/).
    echo "Out dir is '$OUT_DIR'"
    find $OUT_DIR -type d | xargs -n1 -I '{}' touch '{}/__init__.py'
    # And everything above it (i.e. gen/__init__py")
    d=`dirname $OUT_DIR`
    while [[ "$d" != "." ]]; do
        touch "$d/__init__.py"
        d=`dirname $d`
    done
fi

if [ $GEN_GATEWAY = true ]; then
    GATEWAY_DIR=${OUT_DIR}
    mkdir -p ${GATEWAY_DIR}

    protoc $PROTO_INCLUDE \
		--grpc-gateway_out=logtostderr=true:$GATEWAY_DIR ${PROTO_FILES[@]}
    protoc $PROTO_INCLUDE  \
		--swagger_out=logtostderr=true:$GATEWAY_DIR ${PROTO_FILES[@]}
fi
