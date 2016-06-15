#!/bin/sh

if [ -n "GITHUB_API_KEY" ]; then
    git add .
    git -c user.name="Travis CI" commit -m "Update docs"
    git push -f -q https://$GITHUB_API_KEY:x-oauth-basic@github.com/zhuhaow/tun2socks gh-pages &2>/dev/null
fi
