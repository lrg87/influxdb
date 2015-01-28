#!/bin/bash

###########################################################################
# Packaging script which creates debian and RPM packages. It optionally
# tags the repo with the given version.
#
# 'fpm' must be on the path, and the AWS CLI tools must also be installed.

AWS_FILE=~/aws.conf

INSTALL_ROOT_DIR=/opt/influxdb
CONFIG_ROOT_DIR=/etc/opt/influxdb

SAMPLE_CONFIGURATION=etc/config.sample.toml
INITD_SCRIPT=scripts/init.sh

TMP_WORK_DIR=`mktemp -d`
POST_INSTALL_PATH=`mktemp`
ARCH=`uname -i`
LICENSE=MIT
URL=influxdb.com
MAINTAINER=support@influxdb.com
VENDOR=Influxdb
DESCRIPTION="Distributed time-series database"

###########################################################################
# Helper functions.

# usage prints simple usage information.
usage() {
    echo -e "$0 [<version>] [-h]\n"
    cleanup_exit $1
}

# cleanup_exit removes all resources created during the process and exits with
# the supplied returned code.
cleanup_exit() {
    rm -r $TMP_WORK_DIR
    rm $POST_INSTALL_PATH
    exit $1
}

# check_gopath sanity checks the value of the GOPATH env variable.
check_gopath() {
    [ -z "$GOPATH" ] && echo "GOPATH is not set." && cleanup_exit 1
    [ ! -d "$GOPATH" ] && echo "GOPATH is not a directory." && cleanup_exit 1
    echo "GOPATH ($GOPATH) looks sane."
}

# check_clean_tree ensures that no source file is locally modified.
check_clean_tree() {
    modified=$(git ls-files --modified | wc -l)
    if [ $modified -ne 0 ]; then
        echo "The source tree is not clean -- aborting."
        cleanup_exit 1
    fi
    echo "Git tree is clean."
}

# update_tree ensures the tree is in-sync with the repo.
update_tree() {
    git pull origin master
    if [ $? -ne 0 ]; then
        echo "Failed to pull latest code -- aborting."
        cleanup_exit 1
    fi
    git fetch --tags
    if [ $? -ne 0 ]; then
        echo "Failed to fetch tags -- aborting."
        cleanup_exit 1
    fi
    echo "Git tree updated successfully."
}

# check_tag_exists checks if the existing release already exists in the tags.
check_tag_exists () {
    version=$1
    git tag | grep -q "^v$version$"
    if [ $? -eq 0 ]; then
        echo "Proposed version $version already exists as a tag -- aborting."
        cleanup_exit 1
    fi
}

# make_dir_tree creates the directory structure within the packages.
make_dir_tree() {
    work_dir=$1
    version=$2
    mkdir -p $work_dir/$INSTALL_ROOT_DIR/versions/$version/scripts
    if [ $? -ne 0 ]; then
        echo "Failed to create installation directory -- aborting."
        cleanup_exit 1
    fi
    mkdir -p $work_dir/$CONFIG_ROOT_DIR
    if [ $? -ne 0 ]; then
        echo "Failed to create configuration directory -- aborting."
        cleanup_exit 1
    fi
}


# do_build builds the code. The version and commit must be passed in.
do_build() {
    version=$1
    commit=`git rev-parse HEAD`
    if [ $? -ne 0 ]; then
        echo "Unable to retrieve current commit -- aborting"
        cleanup_exit 1
    fi

    rm $GOPATH/bin/*
    go install -a -ldflags="-X main.version $version -X main.commit $commit" ./...
    if [ $? -ne 0 ]; then
        echo "Build failed, unable to create package -- aborting"
        cleanup_exit 1
    fi
    echo "Build completed successfully."
}

# generate_postinstall_script creates the post-install script for the
# package. It must be passed the version.
generate_postinstall_script() {
    version=$1
    cat  <<EOF >$POST_INSTALL_PATH
rm -f $INSTALL_ROOT_DIR/influxd
rm -f $INSTALL_ROOT_DIR/influxdb
rm -f $INSTALL_ROOT_DIR/init.sh
ln -s $INSTALL_ROOT_DIR/versions/$version/influxd $INSTALL_ROOT_DIR/influxd
ln -s $INSTALL_ROOT_DIR/versions/$version/influxdb $INSTALL_ROOT_DIR/influxdb
ln -s $INSTALL_ROOT_DIR/versions/$version/scripts/init.sh $INSTALL_ROOT_DIR/init.sh

if [ ! -L /etc/init.d/influxdb ]; then
    ln -sfn $INSTALL_ROOT_DIR/init.sh /etc/init.d/influxdb
    chmod +x /etc/init.d/influxdb
    if which update-rc.d > /dev/null 2>&1 ; then
        update-rc.d -f influxdb remove
        update-rc.d influxdb defaults
    else
        chkconfig --add influxdb
    fi
fi

if ! id influxdb >/dev/null 2>&1; then
        useradd --system -U -M influxdb
fi
chown -R -L influxdb:influxdb $INSTALL_ROOT_DIR
chmod -R a+rX $INSTALL_ROOT_DIR
EOF
    echo "Post-install script created successfully at $POST_INSTALL_PATH"
}

###########################################################################
# Start the packaging process.

if [ $# -ne 1 ]; then
    usage 1
elif [ $1 == "-h" ]; then
    usage 0
else
    VERSION=$1
fi

echo -e "\nStarting package process...\n"

check_gopath
check_clean_tree
update_tree
check_tag_exists $VERSION
do_build $VERSION
make_dir_tree $TMP_WORK_DIR $VERSION

###########################################################################
# Copy the assets to the installation directories.

cp $GOPATH/bin/* $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION
if [ $? -ne 0 ]; then
    echo "Failed to copy binaries to packaging directory -- aborting."
    cleanup_exit 1
fi
echo "Binaries in $GOPATH/bin copied to $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION"

cp $INITD_SCRIPT $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION/scripts
if [ $? -ne 0 ]; then
    echo "Failed to init.d script to packaging directory -- aborting."
    cleanup_exit 1
fi
echo "$INITD_SCRIPT copied to $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION/scripts"

cp $SAMPLE_CONFIGURATION $TMP_WORK_DIR/$CONFIG_ROOT_DIR/influxdb.conf
if [ $? -ne 0 ]; then
    echo "Failed to copy $SAMPLE_CONFIGURATION to packaging directory -- aborting."
    cleanup_exit 1
fi

generate_postinstall_script $VERSION

###########################################################################
# Create the actual packages.

echo -n "Commence creation of $ARCH packages, version $VERSION? [Y/n] "
read response
response=`echo $response | tr 'A-Z' 'a-z'`
if [ "x$response" == "xn" ]; then
    echo "Packaging aborted."
    cleanup_exit 1
fi

if [ $ARCH == "i386" ]; then
    rpm_package=influxdb-$VERSION-1.i686.rpm
    debian_package=influxdb_${VERSION}_i686.deb
    deb_args="-a i686"
    rpm_args="setarch i686"
elif [ $ARCH == "arm" ]; then
    rpm_package=influxdb-$VERSION-1.armel.rpm
    debian_package=influxdb_${VERSION}_armel.deb
else
    rpm_package=influxdb-$VERSION-1.x86_64.rpm
    debian_package=influxdb_${VERSION}_amd64.deb
fi

COMMON_FPM_ARGS="-C $TMP_WORK_DIR --vendor $VENDOR --url $URL --license $LICENSE --maintainer $MAINTAINER --after-install $POST_INSTALL_PATH --name influxdb --version $VERSION ."
$rpm_args fpm -s dir -t rpm --description "$DESCRIPTION" $COMMON_FPM_ARGS
if [ $? -ne 0 ]; then
    echo "Failed to create RPM package -- aborting."
    cleanup_exit 1
fi
echo "RPM package created successfully."

fpm -s dir -t deb $deb_args --description "$DESCRIPTION" $COMMON_FPM_ARGS
if [ $? -ne 0 ]; then
    echo "Failed to create Debian package -- aborting."
    cleanup_exit 1
fi
echo "Debian package created successfully."

###########################################################################
# Offer to tag the repo.

echo -n "Tag source tree with v$VERSION and push to repo? [y/N] "
read response
response=`echo $response | tr 'A-Z' 'a-z'`
if [ "x$response" == "xy" ]; then
    echo "Creating tag v$VERSION and pushing to repo"
    git tag v$VERSION
    if [ $? -ne 0 ]; then
        echo "Failed to create tag v$VERSION -- aborting"
        cleanup_exit 1
    fi
    git push origin v$VERSION
    if [ $? -ne 0 ]; then
        echo "Failed to push tag v$VERSION to repo -- aborting"
        cleanup_exit 1
    fi
else
    echo "Not creating tag v$VERSION."
fi


###########################################################################
# Offer to publish the packages.

echo -n "Publish packages to S3? [y/N] "
read response
response=`echo $response | tr 'A-Z' 'a-z'`
if [ "x$response" == "xy" ]; then
    echo "Publishing packages to S3."
    if [ ! -e "$AWS_FILE" ]; then
        echo "$AWS_FILE does not exist -- aborting."
        cleanup_exit 1
    fi

    for filepath in `ls *.{deb,rpm}`; do
        echo "Uploading $filepath to S3"
        filename=`basename $filepath`
        bucket=influxdb
        echo "Uploading $filename to s3://influxdb/$filename"
        AWS_CONFIG_FILE=$AWS_FILE aws s3 cp $filepath s3://influxdb/$filename --acl public-read --region us-east-1
        if [ $? -ne 0 ]; then
            echo "Upload failed -- aborting".
            cleanup_exit 1
        fi
        echo "Uploading $filename to s3://get.influxdb.org/$filename"
        AWS_CONFIG_FILE=$AWS_FILE aws s3 cp $filepath s3://get.influxdb.org/$filename --acl public-read --region us-east-1
        if [ $? -ne 0 ]; then
            echo "Upload failed -- aborting".
            cleanup_exit 1
        fi
    done
else
    echo "Not publishing packages to S3."
fi

###########################################################################
# All done.

echo -e "\nPackaging process complete."
cleanup_exit 0
