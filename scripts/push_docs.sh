#!/bin/sh

if [ -n "GITHUB_API_KEY" ]; then
    git add .
    git -c user.name="Travis CI" commit -m "Update docs"
    git push -f -q https://user:$GITHUB_API_KEY@github.com/zhuhaow/tun2socks.git gh-pages &2>/dev/null
fi
