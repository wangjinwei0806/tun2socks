n
    git add .
    git -c user.name="Travis CI" commit -m "Update docs"
    git push --force --quite https://$GITHUB_API_KEY@github.com/zhuhaow/tun2socks.git gh-pages
fi
