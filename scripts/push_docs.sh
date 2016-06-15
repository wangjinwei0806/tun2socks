#!/bin/sh

if [ -n "GITHUB_API_KEY" ]; then
    git add .
    git -c user.name="Travis CI" commit -m "Update docs"
    git push --force --quiet https://$GITHUB_API_KEY@github.com/zhuhaow/tun2socks.git gh-pages
fi
