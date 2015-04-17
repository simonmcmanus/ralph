#! /bin/bash

# Hi There!

# Comments and feedback much welcomed via github issues.

# Prints the package name from the package.json.
echo ------------------------------
echo Ralph
echo Last release:
node -e 'console.log(require("./package.json").name)'
echo ------------------------------
echo
echo
# Checks the package.json (in the folder from which this script is run) and get the last version number.
packageVersion="$(node -e 'console.log(require("./package.json").version)')"

if [ -z "$packageVersion" ];
    then
    echo
    echo Package version not available.
    echo
    echo You need to run Ralph from a folder with a package.json file.
    echo
    exit 1
fi

# Get the current branch name
branch="$(git rev-parse --abbrev-ref HEAD)"

# Enforce master branch
if [ "$branch" != "master" ];
    then
    echo 'You are not on the master branch. Current branch is '$branch'.'
    exit 2
fi

# The release will fail if there are uncommited changes - checking early avoids cleanup.
if [ -n "$(git status --porcelain)" ];
    then

    gitdiff="$(git diff --exit-code)"
    if [ "$gitdiff" == "" ];
        then
            echo
            echo You have untracked changes.
            echo
            git status
            exit 3
        else
            echo
            echo You have the uncommitted changes:
            echo
            echo "$gitdiff"
            exit 4
    fi
fi

# Removes any local tags so avoids conflict with the remote.
#TODO  - should probably warn about doing this or sit behind a flag
# - its the easiest way to ensure the local tags are not different to the remotes.
git tag -l | xargs git tag -d
git fetch origin --tags

#ensure we have the latest upstream changes.
git pull --rebase origin master --quiet

# default this to no value.
commitsToShow=''

# get the last tag from git.
lasttag="$(git tag -l | sort -n | tail -1)"

if [ -n "$lasttag" ];
then
    # Get the count of commits since the last tagged release.
    range=$lasttag'..HEAD'
    commitsSince="$(git rev-list "$range" --count)"

    # The first commit is removing the shrinkwrap file from the previous release so we don't want to include that into our release notes.
    commitsToShow=-$((commitsSince-1))
fi

if [ -n "$lasttag" ]
    then

    ## Ensure that if present the last tagged version is the same as the version in package.json file
    #
    # protects against:
    #  1 - Have local tags that you havnt pushed (presumably becuase you didnt use this script or this script encountered an error)
    #  try deleting your local tags and fetching from the remote tags:
    #  git tag -l | xargs git tag -d
    #  git fetch
    #
    if [ "$lasttag" != v"$packageVersion" ];
        then
        echo 'The version in your local package.json (v'$packageVersion') file does not match the last published git tag (' $lasttag ').'
        exit 5
    fi
fi

echo
# formatting of changelog could be improved here.
changes="$(git --no-pager log $range $commitsToShow --pretty=oneline )"

# If there are no commits we have nothing to do.
if [ -z "$changes" ]
    then
    echo 'No commits - nothing to release.'
    exit 6
fi

if [ -n "$lasttag" ]
    then
        echo 'Commits since '$lasttag' :'
    else
        echo 'This will be the first tagged release.'
        echo
        echo 'It will include these commits:'
fi
echo
echo

git --no-pager  log $range $commitsToShow  --oneline

# No arg specified - lets stop here.
type=$1
if [ -z $type ];
then
    echo
    echo 'To make a release specify major|minor|patch or version number'
    echo
    exit
else

    # When doing the first release the package.json .version would say 1.0.0 and the param would also say 1.0.0
    # In that case we dont need to do a version bump.
    if [ "$packageVersion" == "$type" ];
    then
        newVersion=$packageVersion
    else
        # Works out what the new version number will be.
        newVersion="$(ralph-semver $packageVersion -i $type )"
    fi
fi

echo
echo Do you want to release v$newVersion?
echo
echo "type (yes/no) to continue"
echo
read -p "" CONT

if [ "$CONT" != "yes" ]; then
  echo Exiting.
  exit
fi

# Create the dist folder if it doesn't already exist.
mkdir -p dist



# Remove any install/linked modules
rm -Rf node_modules
npm cache clean


# Install modules from package.json - including dev dependencies so we can run the tests.
npm install || exit 7

# Run them tests.
npm test || exit 8

# Update the Changelog

changeLog='\n'$newVersion'\n'$changes'\n\n'

echo $changeLog$(cat changelog.md)  >  CHANGELOG.md

# Add the files we just changed
git add CHANGELOG.md
git commit -m '$newVersion - adding CHANGELOG.md file - (this commit message should get squashed)'

# we need to bump the version number in package.json.
if [ "$newVersion" != "$packageVersion" ]
then
    npm version $type -m 'foobar - not the real commit - this commit will be reset' || exit 9
    # delete the commit made above
    git push origin master -f
    # delete the tag made by the version (we run a git tag later.)
    git tag --delete v$newVersion
    # note that npm version adds an extra commit we need to reset later.
    commitCount=4
else
    commitCount=3
fi

# Take a copy of the package.json to restore later.
cp package.json ./dist/package.json.backup

# Locks down dependencies that were installed in the above npm install by creating npm-shrinkwrap.json file.
# - means we should be able to replicate the exact dependencies with an npm install from the git tag.
npm shrinkwrap || exit 10

git add npm-shrinkwrap.json
git add package.json
git commit -m $newVersion' - adding npm-shrinkwrap.json  and package file - this commit should be reset.'

commitMsg='Release '$newVersion':
'"$changes"

git tag -a v$newVersion -m  "$commitMsg" || exit 11

git rm npm-shrinkwrap.json

git commit -m $newVersion' - removing npm-shrinkwrap.json - this commit should be reset'

git push origin master || exit 12

# take another backup of package.json because we are about to modify it with the bundled-dependencies command.
cp package.json ./dist/package.json.backup

# Generates bundledDependancies array so dependencies are included in the package.json.
# https://docs.npmjs.com/files/package.json#bundleddependencies
# https://github.com/simonmcmanus/bundled-dependencies
ralph-bundled-dependencies

# Makes the .tgz package and sets the release varaible.

# not entirely sure we need this variable as $newVersion is avaialble.
release="$(npm pack)"

mv ./$release ./dist/$release
# We dont want to commit bundledDependencies to git so lets revert back to the backup package.json
#mv ./dist/package.json.backup ./package.json

# reset the last three commits so we can squash them into one.
git reset --soft head~$commitCount

# Create a commit that combines the two manual commits and also the one generated by the npm version.
# Crazy indentation to keep release notes looking pretty.
git commit -am "$commitMsg" || exit 13

#Push the squashed commit.
# do this first so if this fails we dont push the tag.
git push origin master -f || exit 15


# npm version command above created a tag, lets push that tag.
git push origin master --tags || exit 14

# todo - This will probably be an scp? how will permissions work?
git push origin master --tags

## latest.tgz is the file that we point to in package.json file of our dependencies.
cp ./dist/$release ./dist/latest.tgz

npm publish

echo $release ' has been released'

# Things you might need to cleanup if something goes wrong:
#
#   delete local version tags
#     to check:  git tag
#     to delete: git tag --delete v3.0.0

#   delete remote version tags
#   git push --delete upstream v3.0.0

#   git commits
#   to check: git log
#   reset to hash: git reset --hard COMMITHASH
#   force push changes back to server:  git push origin master -f
